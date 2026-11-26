run=/run/walker-vpn
state=/var/lib/walker-vpn
iface=walkvpn0
wgmark=51872
bootstrap_mark=0x575651
api_uid_pref=11000
bootstrap_pref=11001
tunnel_return_pref=11003
tunnel_pref=11010
profile=$run/$iface.conf

ipv4() {
    local a b c d octet
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ $octet == 0 || $octet != 0* ]] && (( 10#$octet <= 255 )) || return 1
    done
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
valid_interface() { [[ $1 =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]]; }
valid_region() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; }

guard_init() {
    local api_uid installed rules endpoint record veth uplink pair
    api_uid=$(id -u walker-vpn-api) || return 1
    if ! nft list table inet walkervpn >/dev/null 2>&1; then
        local restore_output= restore_forward=
        if [[ -e $run/armed ]]; then
            restore_output="add rule inet walkervpn output jump block_output"
            restore_forward="add rule inet walkervpn forward jump block_forward"
        fi
        nft -f - <<RULES || return 1
table inet walkervpn {
    set bootstrap {
        type ipv4_addr . inet_service
        flags timeout
        timeout 100s
    }
    set peer { type ipv4_addr . inet_service; }
    set direct { type iface_index . iface_index; }

    chain api_route {
        type route hook output priority -155; policy accept;
        meta skuid $api_uid ip daddr . tcp dport @bootstrap meta mark set $bootstrap_mark
    }

    chain api_only {
        meta mark $bootstrap_mark ip daddr . tcp dport @bootstrap accept
        drop
    }

    chain remember_transport {
        type filter hook postrouting priority -151; policy accept;
        ip daddr . tcp dport @bootstrap meta mark $bootstrap_mark ct mark set meta mark
        meta mark $wgmark ip daddr . udp dport @peer ct mark set meta mark
    }

    chain restore_transport {
        type filter hook prerouting priority -151; policy accept;
        ct mark { $wgmark, $bootstrap_mark } meta mark set ct mark
    }

    chain output {
        type filter hook output priority -10; policy accept;
        meta skuid $api_uid jump api_only
    }

    chain forward {
        type filter hook forward priority -10; policy accept;
    }

    chain block_output {
        oifname { "lo", "$iface" } accept
        meta mark $wgmark ip daddr . udp dport @peer accept
        meta nfproto ipv4 meta skuid 0 udp sport 68 udp dport 67 accept
        counter drop
    }

    chain block_forward {
        meta nfproto ipv4 meta iif . meta oif @direct accept
        meta nfproto ipv4 ct state established,related meta oif . meta iif @direct accept
        oifname "$iface" accept
        iifname "$iface" ct state established,related accept
        counter drop
    }
}
$restore_output
$restore_forward
RULES
        if [[ -f $profile ]]; then
            endpoint=$(awk '$1 == "Endpoint" { print $3 }' "$profile")
            guard_peer "$endpoint" || return 1
        fi
        for record in "$run"/direct-wv*; do
            [[ -f $record ]] || continue
            read -r veth uplink pair < "$record"
            valid_interface "$veth" && valid_interface "$uplink" || continue
            [[ $pair == "$(< "/sys/class/net/$veth/ifindex") . $(< "/sys/class/net/$uplink/ifindex")" ]] ||
                continue
            printf 'add element inet walkervpn direct { %s }\n' "$pair" | nft -f - || return 1
        done
    fi
    rules=$(ip -j -4 rule show) || return 1
    # Select the uplink source address at socket connect time. The nftables
    # route hook marks the approved connection for return-path filtering.
    installed=$(jq -r --argjson pref "$api_uid_pref" '.[] | select(.priority == $pref) |
        [.uid_start, .uid_end, .table] | join(" ")' <<< "$rules") || return 1
    case "$installed" in
        "$api_uid $api_uid main") ;;
        '') ip -4 rule add pref "$api_uid_pref" uidrange "$api_uid-$api_uid" lookup main || return 1 ;;
        *) printf 'The routing priority %s is already in use.\n' "$api_uid_pref" >&2; return 1 ;;
    esac
    installed=$(jq -r --argjson pref "$bootstrap_pref" '.[] | select(.priority == $pref) |
        [.fwmark // "", .table // ""] | join(" ")' <<< "$rules") || return 1
    case "$installed" in
        "$bootstrap_mark main") ;;
        '') ip -4 rule add pref "$bootstrap_pref" fwmark "$bootstrap_mark" lookup main || return 1 ;;
        *) printf 'The routing priority %s is already in use.\n' "$bootstrap_pref" >&2; return 1 ;;
    esac
    if [[ -e $run/armed ]] && ! guard_armed; then
        guard_set on || return 1
    fi
}

guard_armed() {
    nft -j list table inet walkervpn 2>/dev/null | jq -e '
        [.nftables[].rule? | select(. != null) |
         select((.expr | length) == 1) | [.chain, .expr[0].jump.target]] |
        any(.[]; . == ["output","block_output"]) and
        any(.[]; . == ["forward","block_forward"])
    ' >/dev/null
}

guard_set() {
    local api_uid redirects=
    api_uid=$(id -u walker-vpn-api) || return 1
    if [[ $1 == on ]]; then
        redirects=$'add rule inet walkervpn output jump block_output\nadd rule inet walkervpn forward jump block_forward'
    fi
    nft -f - <<RULES || return 1
flush chain inet walkervpn output
flush chain inet walkervpn forward
add rule inet walkervpn output meta skuid $api_uid jump api_only
$redirects
RULES
    if [[ $1 == on ]]; then touch "$run/armed"; else rm -f "$run/armed" "$run/preview"; fi
}

guard_peer() {
    local setting=
    if [[ -n ${1:-} ]]; then
        ipv4 "${1%:*}" && valid_port "${1##*:}" || return 1
        setting="add element inet walkervpn peer { ${1%:*} . ${1##*:} }"
    fi
    nft -f - <<RULES
flush set inet walkervpn peer
$setting
RULES
}

tunnel_exists() { [[ -e /sys/class/net/$iface ]]; }
tunnel_is_up() {
    local flags
    [[ -r /sys/class/net/$iface/flags ]] || return 1
    IFS= read -r flags < "/sys/class/net/$iface/flags" || return 1
    [[ $flags =~ ^0x[0-9a-fA-F]+$ ]] && (( flags & 1 ))
}

latest_handshake() {
    local peer timestamp
    read -r peer timestamp < <(wg show "$iface" latest-handshakes) || return 1
    printf '%s\n' "$timestamp"
}

tunnel_down() {
    local family
    ip -4 rule del pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0 2>/dev/null || :
    for family in -4 -6; do
        ip "$family" rule del pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark" 2>/dev/null || :
    done
    if tunnel_exists; then
        [[ -f $profile ]] || return 1
        wg-quick down "$profile" >&2 || return 1
    elif [[ -f $profile ]]; then
        if ! systemctl is-active --quiet systemd-resolved; then
            while IFS= read -r line; do
                resolvconf -d "$line" -f || return 1
            done < <(resolvconf -l 2>/dev/null | awk -v iface="$iface" '
                /^# resolv.conf from / && ($NF==iface || $NF ~ ("[.]" iface "$")) { print $NF }')
        fi
    fi
}

tunnel_up() {
    local endpoint family rules
    endpoint=$(awk '$1 == "Endpoint" { print $3 }' "$profile")
    rules=$(ip -4 -j rule show) || return 1
    if jq -e --argjson pref "$tunnel_return_pref" 'any(.[]; .priority == $pref)' <<< "$rules" >/dev/null; then
        printf 'The routing priority %s is already in use.\n' "$tunnel_return_pref" >&2
        return 1
    fi
    for family in -4 -6; do
        rules=$(ip "$family" -j rule show) || return 1
        if jq -e --argjson pref "$tunnel_pref" 'any(.[]; .priority == $pref)' <<< "$rules" >/dev/null; then
            printf 'The routing priority %s is already in use.\n' "$tunnel_pref" >&2
            return 1
        fi
        if [[ -n $(ip "$family" route show table "$wgmark" 2>/dev/null) ]]; then
            printf 'The routing table %s is already in use.\n' "$wgmark" >&2
            return 1
        fi
    done
    guard_peer "$endpoint" && wg-quick up "$profile" >&2 || return 1
    if ! sysctl -q net.ipv4.conf.all.src_valid_mark=1 ||
        ! ip -4 route add default dev "$iface" table "$wgmark" ||
        ! ip -6 route add default dev "$iface" table "$wgmark" ||
        ! ip -4 rule add pref "$tunnel_return_pref" iif "$iface" table main suppress_prefixlength 0 ||
        ! ip -4 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark" ||
        ! ip -6 rule add pref "$tunnel_pref" not fwmark "$wgmark" table "$wgmark"; then
        tunnel_down || :
        return 1
    fi
}

make_host_profile() {
    local source=$1 target=$2
    if systemctl is-active --quiet systemd-resolved; then
        awk -v mark="$wgmark" '
            /^\[Interface\]$/ { print; print "FwMark = " mark; print "Table = off"; next }
            /^DNS = / {
                sub(/^DNS = /,""); gsub(/, /," ");
                print "PostUp = resolvectl dns %i " $0;
                print "PostUp = resolvectl domain %i ~."; next
            }
            /^AllowedIPs = / { print $0 ", ::/0"; next }
            { print }
        ' "$source" > "$target"
    else
        awk -v mark="$wgmark" '
            /^\[Interface\]$/ { print; print "FwMark = " mark; print "Table = off"; next }
            /^AllowedIPs = / { print $0 ", ::/0"; next }
            { print }
        ' "$source" > "$target"
    fi
}

physical_link() {
    local device
    while IFS= read -r device; do
        valid_interface "$device" || continue
        if [[ -e /sys/class/net/$device/device ]]; then
            printf '%s\n' "$device"
            return 0
        fi
    done < <(ip -j -4 route show table main default |
        jq -r 'sort_by(.metric // 0) | .[].dev // empty')
    return 1
}

link_dns() {
    local device=$1 server
    local -a candidates
    if systemctl is-active --quiet systemd-resolved; then
        read -ra candidates <<< "$(resolvectl dns "$device" 2>/dev/null | cut -d: -f2-)"
    else
        mapfile -t candidates < <(resolvconf -l "$device" 2>/dev/null |
            awk '$1 == "nameserver" { print $2 }')
        if (( ! ${#candidates[@]} )); then
            mapfile -t candidates < <(resolvconf -l 2>/dev/null |
                awk -v device="$device" '
                    /^# resolv.conf from / { selected = ($NF == device || index($NF, device ".") == 1) }
                    selected && $1 == "nameserver" { print $2 }
                ')
        fi
    fi
    for server in "${candidates[@]}"; do
        ipv4 "$server" && [[ $server != 127.* && $server != 0.0.0.0 ]] &&
            printf '%s\n' "$server"
    done
    return 0
}
