#!/usr/bin/env bash
# Run in disposable namespaces so nftables, routes and WireGuard are real.
set -Eeuo pipefail
if [[ ${1:-} != --isolated ]]; then
    script=$(realpath -- "${BASH_SOURCE[0]}")
    exec unshare --user --map-root-user --mount --net --pid --fork --mount-proc bash "$script" --isolated
fi
[[ $$ == 1 && $UID == 0 ]]
trap 'printf "Network fixture failed at line %s.\n" "$LINENO" >&2' ERR
dnsmasq=${WALKER_VPN_TEST_DNSMASQ:-$(command -v dnsmasq || :)}
if [[ ! -x $dnsmasq ]]; then
    echo 'Set WALKER_VPN_TEST_DNSMASQ or add dnsmasq to PATH.' >&2
    exit 1
fi
dnsmasq=$(realpath -- "$dnsmasq")

# Resolve NixOS profile links before hiding the host's runtime directory.
IFS=: read -ra search_path <<< "$PATH"
resolved_path=
for directory in "${search_path[@]}"; do
    [[ $directory == /* && $directory != /run/wrappers/* && -d $directory ]] || continue
    resolved_path+=${resolved_path:+:}$(realpath -- "$directory")
done
PATH=$resolved_path
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mount -t sysfs sysfs /sys
source "${BASH_SOURCE[0]%/*}/../lib/guard.sh"
id() { [[ $* == '-u walker-vpn-api' ]] && printf '123\n'; }
ip() {
    # The disposable user namespace maps only one UID. The transport test
    # does not use the provider UID route.
    if [[ $* == "-4 rule add pref $api_uid_pref uidrange 123-123 lookup main" ]]; then return 0; fi
    command ip "$@"
}

mkdir -p "$run"
ip link add uplink type veth peer name peerlink
ip netns add fixture
ip link set dev peerlink netns fixture
ip address add 192.0.2.1/24 dev uplink
ip -n fixture address add 192.0.2.2/24 dev peerlink
ip link set uplink up
ip -n fixture link set peerlink up
ip link add "$iface" type wireguard
wg set "$iface" listen-port 45001
ip link set "$iface" up
printf 'Endpoint = 192.0.2.2:45999\n' > "$profile"
touch "$run/armed"
guard_init

ip netns exec fixture nft -f - <<'RULES'
table inet transport_test {
    counter unmatched {}
    counter registered {}
    chain input {
        type filter hook input priority filter; policy accept;
        udp dport 45999 udp sport 45000 counter name unmatched
        udp dport 45999 udp sport 45001 counter name registered
    }
}
RULES

nft -f - <<RULES
table inet inject_test_mark {
    chain output {
        type filter hook output priority -30; policy accept;
        udp sport { 45000, 45001 } meta mark set $wgmark
    }
}
RULES

send_probe() {
    printf 'fixture\n' | socat -u - "UDP4-DATAGRAM:$1:$2,bind=192.0.2.1:$3"
}
# Use the registered WireGuard port after closing the synthetic kernel socket.
# Only the WireGuard mark and complete registered UDP tuple should pass.
ip link set "$iface" down
send_probe 192.0.2.2 45999 45001
send_probe 192.0.2.2 45999 45000 2>/dev/null || :
nft delete table inet inject_test_mark
send_probe 192.0.2.2 45999 45001 2>/dev/null || :
count() {
    ip netns exec fixture nft -j list counter inet transport_test "$1" |
        jq -er '[.nftables[].counter? | objects | .packets][0]'
}
[[ $(count registered) == 1 ]]
[[ $(count unmatched) == 0 ]] || {
    echo 'The armed guard accepted a marked packet with an unregistered UDP source port.' >&2
    exit 1
}
printf 'The armed guard admits only the registered marked WireGuard tuple.\n'

# Create a WireGuard peer shared by the two tunnel clients. Private keys and
# resolver records are generated inside the disposable namespace.
lib=${BASH_SOURCE[0]%/*}/../lib
source "$lib/app-service.sh"
mount -t tmpfs tmpfs /etc/netns
wg genkey > /run/peer.key
wg genkey > /run/host.key
wg genkey > /run/app.key
peer_key=$(wg pubkey < /run/peer.key)
host_key=$(wg pubkey < /run/host.key)
app_key=$(wg pubkey < /run/app.key)
ip -n fixture link add peerwg type wireguard
ip -n fixture address add 10.91.0.1/24 dev peerwg
ip netns exec fixture wg set peerwg private-key /run/peer.key listen-port 45999 \
    peer "$host_key" allowed-ips 10.91.0.2/32 peer "$app_key" allowed-ips 10.91.0.3/32
ip -n fixture link set peerwg up
wg set "$iface" private-key /run/host.key listen-port 45001 fwmark "$wgmark" \
    peer "$peer_key" endpoint 192.0.2.2:45999 allowed-ips 0.0.0.0/0
ip address add 10.91.0.2/32 dev "$iface"
ip link set "$iface" up
ip -4 route add default dev "$iface" table "$wgmark"
ip -6 route add default dev "$iface" table "$wgmark"
ip -4 rule add pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0
ip -4 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"
ip -6 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=1
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

build_profile() {
    local region=$1 config=$2
    [[ $region == synthetic ]] || return 1
    cat > "$config" <<PROFILE
[Interface]
PrivateKey = $(< /run/app.key)
Address = 10.91.0.3/32
DNS = 10.91.0.1
[Peer]
PublicKey = $peer_key
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.2:45999
PROFILE
}
fail() { printf '%s\n' "$*" >&2; return 1; }
namespace=wv0123456789
work=$(mktemp -d "$run/app.XXXXXXXX")
start_app_tunnel synthetic
dedicated=$namespace
printf '%s\n' "$app_peer" > /run/dedicated-tuple
printf '45998 192.0.2.2 45999\n' > "$run/app-peer-wvffffffffff"
nft add element inet walkervpn app_peers '{ 45998 . 192.0.2.2 . 45999 }'
guard_app_peers
[[ ! -e $run/app-peer-wvffffffffff ]]
nft get element inet walkervpn app_peers "{ $(< /run/dedicated-tuple) }" >/dev/null
if nft get element inet walkervpn app_peers '{ 45998 . 192.0.2.2 . 45999 }' >/dev/null 2>&1; then
    echo 'The stale dedicated peer is still allowed.' >&2
    exit 1
fi
nft delete table inet walkervpn
guard_init
guard_armed
nft get element inet walkervpn app_peers "{ $(< /run/dedicated-tuple) }" >/dev/null
printf 'Guard recovery restored its valid active transport and removed a stale record.\n'

# Reproduce Vopono's network shape without depending on its setup in a
# nested single-UID user namespace. Exercise Walker VPN's real policy and NAT.
forward_fixture() {
    local namespace=$1 mode=$2 uplink=$3 subnet=$4 dns=$5
    local inside=app0 veth= veth_name=h${namespace:2} pair=
    ip netns add "$namespace"
    ip link add "$veth_name" type veth peer name "$inside" netns "$namespace"
    ip address add "198.18.$subnet.1/24" dev "$veth_name"
    ip link set dev "$veth_name" up
    ip -n "$namespace" address add "198.18.$subnet.2/24" dev "$inside"
    ip -n "$namespace" link set dev "$inside" up
    ip -n "$namespace" -4 route add default via "198.18.$subnet.1"
    mkdir "/etc/netns/$namespace"
    printf 'nameserver %s\n' "$dns" > "/etc/netns/$namespace/resolv.conf"
    app_policy
}
direct=wv1111111111
follow=wv2222222222
forward_fixture "$direct" direct uplink 1 192.0.2.2
forward_fixture "$follow" vpn "$iface" 2 10.91.0.1

# Install and remove a shared NAT table like Vopono's. The per-app NAT
# needs to work after the shared table has gone.
nft -f - <<'RULES'
table inet synthetic_shared_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 198.18.0.0/16 masquerade
    }
}
RULES
nft delete table inet synthetic_shared_nat

reachable() { ip netns exec "$1" ping -q -n -c 1 -W 2 "$2" >/dev/null 2>&1; }
unreachable() {
    if reachable "$@"; then printf 'Unexpected reachability from %s to %s\n' "$1" "$2" >&2; return 1; fi
}
reachable "$direct" 192.0.2.2
reachable "$follow" 10.91.0.1
reachable "$dedicated" 10.91.0.1
unreachable "$direct" 10.91.0.1

start_dns() {
    ip netns exec fixture "$dnsmasq" -d --conf-file=/dev/null --log-facility=- \
        --no-hosts --no-resolv --bind-interfaces --listen-address="$1" \
        --address="/walker-vpn.test/$2" >"/run/dns-$2.log" 2>&1 &
}
start_dns 192.0.2.2 203.0.113.41
start_dns 10.91.0.1 203.0.113.42
for (( attempt=0; attempt<20; attempt++ )); do
    listeners=$(ip netns exec fixture ss -H -lnu "sport = :53")
    if [[ $listeners == *192.0.2.2:53* && $listeners == *10.91.0.1:53* ]]; then break; fi
    sleep .05
done
if (( attempt == 20 )); then cat /run/dns-*.log >&2; exit 1; fi
resolve() {
    RES_OPTIONS='attempts:1 timeout:1' ip netns exec "$1" getent -s dns ahostsv4 walker-vpn.test |
        awk 'NR == 1 { print $1 }'
}
[[ $(resolve "$direct") == 203.0.113.41 ]]
[[ $(resolve "$follow") == 203.0.113.42 ]]
[[ $(resolve "$dedicated") == 203.0.113.42 ]]
ip -n fixture -6 address add 2001:db8::2/64 dev peerlink nodad
ip -6 address add 2001:db8::1/64 dev uplink nodad
ip -6 address add 2001:db8:1::1/64 dev h1111111111 nodad
ip -6 address add 2001:db8:2::1/64 dev h2222222222 nodad
ip -n "$direct" -6 address add 2001:db8:1::2/64 dev app0 nodad
ip -n "$follow" -6 address add 2001:db8:2::2/64 dev app0 nodad
ip -n "$direct" -6 route add default via 2001:db8:1::1
ip -n "$follow" -6 route add default via 2001:db8:2::1
for ns in "$direct" "$follow" "$dedicated"; do unreachable "$ns" 2001:db8::2; done

# Keep the guard armed when simulating either unexpected link drop.
ip link set "$iface" down
unreachable "$follow" 10.91.0.1
reachable "$direct" 192.0.2.2
reachable "$dedicated" 10.91.0.1
if resolve "$follow" >/dev/null; then exit 1; fi
[[ $(resolve "$direct") == 203.0.113.41 ]]
[[ $(resolve "$dedicated") == 203.0.113.42 ]]
ip link set "$iface" up
ip -4 route replace default dev "$iface" table "$wgmark"
ip -6 route replace default dev "$iface" table "$wgmark"
reachable "$follow" 10.91.0.1
ip -n "$dedicated" link set "$dedicated" down
unreachable "$dedicated" 10.91.0.1
if resolve "$dedicated" >/dev/null; then exit 1; fi
[[ $(resolve "$follow") == 203.0.113.42 ]]
reachable "$follow" 10.91.0.1
reachable "$direct" 192.0.2.2
guard_armed
# Simulate manual disconnect removing host routes and disarming the guard.
ip link delete "$iface"
guard_set off
if guard_armed; then exit 1; fi
unreachable "$follow" 192.0.2.2
reachable "$direct" 192.0.2.2
printf 'Synthetic IPv4 and DNS follow the three app routes through shared NAT removal and independent tunnel drops. IPv6 did not reach the physical peer.\n'
