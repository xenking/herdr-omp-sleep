#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

session="$tmp/branches.jsonl"
cat >"$session" <<'EOF'
{"type":"session","version":3,"id":"session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}
{"type":"message","id":"root","parentId":null,"timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":"shared-root"}}
{"type":"message","id":"a","parentId":"root","timestamp":"2026-01-01T00:00:02Z","message":{"role":"user","content":"branch-A-only"}}
{"type":"message","id":"b","parentId":"root","timestamp":"2026-01-01T00:00:03Z","message":{"role":"user","content":"branch-B-only"}}
EOF

rendered_a=$("$root/bin/omp-render" --md --leaf=a "$session")
[[ "$rendered_a" == *shared-root* ]] || { printf 'requested branch lost shared ancestor\n' >&2; exit 1; }
[[ "$rendered_a" == *branch-A-only* ]] || { printf 'requested branch missing\n' >&2; exit 1; }
[[ "$rendered_a" != *branch-B-only* ]] || { printf 'requested branch included sibling\n' >&2; exit 1; }

rendered_b=$("$root/bin/omp-render" --md --leaf=b "$session")
[[ "$rendered_b" == *branch-B-only* ]] || { printf 'second branch missing\n' >&2; exit 1; }
[[ "$rendered_b" != *branch-A-only* ]] || { printf 'second branch included sibling\n' >&2; exit 1; }

if "$root/bin/omp-render" --md "$session" >/dev/null 2>&1; then
	printf 'leafless branched session unexpectedly rendered\n' >&2
	exit 1
fi
if "$root/bin/omp-render" --md --leaf=missing "$session" >/dev/null 2>&1; then
	printf 'missing leaf unexpectedly rendered\n' >&2
	exit 1
fi

cat >"$tmp/cycle.jsonl" <<'EOF'
{"type":"message","id":"cycle-a","parentId":"cycle-b","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":"cycle-a"}}
{"type":"message","id":"cycle-b","parentId":"cycle-a","timestamp":"2026-01-01T00:00:02Z","message":{"role":"user","content":"cycle-b"}}
EOF
if "$root/bin/omp-render" --md --leaf=cycle-a "$tmp/cycle.jsonl" >/dev/null 2>&1; then
	printf 'cyclic ancestry unexpectedly rendered\n' >&2
	exit 1
fi

cat >"$tmp/missing-parent.jsonl" <<'EOF'
{"type":"message","id":"orphan","parentId":"gone","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":"orphan"}}
EOF
if "$root/bin/omp-render" --md --leaf=orphan "$tmp/missing-parent.jsonl" >/dev/null 2>&1; then
	printf 'missing ancestry unexpectedly rendered\n' >&2
	exit 1
fi

mkdir -p "$tmp/bin" "$tmp/home"
cat >"$tmp/bin/omp-render" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$RENDER_ARGS"
printf 'render %s\n' "$*"
EOF
cat >"$tmp/bin/less" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$LESS_ARGS"
exit 49
EOF
chmod +x "$tmp/bin/omp-render" "$tmp/bin/less"

run_frozen() {
	set +e
	HOME="$tmp/home" PI_CODING_AGENT_DIR="$tmp/home/.omp/agent" PATH="$tmp/bin:$PATH" RENDER_ARGS="$tmp/render.args" LESS_ARGS="$tmp/less.args" TERM=xterm \
		"$root/bin/omp-frozen" "$session" "$1" >/dev/null 2>&1
	rc=$?
	set -e
	[ "$rc" = 49 ] || { printf 'pager exit changed: %s\n' "$rc" >&2; exit 1; }
}

run_frozen a
shopt -s nullglob
views=("$tmp/home/.omp/agent/frozen/"*.ans.txt)
[ "${#views[@]}" = 2 ] || { printf 'first leaf cache count: %s\n' "${#views[@]}" >&2; exit 1; }
leaf_a_calls=$(grep -Fc -- '--leaf=a' "$tmp/render.args" || true)
[ "$leaf_a_calls" = 2 ] || { printf 'folded/unfolded leaf propagation: %s\n' "$leaf_a_calls" >&2; exit 1; }

run_frozen b
views=("$tmp/home/.omp/agent/frozen/"*.ans.txt)
[ "${#views[@]}" = 4 ] || { printf 'leaf cache identities reused: %s\n' "${#views[@]}" >&2; exit 1; }
leaf_b_calls=$(grep -Fc -- '--leaf=b' "$tmp/render.args" || true)
[ "$leaf_b_calls" = 2 ] || { printf 'second folded/unfolded leaf propagation: %s\n' "$leaf_b_calls" >&2; exit 1; }

printf 'branch-render: ok\n'
