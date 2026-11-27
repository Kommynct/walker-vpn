#!/usr/bin/env bash
set -euo pipefail
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME=$scratch/state XDG_DATA_HOME=$scratch/data
source "${BASH_SOURCE[0]%/*}/../lib/desktop.sh"
id=org.example.Policy.desktop
record=$desktop_root/$id
mkdir -p "$record" "$desktop_data/applications"
launcher=$desktop_data/applications/$id
printf '[Desktop Entry]\nName=Test\nExec=walker-vpn desktop %s -- %%U\n' "$id" > "$launcher"
cp "$launcher" "$record/generated"
printf 'flatpak\n' > "$record/kind"
printf 'vpn\n' > "$record/mode"
close_app_before_change() { return 0; }
flatpak() { return 1; }
if install_desktop "$id" direct; then exit 1; fi
[[ $(< "$record/mode") == vpn ]]
cmp "$launcher" "$record/generated"
flatpak() { return 0; }
install_desktop "$id" direct
[[ $(< "$record/mode") == direct ]]
cmp "$launcher" "$record/generated"
printf 'Failed and successful mode changes preserve the managed launcher.\n'

choose_app_route() { printf 'vpn\n'; }
choose_vpn_region() {
    [[ $1 == 'Test · VPN location' && $2 == "$expected_region" ]]
    printf '%s\n' "$next_region"
}
expected_region=host next_region=example-region
configure_app_route "$id" "$id" Test
[[ $(< "$record/mode") == vpn && $(< "$record/region") == example-region ]]
flatpak() { return 1; }
expected_region=example-region next_region=host
configure_app_route "$id" "$id" Test
[[ $(< "$record/region") == host ]]
cmp "$launcher" "$record/generated"
printf 'The menu saves a VPN location and can restore the system location without rewriting the launcher.\n'
