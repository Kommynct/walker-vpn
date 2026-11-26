desktop_data=${XDG_DATA_HOME:-$HOME/.local/share}
desktop_root=${XDG_STATE_HOME:-$HOME/.local/state}/walker-vpn/apps
command_dir=$desktop_root/bin

desktop_id() { [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,199}\.desktop$ ]]; }

desktop_roots() {
    local dir
    printf '%s\n' "$desktop_data/applications" \
        "$desktop_data/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications \
        "$desktop_root/commands"
    local -a dirs
    IFS=: read -ra dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    for dir in "${dirs[@]}"; do
        [[ -n $dir ]] && printf '%s/applications\n' "$dir"
    done
}

desktop_file() {
    local dir found
    while IFS= read -r dir; do
        found=$dir/$1
        if [[ -f $found ]]; then printf '%s\n' "$found"; return 0; fi
    done <<< "$(desktop_roots)"
    return 1
}

desktop_value() {
    awk -v key="$2" '
        /^\[/ { entry=($0 == "[Desktop Entry]") }
        entry && index($0, key "=") == 1 { print substr($0,length(key)+2); exit }
    ' "$1"
}

desktop_executable() {
    local rest=$1 token
    local pattern='^[[:space:]]*("([^"]+)"|([^[:space:]]+))[[:space:]]*(.*)$'
    while [[ $rest =~ $pattern ]]; do
        token=${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}
        rest=${BASH_REMATCH[4]}
        case "${token##*/}" in
            env|gamemoderun|prime-run|steam-run|--|-i|--ignore-environment|*=*) ;;
            -u|-C|--unset|--chdir)
                [[ $rest =~ $pattern ]] || return 1
                rest=${BASH_REMATCH[4]}
                ;;
            *) printf '%s\n' "$token"; return ;;
        esac
    done
    return 1
}

can_route_command() {
    [[ $1 =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]{0,150}$ ]] || return 1
    case "$1" in
        bash|dash|sh|fish|env|node|electron|java|perl|ruby|python|python3|flatpak|walker-vpn|\
        systemctl|systemd-run|sudo|run0|setpriv|jq|socat|nft|ip|wg|mount|flock|awk|rg|\
        cat|sleep|readlink|stat|chmod|mv|rm|mkdir|ps|busctl|gdbus|hyprctl|walker) return 1 ;;
    esac
}

unrouted_path() {
    local directory result=
    local -a paths
    IFS=: read -ra paths <<< "$PATH"
    for directory in "${paths[@]}"; do
        [[ -n $directory && $directory != "$command_dir" ]] || continue
        result+="${result:+:}$directory"
    done
    printf '%s\n' "$result"
}

flatpak_command() {
    local argument candidate id
    local real=${WALKER_VPN_FLATPAK:?}
    local -a original=("$@")
    while [[ ${1:-} == -v || ${1:-} == --verbose || ${1:-} == --ostree-verbose ]]; do
        shift
    done
    if [[ ${1:-} == run ]]; then
        for argument in "${@:2}"; do
            candidate=${argument#app/}
            candidate=${candidate%%/*}
            [[ $candidate =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$ ]] || continue
            id=$candidate.desktop
            if [[ -f $desktop_root/$id/mode && -f $desktop_root/$id/kind &&
                $(< "$desktop_root/$id/kind") == flatpak ]]; then
                if [[ $argument != "$2" || $argument != "$candidate" ]]; then
                    notify 'Use the managed launcher for this Flatpak with alternate run options.'
                    return 1
                fi
                WALKER_VPN_FLATPAK_OPTIONS=true desktop_launch "$id" -- "${@:3}"
                return
            fi
            break
        done
    fi
    exec "$real" "${original[@]}"
}

app_processes() {
    local id=${1%.desktop} kind=$2 source=$3 running exec_line program resolved name
    local pid state comm argument scope own_scope response roots
    local -A names=() matches=()
    if [[ $kind == flatpak ]]; then
        running=$(flatpak ps --columns=application:f,child-pid) || return 2
        roots=$(awk -v id="$id" '$1==id { print ($2 ~ /^[1-9][0-9]+$/ ? $2 : 0) }' <<< "$running")
        [[ -n $roots ]] || return 0
        running=$(ps -u "$UID" -o pid=,ppid=,state=) || return 2
        # Include the actual app and any nested children under the sandbox PID.
        awk -v roots="$roots" '
            BEGIN {
                n=split(roots,lines,"\n")
                for(i=1;i<=n;i++) if (lines[i]>1) targets[lines[i]]=1
            }
            $3!="Z" { parent[$1]=$2 }
            END {
                for (pid in parent) {
                    p=pid
                    while (p>1 && !(p in targets) && (p in parent)) p=parent[p]
                    if (p in targets) {
                        print pid
                        found[p]=1
                    }
                }
                # Keep waiting if Flatpak lists an instance during teardown.
                for (p in targets) if (!(p in found)) missing=1
                if (missing || n!=length(targets)) print 0
            }
        ' <<< "$running"
        return 0
    fi

    exec_line=$(desktop_value "$source" Exec)
    exec_line=${exec_line#"walker-vpn desktop $1 -- "}
    program=$(desktop_executable "$exec_line") || program=
    case "${program##*/}" in
        bash|dash|sh|fish|node|electron|java|perl|ruby|python|python3) program= ;;
    esac
    resolved=$(type -P -- "$program") || resolved=
    for name in "$id" "${id##*.}" "${program##*/}" "$(desktop_value "$source" StartupWMClass)"; do
        [[ -n $name ]] && names[${name,,}]=1
    done
    if [[ $id == *.* && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && command -v busctl >/dev/null; then
        response=$(busctl --user --timeout=1s call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus GetConnectionUnixProcessID s "$id" 2>/dev/null) || response=
        if [[ $response =~ ^u\ ([1-9][0-9]+)$ && -O /proc/${BASH_REMATCH[1]} ]]; then
            matches[${BASH_REMATCH[1]}]=1
        fi
    fi

    IFS= read -r own_scope < /proc/self/cgroup || own_scope=
    running=$(ps -u "$UID" -o pid=,state=,comm=) || return 2
    while read -r pid state comm; do
        [[ -n $pid && $state != Z ]] || continue
        if [[ -n $resolved && /proc/$pid/exe -ef $resolved ]]; then matches[$pid]=1; continue; fi
        argument=
        { IFS= read -r -d '' argument < "/proc/$pid/cmdline"; } 2>/dev/null || :
        for name in "$comm" "${argument##*/}"; do
            name=${name#.}
            name=${name%-wrapped}
            if [[ -n $name && ${names[${name,,}]:-} ]]; then matches[$pid]=1; break; fi
        done
        if { IFS= read -r scope < "/proc/$pid/cgroup"; } 2>/dev/null &&
            [[ $scope != "$own_scope" && ( $scope == */app-"$id"-*.scope || $scope == */app-"$id"@*.service ) ]]; then
            matches[$pid]=1
        fi
    done <<< "$running"
    if (( ${#matches[@]} )); then printf '%s\n' "${!matches[@]}"; fi
}

app_closed() {
    local running
    running=$(app_processes "$@") || return 2
    [[ -z $running ]]
}

app_windows() {
    [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null || return 0
    local clients
    clients=$(hyprctl -j clients 2>/dev/null) || return 1
    jq -r --arg pids "$1" '($pids | split("\n") | map(tonumber)) as $targets |
        .[] | select(.pid as $pid | $targets | index($pid)) |
        .address | select(test("^0x[0-9a-fA-F]+$"))' <<< "$clients"
}

open_app_lock() {
    mkdir -p -- "$desktop_root/locks" &&
        exec {app_lock}>"$desktop_root/locks/$1"
}

close_app_before_change() {
    local id=$1 kind=$2 source=$3 name=$4 reply running windows pid address
    local deadline=0 requested_windows=false locked
    local -A signaled=()
    while :; do
        locked=false
        if flock -n "$app_lock"; then locked=true; fi
        running=$(app_processes "$id" "$kind" "$source") || {
            notify "Could not verify that $name is closed."
            return 2
        }
        if [[ $locked == true ]]; then
            if [[ -z $running ]]; then return 0; fi
            flock -u "$app_lock" || return 1
        fi
        if (( deadline == 0 )); then
            reply=$(choose "Close $name and change its VPN routing? Save your work first" \
                'Close app and apply' 'Cancel') || return 2
            [[ $reply == 0 ]] || return 2
            deadline=$(( SECONDS + 15 ))
            continue
        fi
        if (( SECONDS >= deadline )); then
            notify "$name is still running. Its VPN routing was not changed."
            return 2
        fi
        if [[ -n $running ]]; then
            windows=$(app_windows "$running") || {
                notify "Could not check $name's windows. Its VPN routing was not changed."
                return 2
            }
            if [[ -n $windows ]]; then
                if [[ $requested_windows == false ]]; then
                    while read -r address; do
                        hyprctl dispatch "hl.dsp.window.close({ window = [[address:$address]] })" >/dev/null 2>&1 ||
                            hyprctl dispatch closewindow "address:$address" >/dev/null 2>&1 || :
                    done <<< "$windows"
                    requested_windows=true
                fi
            else
                while read -r pid; do
                    [[ $pid =~ ^[1-9][0-9]+$ && -O /proc/$pid && ! ${signaled[$pid]:-} ]] || continue
                    kill -TERM "$pid" 2>/dev/null || :
                    signaled[$pid]=1
                done <<< "$running"
            fi
        fi
        sleep .25
    done
}

flatpak_network() {
    local id=$1 path=$desktop_data/flatpak/overrides/$1
    if [[ -f $path ]]; then
        awk '
            /^\[/ { ctx=($0=="[Context]") }
            ctx && /^shared=/ {
                count=split(substr($0,8), parts, ";")
                for (i=1; i<=count; i++) if (parts[i]=="network" || parts[i]=="!network") print parts[i]
            }
        ' "$path"
    fi
}

flatpak_executable() {
    local metadata
    metadata=$(flatpak info --show-metadata "$1") || return 1
    awk '
        /^\[/ { app=($0=="[Application]") }
        app && /^command=./ { print substr($0,9); found=1; exit }
        END { if (!found) exit 1 }
    ' <<< "$metadata"
}

restore_network() {
    local id=$1 old=$2 path=$desktop_data/flatpak/overrides/$1 temporary
    [[ -f $path ]] || return 0
    temporary=$(mktemp "${path}.walker.XXXXXXXX") || return 1
    if ! awk -v old="$old" '
        /^\[/ { ctx=($0=="[Context]") }
        ctx && /^shared=/ {
            n=split(substr($0,8), parts, ";"); result=""
            for (i=1; i<=n; i++)
                if (parts[i]!="" && parts[i]!="network" && parts[i]!="!network")
                    result=result parts[i] ";"
            if (old!="") result=result old ";"
            if (result!="") print "shared=" result
            next
        }
        { print }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -f -- "$temporary" "$path"
}

restore_desktop_files() (
    local id=$1 record target current kind old
    desktop_id "$id" || return 1
    record=$desktop_root/$id
    target=$desktop_data/applications/$id
    [[ -f $record/kind ]] || return 0
    if [[ -e $desktop_root/commands/$id ]]; then target=$record/launcher; fi
    kind=$(< "$record/kind")
    # Preserve any launcher edits made since enabling app routing.
    if [[ -f $target ]] && ! cmp -s "$target" "$record/generated"; then
        notify 'This desktop file was edited. Restore or move it before removing VPN routing.'
        return 1
    fi
    if [[ $kind == flatpak && -f $record/network ]]; then
        old=$(< "$record/network")
        if [[ $(flatpak_network "${id%.desktop}") == '!network' ]]; then
            restore_network "${id%.desktop}" "$old" || return 1
        fi
    fi
    if [[ -f $record/original ]]; then
        cp -p -- "$record/original" "$target" || return 1
    else
        rm -f -- "$target" || return 1
    fi
    if [[ -s $record/command-shim ]]; then
        rm -f -- "$command_dir/$(< "$record/command-shim")" || return 1
    fi
    rm -rf -- "$record"
)

restore_desktop() (
    local id=$1 record source kind app_lock desktop_lock
    desktop_id "$id" || return 1
    record=$desktop_root/$id
    [[ -f $record/kind ]] || return 0
    exec {desktop_lock}>"$desktop_root/.lock"
    flock "$desktop_lock" || return 1
    [[ -f $record/kind ]] || return 0
    kind=$(< "$record/kind")
    source=$(desktop_file "$id") || source=$record/generated
    open_app_lock "$id" || return 1
    if ! flock -n "$app_lock" || ! app_closed "$id" "$kind" "$source"; then
        notify "Quit ${id%.desktop} completely before restoring its routing."
        return 1
    fi
    restore_desktop_files "$id"
)

install_desktop() (
    local id=$1 mode=$2 source kind=native target record command name app_lock desktop_lock shim=
    desktop_id "$id" && [[ $mode == vpn || $mode == direct || $mode == default ]] || return 1
    mkdir -p -- "$desktop_root" "$desktop_data/applications" || return 1
    exec {desktop_lock}>"$desktop_root/.lock"
    flock "$desktop_lock" || return 1
    record=$desktop_root/$id
    if [[ $mode == default && ! -f $record/mode ]]; then return 0; fi
    if [[ -f $record/mode && $(< "$record/mode") == "$mode" ]]; then return 0; fi
    target=$desktop_data/applications/$id
    source=$(desktop_file "$id") || { [[ -f $record/generated ]] && source=$record/generated; } || return 1
    name=$(desktop_value "$source" Name)
    if [[ -f $record/kind ]]; then
        kind=$(< "$record/kind")
    elif [[ $(desktop_value "$source" Exec) =~ (^|[[:space:]/])flatpak[[:space:]]+run[[:space:]] ]] &&
        flatpak info "${id%.desktop}" >/dev/null 2>&1; then
        kind=flatpak
    fi
    open_app_lock "$id" || return 1
    close_app_before_change "$id" "$kind" "$source" "${name:-${id%.desktop}}" || return $?
    if [[ -f $record/mode ]]; then
        if [[ $mode == default ]]; then restore_desktop_files "$id"; return; fi
        if [[ -e $desktop_root/commands/$id ]]; then source=$record/launcher; fi
        if ! cmp -s "$source" "$record/generated"; then
            notify 'The managed launcher changed. Restore it before switching routing.'
            return 1
        fi
        if [[ $kind == flatpak ]]; then
            flatpak override --user --unshare=network "${id%.desktop}" || return 1
        fi
        local next_mode
        next_mode=$(mktemp "$record/.mode.XXXXXXXX") || return 1
        if printf '%s\n' "$mode" > "$next_mode" && mv -f -- "$next_mode" "$record/mode"; then
            return 0
        fi
        rm -f -- "$next_mode"
        return 1
    fi
    source=$(desktop_file "$id") || return 1
    if [[ $source == "$desktop_root/commands/$id" ]]; then target=$record/launcher; fi
    [[ $(desktop_value "$source" Hidden) != true && $(desktop_value "$source" Terminal) != true ]] || return 1
    command=$(desktop_value "$source" Exec)
    [[ -n $command ]] || return 1
    if [[ $kind == flatpak ]]; then
        flatpak_executable "${id%.desktop}" >/dev/null || return 1
    else
        shim=$(desktop_executable "$command") || shim=
        shim=${shim##*/}
        can_route_command "$shim" || shim=
        if [[ -n $shim && -e $command_dir/$shim ]]; then
            notify "Another saved routing policy already owns the $shim command."
            return 1
        fi
    fi
    mkdir -- "$record" || return 1
    trap 'if [[ -n $shim ]]; then rm -f -- "$command_dir/$shim"; fi; rm -rf -- "$record"' EXIT
    printf '%s\n' "$kind" > "$record/kind"
    printf '%s\n' "$mode" > "$record/mode"
    if [[ -e $target ]]; then cp -L -p -- "$target" "$record/original" || return 1; fi
    if [[ $kind == flatpak ]]; then
        flatpak_network "${id%.desktop}" > "$record/network"
        command='%U'
    elif [[ -n $shim ]]; then
        mkdir -p "$command_dir" || return 1
        printf '%s\n' "$shim" > "$record/command-shim" || return 1
        printf '#!/usr/bin/env bash\nexec walker-vpn desktop %q -- %q "$@"\n' \
            "$id" "$shim" > "$command_dir/$shim" && chmod 700 "$command_dir/$shim" || return 1
    fi
    awk -v id="$id" -v kind="$kind" -v flatpak_exec="$command" '
        /^\[/ { entry=($0 == "[Desktop Entry]") }
        /^\[Desktop Action / { action=1 }
        entry && /^DBusActivatable=/ { next }
        entry && /^Actions=/ { next }
        entry && /^Exec=/ {
            exec_line=(kind=="flatpak" ? flatpak_exec : substr($0,6))
            print "Exec=walker-vpn desktop " id " -- " exec_line
            next
        }
        entry && /^\[Desktop Entry\]$/ {
            print; print "DBusActivatable=false"; print "X-Walker-VPN-Managed=true"; next
        }
        !action { print }
    ' "$source" > "$record/generated" || return 1
    temporary=$(mktemp "$desktop_data/applications/.walker.XXXXXXXX") || return 1
    if [[ $kind == flatpak ]] && ! flatpak override --user --unshare=network "${id%.desktop}"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! cp -- "$record/generated" "$temporary" || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        if [[ $kind == flatpak ]]; then restore_network "${id%.desktop}" "$(< "$record/network")"; fi
        return 1
    fi
    trap - EXIT
    if [[ $target == "$desktop_data/applications/"* ]] && command -v update-desktop-database >/dev/null; then
        update-desktop-database "$desktop_data/applications" || :
    fi
)

desktop_launch() (
    local id=${1:-} record kind mode source app_lock executable managed_command
    [[ ${2:-} == -- ]] && desktop_id "$id" || return 2
    shift 2
    open_app_lock "$id" || return 1
    flock -n "$app_lock" || return 1
    record=$desktop_root/$id
    if [[ ! -f $record/mode || ! -f $record/kind ]]; then
        notify 'Enable the VPN-only policy for this app in Walker before launching it.'
        return 1
    fi
    kind=$(< "$record/kind")
    mode=$(< "$record/mode")
    if [[ -n ${required_mode:-} && $mode != "$required_mode" ]]; then
        notify 'This launch requires the app’s VPN-only policy.'
        return 1
    fi
    source=$(desktop_file "$id") || source=$record/generated
    if ! app_closed "$id" "$kind" "$source"; then
        notify 'Quit the existing app completely before launching it with VPN routing.'
        return 1
    fi
    if [[ $kind == flatpak ]]; then
        if ! executable=$(flatpak_executable "${id%.desktop}"); then
            notify 'Could not read the installed Flatpak’s launch command.'
            return 1
        fi
        gdbus call --session --dest org.freedesktop.Flatpak \
            --object-path /org/freedesktop/Flatpak/SessionHelper \
            --method org.freedesktop.Flatpak.SessionHelper.RequestSession >/dev/null ||
            { notify 'Flatpak could not initialize its DNS monitor.'; return 1; }
        run_protected "$mode" flatpak "${id%.desktop}" "$executable" "$@" </dev/null ||
            { notify 'Could not launch the Flatpak with its network policy.'; return 1; }
    else
        # An older desktop override may still point into the previous system closure.
        if [[ ${1:-} == /nix/store/*/bin/* && -s $record/command-shim ]]; then
            managed_command=$(< "$record/command-shim")
            if [[ ${1##*/} == "$managed_command" && -x /run/current-system/sw/bin/$managed_command ]]; then
                shift
                set -- "/run/current-system/sw/bin/$managed_command" "$@"
            fi
        fi
        run_protected "$mode" native "${id%.desktop}" "$@" </dev/null ||
            { notify 'Could not launch the application with its network policy.'; return 1; }
    fi
)

choose_app_route() {
    local id=$1 name=$2 current=default pick i
    local -a modes=(default vpn direct)
    local -a labels=('Follow system VPN' 'VPN only' 'Exclude from VPN · use regular internet')
    if [[ -f $desktop_root/$id/mode ]]; then current=$(< "$desktop_root/$id/mode"); fi
    for i in "${!modes[@]}"; do
        if [[ ${modes[i]} == "$current" ]]; then labels[i]+=' · Current'; fi
    done
    pick=$(choose "$name · Network route" "${labels[@]}") || return 2
    [[ $pick =~ ^[012]$ ]] || return 2
    printf '%s\n' "${modes[pick]}"
}

command_menu() {
    local mode path command id file picked
    local -a commands=()
    for path in /run/current-system/sw/bin/*; do
        command=${path##*/}
        [[ -f $path && -x $path ]] && can_route_command "$command" || continue
        commands+=("$command")
    done
    (("${#commands[@]}")) || return 2
    picked=$(choose 'Installed system commands' "${commands[@]}") || return 2
    [[ $picked =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( picked < ${#commands[@]} )) || return 2
    command=${commands[picked]}
    id=walker-vpn-command.$command.desktop
    mode=$(choose_app_route "$id" "$command") || return 2
    [[ $mode != default || -f $desktop_root/$id/mode ]] || return 0
    # A launcher for command-only packages is internal to Walker VPN.
    mkdir -p "$desktop_root/commands" || return 1
    file=$desktop_root/commands/$id
    if [[ ! -e $file ]]; then
        printf '[Desktop Entry]\nName=%s\nType=Application\nExec=%s\n' "$command" "$command" > "$file" || return 1
    fi
    install_desktop "$id" "$mode"
}

app_menu() {
    local mode dir file id name pick current
    local -a ids=() names=() files=()
    local -A seen=()
    local -a managed_ids=() managed_names=()
    while IFS= read -r dir; do
        for file in "$dir/"*.desktop; do
            [[ -f $file ]] || continue
            id=${file##*/}
            desktop_id "$id" && [[ ! -v seen[$id] ]] || continue
            seen[$id]=1
            files+=("$file")
        done
    done < <(desktop_roots)
    if (( ${#files[@]} )); then
        while IFS=$'\t' read -r id name; do
            current=
            if [[ -f $desktop_root/$id/mode ]]; then
                current=$(< "$desktop_root/$id/mode")
                if [[ $current == vpn ]]; then current=' · VPN-only'; else current=' · Excluded'; fi
            fi
            if [[ -n $current ]]; then
                managed_ids+=("$id")
                managed_names+=("$name$current")
            else
                ids+=("$id")
                names+=("$name")
            fi
        done < <(awk '
            BEGINFILE { delete values; entry=0 }
            /^\[/ { entry=($0=="[Desktop Entry]") }
            entry && /^(Hidden|NoDisplay|Terminal|Exec|Name)=/ {
                key=substr($0,1,index($0,"=")-1)
                if (!(key in values)) values[key]=substr($0,length(key)+2)
            }
            ENDFILE {
                if (values["Hidden"]!="true" && values["NoDisplay"]!="true" &&
                    values["Terminal"]!="true" && length(values["Exec"]) && length(values["Name"])) {
                    id=FILENAME
                    sub(/^.*\//,"",id)
                    gsub(/[[:cntrl:]]/," ",values["Name"])
                    print id "\t" values["Name"]
                }
            }
        ' "${files[@]}")
    fi
    ids=("${managed_ids[@]}" "${ids[@]}")
    names=("${managed_names[@]}" "${names[@]}")
    pick=$(choose 'Choose an app to route' "${names[@]}" 'Installed system commands…') || return 0
    [[ $pick =~ ^(0|[1-9][0-9]{0,4})$ ]] && (( pick <= ${#ids[@]} )) || return 1
    local result=0
    if (( pick == ${#ids[@]} )); then
        command_menu || result=$?
    else
        mode=$(choose_app_route "${ids[pick]}" "${names[pick]%% · *}") || return 0
        install_desktop "${ids[pick]}" "$mode" || result=$?
    fi
    case $result in
        0|2) return 0 ;;
        *) notify 'Could not update app routing.'; return 1 ;;
    esac
}

restore_all() {
    local entry result=0
    for entry in "$desktop_root/"*.desktop; do
        [[ -d $entry ]] || continue
        restore_desktop "${entry##*/}" || result=1
    done
    return "$result"
}
