#!/usr/bin/env bash
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_DATA_HOME=$scratch/data XDG_STATE_HOME=$scratch/state
source "${BASH_SOURCE[0]%/*}/../lib/desktop.sh"

app=org.example.App
record=$desktop_root/$app.desktop
mkdir -p "$record"
printf '%s\n' flatpak > "$record/kind"
printf '%s\n' old-cached-command > "$record/command"

flatpak() {
    [[ $* == "info --show-metadata $app" ]]
    cat "$scratch/metadata"
}
app_closed() { return 0; }
gdbus() { return 0; }
notify() { printf '%s\n' "$*" >&2; }
run_protected() { printf '%s\n' "$@" > "$scratch/launch"; }

for mode in vpn direct; do
    printf '%s\n' "$mode" > "$record/mode"
    for executable in original-command updated-command; do
        printf '[Application]\ncommand=%s\n' "$executable" > "$scratch/metadata"
        desktop_launch "$app.desktop" -- 'two words'
        mapfile -t launch < "$scratch/launch"
        [[ ${#launch[@]} == 5 && ${launch[0]} == "$mode" && ${launch[1]} == flatpak &&
            ${launch[2]} == "$app" && ${launch[3]} == "$executable" && ${launch[4]} == 'two words' ]]
    done
done

rm -- "$scratch/launch"
printf '[Runtime]\ncommand=wrong-section\n' > "$scratch/metadata"
if desktop_launch "$app.desktop" -- 2>/dev/null || [[ -e $scratch/launch ]]; then
    exit 1
fi
printf 'Flatpak updates preserve both routing modes and use the new executable.\n'
