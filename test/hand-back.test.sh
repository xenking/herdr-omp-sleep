#!/bin/bash
# hand_back() decides whether exiting returns the user to a prompt or ends the
# pane. Wrong in one direction it costs a nested shell; wrong in the other it
# closes the pane and can take a one-pane workspace with it (2026-09-03: 13
# panes, 8 workspaces). The discriminator is argv[0] of the parent — a login
# shell is `-zsh` — so this pins the field, because `ps -o comm=` strips the
# dash and matches every `sh -c` herdr may put in between.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/.omp/agent/frozen"

# Stands in for the login shell hand_back execs. Running is the observable.
cat >"$tmp/bin/shellstub" <<'EOF'
#!/bin/bash
printf exec >"$RESULT"
EOF
chmod +x "$tmp/bin/shellstub"

# `; :` keeps bash from exec-optimising the wrapper into the parent, which would
# leave the wrapper with no parent at all and test nothing.
handed() {
	: >"$tmp/result"
	HOME="$tmp" PATH="$tmp/bin:$PATH" RESULT="$tmp/result" SHELL="$tmp/bin/shellstub" \
		HERDR_PANE_ID=hbtest HERDR_SOCKET_PATH="$tmp/missing.sock" \
		bash -c "exec -a '$1' bash -c '\"$root/bin/omp-pane\" --parked --resume=$tmp/gone.jsonl; :'" \
		>/dev/null 2>&1 || true
	printf '%s' "$(cat "$tmp/result")"
}

# A login shell is underneath: exiting lands on the prompt it already had.
got=$(handed -zsh)
[ -z "$got" ] || {
	printf 'login-shell parent: expected exit, wrapper exec-ed a shell\n' >&2
	exit 1
}

# Nobody usable underneath (herdr's own command-pane spawn, with or without an
# intervening `sh -c`): becoming the shell is what keeps the pane alive.
for argv0 in bash sh /bin/sh herdr; do
	got=$(handed "$argv0")
	[ "$got" = exec ] || {
		printf 'parent %s: expected exec, got %s\n' "$argv0" "${got:-<exit>}" >&2
		exit 1
	}
done

printf 'hand-back: ok\n'
