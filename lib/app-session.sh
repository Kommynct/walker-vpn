# Run as the desktop user, inside the app network namespace.
set -uo pipefail
proxy=$1 app_id=$2
shift 2
if [[ ! -S $XDG_RUNTIME_DIR/bus ]]; then
    unset DBUS_SESSION_BUS_ADDRESS
    exec "$@"
fi
if [[ ! -x $proxy ]]; then
    printf 'The filtered desktop session bus proxy is unavailable.\n' >&2
    exit 1
fi

directory=$(mktemp -d "$XDG_RUNTIME_DIR/walker-vpn-bus.XXXXXXXX") || exit 1
socket=$directory/bus
child= proxy_pid=
cleanup() {
    if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || :; fi
    if [[ -n $proxy_pid ]]; then
        kill -TERM "$proxy_pid" 2>/dev/null || :
        wait "$proxy_pid" 2>/dev/null || :
    fi
    rm -rf -- "$directory"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

mkfifo "$directory/ready" || exit 1
exec {ready}<>"$directory/ready" || exit 1
exec {input}<&0
(
    if ! IFS= read -r -N 1 -t 3 -u "$ready"; then
        printf 'The filtered desktop session bus did not start.\n' >&2
        exit 1
    fi
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$socket"
    exec {input}<&- {ready}>&-
    exec "$@"
) <&"$input" &
child=$!
exec {input}<&-
rules=(
    --filter
    --talk=org.kde.StatusNotifierWatcher
    --talk=org.freedesktop.Notifications
    '--call=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.*@/org/freedesktop/portal/desktop'
    '--broadcast=org.freedesktop.portal.Desktop=org.freedesktop.portal.Settings.SettingChanged@/org/freedesktop/portal/desktop'
)
if [[ $app_id =~ ^[a-zA-Z_][a-zA-Z0-9_-]*(\.[a-zA-Z_][a-zA-Z0-9_-]*)+$ ]]; then
    rules+=("--own=$app_id")
fi
for instance in {1..4}; do
    rules+=("--own=org.kde.StatusNotifierItem-$child-$instance")
done
"$proxy" "--fd=$ready" "unix:path=$XDG_RUNTIME_DIR/bus" "$socket" "${rules[@]}" </dev/null >&2 &
proxy_pid=$!
exec {ready}>&-
result=0
wait "$child" || result=$?
child=
exit "$result"
