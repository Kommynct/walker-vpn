app_netns_dir=/run/netns

app_cleanup() {
    if [[ -n ${active_record:-} && -n ${active_lease:-} ]]; then
        flock -x "$active_lease" || return 1
        if [[ -f $active_record && $(< "$active_record") == "$namespace $app_iface $mode $work" ]]; then
            rm -f -- "$active_record"
        fi
    fi
    # Keep the egress policy in place until the host veth is gone.
    if [[ -n ${veth:-} ]]; then
        if ip link show dev "$veth" >/dev/null 2>&1; then
            ip link del "$veth" >&2 || return 1
        fi
        if [[ -n ${pair:-} ]]; then
            rm -f -- "$run/direct-$namespace"
            printf 'delete element inet walkervpn direct { %s }\n' "$pair" |
                nft -f - >&2 || :
        fi
        nft -f - <<< "destroy table inet $namespace" >&2 || :
        if [[ $mode == direct ]]; then
            ip -4 rule del pref 11002 iif "$veth" lookup main 2>/dev/null || :
        fi
    fi
    if [[ -n ${vpn_pid:-} ]]; then
        kill -INT "$vpn_pid" 2>/dev/null || :
        for ((attempt=0; attempt<30; attempt++)); do
            kill -0 "$vpn_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$vpn_pid" 2>/dev/null || :
        wait "$vpn_pid" 2>/dev/null || :
    fi
    rm -rf -- "$work"
}

app_policy() {
    local links inside wgdev uplink_index endpoint peer_ip peer_port mark allowed reverse_mark=
    links=$(ip -n "$namespace" -j -d link show | jq -er '
        [.[] | select(.linkinfo.info_kind == "veth")] as $interfaces |
        [.[] | select(.linkinfo.info_kind == "wireguard")] as $tunnels |
        select(($interfaces | length) == 1) |
        [$interfaces[0].ifname, $interfaces[0].link_index,
            (if ($tunnels | length) == 1 then $tunnels[0].ifname else "" end)] | @tsv
    ') || return 1
    IFS=$'\t' read -r inside link_index wgdev <<< "$links"
    [[ $link_index =~ ^[0-9]+$ ]] || return 1
    links=$(ip -j -d link show | jq -er --argjson index "$link_index" --arg uplink "$uplink" '
        [first(.[] | select(.ifindex == $index and .linkinfo.info_kind == "veth") | .ifname),
         first(.[] | select(.ifname == $uplink) | .ifindex)] |
        select(length == 2) | @tsv
    ') || return 1
    IFS=$'\t' read -r veth uplink_index <<< "$links"
    valid_interface "$inside" && valid_interface "$veth" && valid_interface "$uplink" || return 1

    if [[ $mode == direct || ${use_host_tunnel:-false} == true ]]; then
        allowed="meta nfproto ipv4 oifname \"$inside\" accept"
        app_iface=$inside
        if [[ $mode == direct ]]; then
            reverse_mark="iifname \"$veth\" oifname \"$uplink\" meta nfproto ipv4 ct mark set $bootstrap_mark"
        fi
    else
        valid_interface "$wgdev" || return 1
        endpoint=$(ip netns exec "$namespace" wg show "$wgdev" endpoints | awk 'NR == 1 { print $2 }')
        peer_ip=${endpoint%:*}
        peer_port=${endpoint##*:}
        mark=$(ip netns exec "$namespace" wg show "$wgdev" fwmark) || return 1
        valid_interface "$wgdev" && ipv4 "$peer_ip" && valid_port "$peer_port" &&
            [[ $mark =~ ^0x[1-9a-f][a-f0-9]{0,7}$ ]] || return 1
        allowed=$(printf 'meta nfproto ipv4 oifname "%s" accept\noifname "%s" meta mark %s ip daddr %s udp dport %s accept' \
            "$wgdev" "$inside" "$mark" "$peer_ip" "$peer_port")
        app_iface=$wgdev
    fi
    ip netns exec "$namespace" nft -f - <<RULES >&2 || return 1
table inet walker_app {
    chain output {
        type filter hook output priority -20; policy drop;
        oifname "lo" accept
        $allowed
    }
}
RULES

    nft -f - <<RULES >&2 || return 1
table inet $namespace {
    chain input {
        type filter hook input priority -20; policy accept;
        iifname "$veth" drop
    }
    chain forward {
        type filter hook forward priority -20; policy accept;
        iifname "$veth" meta nfproto ipv6 drop
        iifname "$veth" oifname != "$uplink" drop
        oifname "$veth" iifname != "$uplink" drop
        $reverse_mark
    }
}
RULES
    if [[ $mode == direct ]]; then
        ip -4 rule add pref 11002 iif "$veth" lookup main >&2 || return 1
        [[ $uplink_index =~ ^[0-9]+$ ]] || return 1
        local indices="$link_index . $uplink_index"
        printf 'add element inet walkervpn direct { %s }\n' "$indices" | nft -f - >&2 || return 1
        pair=$indices
        printf '%s %s %s\n' "$veth" "$uplink" "$pair" > "$run/direct-$namespace" || return 1
    fi
}

launch_app() {
    local app_kind app_id uid gid home user_entry job forward_files argc result=0
    mode= namespace= work= veth= pair= vpn_pid= active_record= active_lease= app_iface=
    local link_index uplink use_host_tunnel=false
    local item marker wait_start
    local -a fields=() args=() session=() dns=() options=()
    # NUL-delimited fields preserve spaces, empty arguments, and newlines.
    mapfile -d '' -t fields < <(jq -s -j --args '
        def safe_string: type == "string" and length <= 4096 and index("\u0000") == null;
        select(length == 1) | .[0] |
        select(
            (.mode == "vpn" or .mode == "direct") and
            (.kind == "native" or .kind == "flatpak") and
            (.job | strings | test("^[a-f0-9-]{36}$")) and
            ((.app_id // "") | strings | test("^[A-Za-z0-9_.-]{0,200}$")) and
            (.kind != "flatpak" or (.app_id | strings | test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,199}$"))) and
            (.argv | type == "array" and length >= 1 and length <= 80 and all(.[]; safe_string))
        ) |
        (if (.session | type) == "object" then .session else {} end) as $env |
        ([.mode, .kind, (.app_id // ""), .job, (.forward_files != false | tostring), (.argv | length | tostring)] +
            .argv + [$ARGS.positional[] as $key | $env[$key] | select(safe_string) | "\($key)=\(.)"])[] |
        ., "\u0000"
    ' -- "${app_session_keys[@]}" <<< "$request")
    if (( ${#fields[@]} < 7 )); then
        fail 'The app request contained invalid launch information.'
        return
    fi
    mode=${fields[0]} app_kind=${fields[1]} app_id=${fields[2]}
    job=${fields[3]} forward_files=${fields[4]} argc=${fields[5]}
    args=("${fields[@]:6:argc}")
    session=("${fields[@]:6+argc}")
    user_entry=$(getent passwd "$account") || { fail 'The desktop account could not be found.'; return; }
    IFS=: read -r _ _ uid gid _ home _ <<< "$user_entry"
    [[ $uid =~ ^[0-9]+$ ]] && (( uid > 0 )) || return 1
    acquire && guard_init || { fail 'The app firewall could not be initialized.'; return; }
    if [[ -n $app_id ]]; then
        active_record=$run/active-$app_kind-$app_id
        if [[ -f $active_record ]]; then
            local running_mode
            read -r namespace app_iface running_mode work < "$active_record" || return 1
            if [[ -e $app_netns_dir/$namespace && -f $work/lease ]]; then
                [[ $mode == "$running_mode" ]] || { fail 'Close the running app before using a different VPN route.'; return; }
                exec {active_lease}<"$work/lease" || return 1
                flock -sn "$active_lease" || { fail 'The app is shutting down. Try opening it again.'; return; }
                [[ -f $active_record && $(< "$active_record") == "$namespace $app_iface $mode $work" ]] || return 1
                run_app_in_namespace || result=$?
                printf '%s\n' "$result" > "$run/result-$job"
                return "$result"
            fi
            rm -f -- "$active_record" || return 1
        fi
    fi
    work=$(mktemp -d "$run/app.XXXXXXXX") || return 1
    namespace="wv$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
    trap app_cleanup EXIT
    trap 'exit 143' TERM HUP INT
    : > "$work/vopono.toml"

    if [[ $mode == direct ]] || tunnel_exists; then
        if [[ $mode == direct ]]; then
            uplink=$(physical_link) || { fail 'No active physical IPv4 link was found.'; return; }
        else
            uplink=$iface
            use_host_tunnel=true
            if ! tunnel_is_up; then
                fail 'The host VPN tunnel is unavailable.'
                return
            fi
        fi
        mapfile -t dns < <(link_dns "$uplink")
        (("${#dns[@]}")) || { fail 'The selected uplink has no IPv4 DNS servers.'; return; }
        options=(--provider none --protocol none)
        for item in "${dns[@]}"; do options+=(--dns "$item"); done
    else
        if guard_armed || [[ -e $run/armed ]]; then
            fail 'Connect the host VPN before starting a VPN-only app while the kill switch is on.'
            return
        else
            uplink=$(physical_link) || { fail 'No active physical IPv4 link was found.'; return; }
        fi
        build_profile optimal "$work/walker.conf" >/dev/null ||
            { fail 'Could not register a WireGuard peer for this app.'; return; }
        options=(--provider custom --protocol wireguard --custom "$work/walker.conf")
    fi
    # A child must never inherit the advisory lock after setup.
    (
        exec {lock}>&-
        exec vopono exec "${options[@]}" --firewall nftables --disable-ipv6 \
            --vopono-config "$work/vopono.toml" --custom-netns-name "$namespace" \
            --interface "$uplink" --no-proxy --create-netns-only none
    ) </dev/null >"$work/vopono.log" 2>&1 &
    vpn_pid=$!
    marker="Created netns $namespace -"
    wait_start=$SECONDS
    until rg -q -F "$marker" "$work/vopono.log"; do
        if ! kill -0 "$vpn_pid" 2>/dev/null || (( SECONDS - wait_start >= 22 )); then
            # Backend diagnostics may contain provider or tunnel details.
            fail 'Vopono did not start the app namespace.'
            return
        fi
        sleep 0.1
    done
    app_policy || { fail 'Could not install the app isolation policy.'; return; }
    if [[ $app_kind == flatpak ]]; then
        mkdir "$work/monitor" || return 1
        for item in host.conf gai.conf hosts; do
            if [[ -f /etc/$item ]]; then cp "/etc/$item" "$work/monitor/$item" || return 1; fi
        done
        cp "/etc/netns/$namespace/resolv.conf" "$work/monitor/resolv.conf" || return 1
        chmod 755 "$work/monitor"
        chmod 444 "$work/monitor/"*
    fi
    if [[ -n $active_record ]]; then
        exec {active_lease}>"$work/lease" || return 1
        printf '%s %s %s %s\n' "$namespace" "$app_iface" "$mode" "$work" > "$active_record" || return 1
    fi
    run_app_in_namespace || result=$?
    wait_for_app_processes "$namespace" "$uid"
    trap - EXIT
    app_cleanup
    printf '%s\n' "$result" > "$run/result-$job"
    return "$result"
}

# Some desktop launchers detach the GUI and exit while it still needs the
# namespace. Track its members instead of the original launcher's lifetime.
wait_for_app_processes() {
    local namespace=$1 uid=$2 members pid key real_uid rest live_pid
    while members=$(ip netns pids "$namespace"); do
        live_pid=
        for pid in $members; do
            [[ $pid =~ ^[1-9][0-9]*$ && /proc/$pid/ns/net -ef $app_netns_dir/$namespace ]] || continue
            while read -r key real_uid rest; do
                [[ $key == Uid: ]] || continue
                if [[ $real_uid == "$uid" ]]; then live_pid=$pid; fi
                break
            done 2>/dev/null < "/proc/$pid/status"
            [[ -z $live_pid ]] || break
        done
        [[ -n $live_pid ]] || return 0
        # Keep watching the same process until another namespace scan is needed.
        while [[ /proc/$live_pid/ns/net -ef $app_netns_dir/$namespace ]]; do
            sleep 1
        done
    done
}

# A later launch holds a shared lease for as long as it uses the namespace.
# The creator takes an exclusive lease before removing its firewall or veth.
run_app_in_namespace() {
    release
    (
        if [[ -n $active_lease ]]; then exec {active_lease}>&-; fi
        exec ip netns exec "$namespace" bash "$lib/app-inside.sh" "$uid" "$gid" "$account" \
            "$home" "$namespace" "$app_iface" "$app_kind" "$app_id" "$work" "$forward_files" \
            "${#session[@]}" "${session[@]}" "${args[@]}"
    )
}
