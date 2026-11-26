#!/usr/bin/env bash
set -euo pipefail
handler=${BASH_SOURCE[0]%/*}/../bin/open-link
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OPENER_LOG=$scratch/opened
cat >"$scratch/opener" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$OPENER_LOG"
SH
chmod +x "$scratch/opener"
url='https://example.invalid/path?a=b&c=d'
[[ $(printf '%s\n' "$url" | bash "$handler" serve "$scratch/opener") == ok ]]
printf 'open\0%s\0' "$url" | cmp - "$OPENER_LOG"
rm "$OPENER_LOG"
for invalid in file:///etc/passwd '--help' 'https://example.invalid/unescaped space' ftp://example.invalid; do
    if printf '%s\n' "$invalid" | bash "$handler" serve "$scratch/opener"; then exit 1; fi
    [[ ! -e $OPENER_LOG ]]
done
printf -v long '%08200d' 0
if printf 'https://example.invalid/%s\n' "$long" | bash "$handler" serve "$scratch/opener"; then exit 1; fi
[[ ! -e $OPENER_LOG ]]
bash "$handler" client "$scratch/opener" false '/tmp/a local file'
printf '/tmp/a local file\0' | cmp - "$OPENER_LOG"
printf 'Web links preserve their arguments, non-web requests stay local, and the desktop rejects invalid input.\n'
