set -uo pipefail
uid=$1 gid=$2 user=$3 home=$4 namespace=$5 app_iface=$6 kind=$7 app_id=$8 work=$9
shift 9
forward_files=$1
env_count=$2
shift 2
session=("${@:1:env_count}")
shift "$env_count"
runtime=/run/user/$uid
session_bus=unix:path=$runtime/bus

if [[ ! /proc/self/ns/net -ef /run/netns/$namespace || /proc/self/ns/net -ef /proc/1/ns/net ||
    /proc/self/ns/mnt -ef /proc/1/ns/mnt ]]; then
    printf 'The app process did not enter the expected network and mount namespaces.\n' >&2
    exit 1
fi
if [[ ! -s /etc/resolv.conf ]] || ! ip link show dev "$app_iface" >/dev/null; then
    printf 'The app namespace has no resolver configuration or expected network interface.\n' >&2
    exit 1
fi

# nss-resolve uses a host Unix socket. Hide it within this mount namespace.
if [[ -d /run/systemd/resolve ]]; then
    mount -t tmpfs -o size=4k,mode=000 tmpfs /run/systemd/resolve || exit 1
fi

if [[ $kind == flatpak ]]; then
    # Pin the desktop user's destination by fd. The private mount namespace and
    # the ownership check keep this bind off system and other users' directories.
    monitor=$runtime/.flatpak-helper/monitor
    exec {monitor_fd}<"$monitor" || exit 1
    target=/proc/self/fd/$monitor_fd
    [[ -d $target && $(stat -L -c %u "$target") == "$uid" ]] || exit 1
    # The fd-based libmount backend rejects a /proc/self/fd mount target.
    # The classic bind syscall resolves the pinned directory instead.
    LIBMOUNT_FORCE_MOUNT2=always mount --no-canonicalize --bind "$work/monitor" "$target" || exit 1
    exec {monitor_fd}<&-
    mapfile -t dns < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
    (("${#dns[@]}")) || exit 1
    check='
        set -eu
        awk -F : -v iface="$1" '"'"'$1 ~ "^[[:space:]]*" iface "$" { found=1 } END { exit !found }'"'"' /proc/net/dev
        shift
        command=$1
        shift
        while [ "$1" != -- ]; do
            awk -v server="$1" '"'"'$1 == "nameserver" && $2 == server { found=1 } END { exit !found }'"'"' /etc/resolv.conf
            shift
        done
        shift
        exec "$command" "$@"
    '
    command=$1
    shift
    if [[ $forward_files == true ]] && (( $# )); then
        set -- --file-forwarding --command=sh "$app_id" -c "$check" walker-vpn \
            "$app_iface" "$command" "${dns[@]}" -- @@u "$@" @@
    else
        set -- --command=sh "$app_id" -c "$check" walker-vpn \
            "$app_iface" "$command" "${dns[@]}" -- "$@"
    fi
    set -- "${WALKER_VPN_FLATPAK:-flatpak}" run --share=network --nosocket=session-bus --nosocket=system-bus \
        --talk-name=org.kde.StatusNotifierWatcher --no-talk-name=org.freedesktop.Flatpak "$@"
else
    set -- /run/current-system/sw/bin/bash "${BASH_SOURCE[0]%/*}/app-session.sh" \
        "$(command -v xdg-dbus-proxy)" "$app_id" "$@"
fi

cd "$home" || exit 1
printf 'READY\n'
exec setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs -- \
    env -i HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="$runtime" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/walker-vpn/no-system-bus \
    PATH=/run/current-system/sw/bin "${session[@]}" "$@"
