#!/bin/bash
# Install the omp pane sleep mode: three scripts, one omp extension, one
# launchd agent. Everything it writes is listed as it goes, and --uninstall
# takes exactly those things back out.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREFIX="${PREFIX:-$HOME/.local/bin}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
EXT_DIR="$AGENT_DIR/extensions"
STATE_DIR="$HOME/.local/state"
LABEL="com.$(id -un).omp-reap-idle"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
IDLE_MIN=15
DO_TEMPLATES=0
DO_UNINSTALL=0

SCRIPTS=(omp-pane omp-frozen omp-render omp-hist omp-reap-idle)

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

  --prefix DIR       where the scripts go (default: ~/.local/bin)
  --idle-min N       minutes idle before a pane sleeps (default: 15)
  --herdr-templates  point existing herdr pane templates at omp-pane
  --uninstall        remove everything this installed
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--prefix)
		PREFIX=${2:?--prefix needs a directory}
		shift 2
		;;
	--idle-min)
		IDLE_MIN=${2:?--idle-min needs a number}
		shift 2
		;;
	--herdr-templates)
		DO_TEMPLATES=1
		shift
		;;
	--uninstall)
		DO_UNINSTALL=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
done

case $IDLE_MIN in
'' | *[!0-9]*) die "--idle-min must be a whole number of minutes, got: $IDLE_MIN" ;;
esac

if [ "$DO_UNINSTALL" = 1 ]; then
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	printf 'removed  %s\n' "$PLIST"
	for s in "${SCRIPTS[@]}"; do
		rm -f "$PREFIX/$s"
		printf 'removed  %s\n' "$PREFIX/$s"
	done
	rm -f "$EXT_DIR/draft-keeper.ts"
	printf 'removed  %s\n' "$EXT_DIR/draft-keeper.ts"
	printf 'kept     %s (session hints, baked frames, unsent drafts)\n' "$AGENT_DIR/frozen"
	printf '\nPanes parked right now keep their frozen view until you press ENTER.\n'
	exit 0
fi

[ "$(uname -s)" = Darwin ] || die "macOS only: this uses launchd and BSD stat(1)"

missing=()
for c in herdr omp jq less nc; do
	command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[ ${#missing[@]} -eq 0 ] || die "missing on PATH: ${missing[*]}"

mkdir -p "$PREFIX" "$EXT_DIR" "$STATE_DIR" "$AGENT_DIR/frozen"

for s in "${SCRIPTS[@]}"; do
	install -m 755 "$SRC/bin/$s" "$PREFIX/$s"
	printf 'installed  %s\n' "$PREFIX/$s"
done

install -m 644 "$SRC/extensions/draft-keeper.ts" "$EXT_DIR/draft-keeper.ts"
printf 'installed  %s\n' "$EXT_DIR/draft-keeper.ts"

# The reaper runs from launchd, which hands a process almost no PATH. It calls
# herdr, jq and omp by name, so give it the directories those actually live in.
launchd_path="$PREFIX:$(dirname "$(command -v herdr)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"

mkdir -p "$(dirname "$PLIST")"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>

	<key>ProgramArguments</key>
	<array>
		<string>$PREFIX/omp-reap-idle</string>
	</array>

	<key>EnvironmentVariables</key>
	<dict>
		<key>IDLE_MIN</key>
		<string>$IDLE_MIN</string>
		<key>PATH</key>
		<string>$launchd_path</string>
	</dict>

	<key>StartInterval</key>
	<integer>900</integer>

	<key>RunAtLoad</key>
	<false/>

	<key>StandardErrorPath</key>
	<string>$STATE_DIR/omp-reap.err</string>
</dict>
</plist>
EOF
printf 'installed  %s\n' "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
printf 'loaded     %s (every 900s, IDLE_MIN=%s)\n' "$LABEL" "$IDLE_MIN"

# The script's own default has to match the plist, or a manual run acts on a
# different set of panes than the scheduled one and every diagnosis is wrong.
if [ "$IDLE_MIN" != 15 ]; then
	sed -i '' -E "s/^IDLE_MIN=\\\$\{IDLE_MIN:-[0-9]+\}$/IDLE_MIN=\${IDLE_MIN:-$IDLE_MIN}/" \
		"$PREFIX/omp-reap-idle"
	printf 'aligned    %s default to IDLE_MIN=%s\n' "$PREFIX/omp-reap-idle" "$IDLE_MIN"
fi

if [ "$DO_TEMPLATES" = 1 ]; then
	tpl_dir="${HERDR_CONFIG_DIR:-$HOME/.config/herdr}/plugins/config"
	if [ ! -d "$tpl_dir" ]; then
		printf 'skipped    no herdr plugin config at %s\n' "$tpl_dir"
	else
		stamp=$(date +%Y%m%d%H%M%S)
		n=0
		while IFS= read -r f; do
			cp "$f" "$f.bak.$stamp"
			sed -i '' -E 's/^([[:space:]]*command[[:space:]]*=[[:space:]]*)"omp"[[:space:]]*$/\1"omp-pane"/' "$f"
			printf 'rewrote    %s (backup: %s)\n' "$f" "$(basename "$f").bak.$stamp"
			n=$((n + 1))
		done < <(grep -rlE '^[[:space:]]*command[[:space:]]*=[[:space:]]*"omp"[[:space:]]*$' \
			--include='*.toml' "$tpl_dir" 2>/dev/null |
			grep -v '\.bak\.' || true)
		printf 'rewrote    %s herdr template(s)\n' "$n"
	fi
fi

case ":$PATH:" in
*":$PREFIX:"*) ;;
*) printf '\nwarning: %s is not on your PATH — herdr will not find omp-pane\n' "$PREFIX" ;;
esac

cat <<EOF

Done. Panes already running plain omp are picked up on their first sleep;
nothing needs restarting.

Verify — what would sleep right now, without touching anything:
  DRY_RUN=1 IDLE_MIN=0 $PREFIX/omp-reap-idle
What it has actually done:
  tail $STATE_DIR/omp-reap.log
The schedule itself:
  launchctl print $DOMAIN/$LABEL | grep -E 'state|runs'
EOF
