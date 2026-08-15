#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/omp" <<'EOF'
#!/bin/bash
printf '%s' "${HERDR_ENV:-}" >"$RESULT"
EOF
chmod +x "$tmp/bin/omp"

PATH="$tmp/bin:$PATH" RESULT="$tmp/herdr-env" HERDR_ENV= HERDR_PANE_ID=test HERDR_SOCKET_PATH="$tmp/missing.sock" \
  "$root/bin/omp-pane"
[ "$(cat "$tmp/herdr-env")" = "1" ]
