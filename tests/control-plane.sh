#!/usr/bin/env bash
set -euo pipefail
lib=$(cd -- "${BASH_SOURCE[0]%/*}/../lib" && pwd)
source "$lib/guard.sh"
source "$lib/pia.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
nft() { cat "$scratch/rules"; }
for chain in output forward; do
    jq -nc --arg chain "$chain" '{rule:{chain:$chain,expr:[{jump:{target:("block_"+$chain)}}]}}' > "$scratch/$chain"
    jq -s '{nftables:.}' "$scratch/$chain" > "$scratch/rules"
    if guard_armed; then exit 1; fi
done
jq -s '{nftables:.}' "$scratch/output" "$scratch/forward" > "$scratch/rules"
guard_armed
wg() { printf '%s\n' dummy; }
key=$(printf 'A%.0s' {1..43})=
api_request() {
    cat >/dev/null
    jq -nc --arg key "$key" '{status:"OK",peer_pubkey:"dummy",peer_ip:"10.1.1.2",server_ip:"192.0.2.1",
        server_port:51820,server_key:$key,dns_servers:["10.1.1.1","10.1.1.3"]}'
}
catalog='[{"id":"test","servers":{"wg":[{"cn":"example.invalid","ip":"192.0.2.1"}]}}]'
pia_profile "$catalog" test dummy "$scratch/profile" >/dev/null
rg -Fxq 'DNS = 10.1.1.1, 10.1.1.3' "$scratch/profile"
if pia_profile "$catalog" test dummy /dev/full >/dev/null 2>&1; then exit 1; fi
printf 'Firewall status and profile generation checks passed.\n'
