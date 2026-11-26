#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../lib/session-env.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/config" "$scratch/database/Etc"
touch "$scratch/database/Etc/UTC"
ln -s "$scratch/database" "$scratch/config/zoneinfo"
ln -s zoneinfo/Etc/UTC "$scratch/config/localtime"
[[ $(desktop_zoneinfo_dir "$scratch/config/localtime") == "$scratch/config/zoneinfo" ]]
ln -sf "$scratch/config/zoneinfo/Etc/UTC" "$scratch/config/localtime"
[[ $(desktop_zoneinfo_dir "$scratch/config/localtime") == "$scratch/config/zoneinfo" ]]
ln -sf '../config/./zoneinfo/Etc/UTC' "$scratch/config/localtime"
[[ $(desktop_zoneinfo_dir "$scratch/config/localtime") == "$scratch/config/zoneinfo" ]]
touch "$scratch/config/copied-localtime"
[[ $(TZDIR="$scratch/database" desktop_zoneinfo_dir "$scratch/config/copied-localtime") == "$scratch/database" ]]
printf 'Timezone detection preserves the host’s zoneinfo path through relative and absolute symlinks.\n'
