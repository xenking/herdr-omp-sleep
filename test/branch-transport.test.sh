#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

agent="$tmp/agent"
state="$agent/frozen"
old="$tmp/old.jsonl"
new="$tmp/forked.jsonl"
DEAD="$tmp/dead"
OMP_ARGS="$tmp/omp.args"
OMP_ENV="$tmp/omp.env"
FROZEN_ARGS="$tmp/frozen.args"
mkdir -p "$state" "$agent/extensions" "$tmp/bin" "$tmp/home"
: >"$old"
cat >"$new" <<'EOF'
{"type":"message","id":"turn","parentId":null,"timestamp":"2020-01-01T00:00:00Z","message":{"role":"user","content":"fork"}}
EOF
touch -t 202001010000 "$new"
printf 'extension\n' >"$agent/extensions/sleep-state.ts"

# The fake omp is a real process for the reaper leg and an argv/env recorder for
# the wrapper leg. It never touches a real OMP session.
cat >"$tmp/bin/omp" <<'EOF'
#!/bin/bash
if [ "${LIVE_FIXTURE:-0}" = 1 ]; then
  trap 'printf dead >"$DEAD"; exit 0' TERM INT
  while :; do
    if [ -s "$STATE/p.session" ] && [ -s "$STATE/p.cursor.json" ]; then
      jq '.checkpointed = true' "$STATE/p.cursor.json" >"$STATE/ack.tmp"
      mv "$STATE/ack.tmp" "$STATE/p.cursor.json"
    fi
    sleep 1
  done
fi
{
  printf '%s\n' "$@"
} >"$OMP_ARGS"
printf 'HERDR_ENV=%s\nOMP_SLEEP_RESUME_SESSION=%s\nOMP_SLEEP_RESUME_LEAF=%s\n' \
  "${HERDR_ENV:-}" "${OMP_SLEEP_RESUME_SESSION:-}" "${OMP_SLEEP_RESUME_LEAF:-}" >"$OMP_ENV"
EOF
chmod +x "$tmp/bin/omp"

cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/bash
if [ "$1 $2" = 'api snapshot' ]; then
  printf '%s\n' '{"result":{"snapshot":{"focused_pane_id":null}}}'
elif [ "$1 $2" = 'agent list' ]; then
  printf '%s\n' '{"result":{"agents":[{"pane_id":"p","agent":"omp","agent_status":"idle","agent_session":{"value":"old"},"display_agent":false}]}}'
elif [ "$1 $2" = 'pane list' ]; then
  printf '%s\n' '{"result":{"panes":[{"pane_id":"p","cwd":"/tmp","terminal_title":">"}]}}'
elif [ "$1 $2" = 'pane process-info' ]; then
  if [ -e "$DEAD" ]; then
    printf '%s\n' '{"result":{"process_info":{"foreground_processes":[]}}}'
  else
    printf '{"result":{"process_info":{"foreground_processes":[{"pid":%s,"cmdline":"%s/bin/omp --resume=%s"}]}}}\n' \
      "$TARGET_PID" "$TMP_ROOT" "$OLD_PATH"
  fi
fi
EOF
chmod +x "$tmp/bin/herdr"

DEAD="$tmp/dead" STATE="$state" TMP_ROOT="$tmp" OLD_PATH="$old" \
  LIVE_FIXTURE=1 "$tmp/bin/omp" --resume="$old" &
target_pid=$!
trap 'kill "$target_pid" 2>/dev/null || true; wait "$target_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
now_ms=$(( $(date +%s) * 1000 ))
cat >"$state/p.live.$target_pid.json" <<EOF
{"version":1,"pid":$target_pid,"sessionFile":"$new","sessionId":"forked","leafId":"leaf-b","updatedAt":$now_ms}
EOF

# The live snapshot wins over stale startup argv; TERM follows acknowledgement.
HOME="$tmp/home" PI_CODING_AGENT_DIR="$agent" PATH="$tmp/bin:$PATH" \
  DEAD="$DEAD" TMP_ROOT="$tmp" OLD_PATH="$old" TARGET_PID="$target_pid" \
  IDLE_MIN=0 EMPTY_MIN=0 HERDR_PANE_ID=p HERDR_SOCKET_PATH="$tmp/home/.config/herdr/herdr.sock" \
  "$root/bin/omp-reap-idle" --pane p >/dev/null 2>&1
wait "$target_pid" 2>/dev/null || true
[[ "$(jq -r '.sessionFile' "$state/p.cursor.json")" == "$new" ]]
[[ "$(jq -r '.leafId' "$state/p.cursor.json")" == leaf-b ]]
[[ "$(jq -r '.checkpointed' "$state/p.cursor.json")" == true ]]
[[ "$(cat "$state/p.session")" == "$new" ]]

# A completed cursor remains authoritative even when a parked caller carries
# the old --resume path. The wrapper emits the exact leaf to frozen and OMP.
printf 'parked\n' >"$state/p.ans"
cat >"$tmp/bin/omp-frozen" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FROZEN_ARGS"
exit 0
EOF
cat >"$tmp/bin/shellstub" <<'EOF'
#!/bin/bash
printf shell >"$SHELL_RESULT"
EOF
chmod +x "$tmp/bin/omp-frozen" "$tmp/bin/shellstub"

OMP_ARGS="$tmp/omp.args" OMP_ENV="$tmp/omp.env" FROZEN_ARGS="$tmp/frozen.args" \
  SHELL_RESULT="$tmp/shell.result" HOME="$tmp/home" PI_CODING_AGENT_DIR="$agent" \
  PATH="$tmp/bin:$PATH" HERDR_PANE_ID=p HERDR_SOCKET_PATH="$tmp/missing.sock" \
  SHELL="$tmp/bin/shellstub" "$root/bin/omp-pane" --parked --resume="$old" >/dev/null 2>&1
[[ "$(sed -n '1p' "$FROZEN_ARGS")" == "$new" ]]
[[ "$(sed -n '2p' "$FROZEN_ARGS")" == leaf-b ]]
[[ "$(sed -n '1p' "$OMP_ARGS")" == "--resume=$new" ]]
[[ "$(sed -n '2p' "$OMP_ARGS")" == -e ]]
[[ "$(sed -n '3p' "$OMP_ARGS")" == "$agent/extensions/sleep-state.ts" ]]
[[ "$(sed -n '4p' "$OMP_ARGS")" == /omp-sleep-resume ]]
[[ "$(sed -n '1p' "$OMP_ENV")" == HERDR_ENV=1 ]]
[[ "$(sed -n '2p' "$OMP_ENV")" == OMP_SLEEP_RESUME_SESSION=forked ]]
[[ "$(sed -n '3p' "$OMP_ENV")" == OMP_SLEEP_RESUME_LEAF=leaf-b ]]

# A missing cursor is not permission to resume the sibling named by argv or
# the plain hint; the wrapper returns to the shell without invoking omp.
sibling="$tmp/sibling.jsonl"
: >"$sibling"
printf '%s' "$sibling" >"$state/p.session"
printf 'parked\n' >"$state/p.ans"
rm -f "$state/p.cursor.json" "$tmp/omp.args" "$tmp/omp.env" "$tmp/shell.result"
OMP_ARGS="$tmp/omp.args" OMP_ENV="$tmp/omp.env" SHELL_RESULT="$tmp/shell.result" \
  HOME="$tmp/home" PI_CODING_AGENT_DIR="$agent" PATH="$tmp/bin:$PATH" \
  HERDR_PANE_ID=p HERDR_SOCKET_PATH="$tmp/missing.sock" SHELL="$tmp/bin/shellstub" \
  "$root/bin/omp-pane" --parked --resume="$sibling" >/dev/null 2>&1
[[ ! -e "$tmp/omp.args" ]]
[[ -e "$tmp/shell.result" ]]

printf 'branch-transport: ok\n'
