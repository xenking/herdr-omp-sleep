#!/bin/bash
# Install the omp pane sleep mode: five scripts, three omp extensions, one
# scheduler entry (a launchd agent on macOS, a systemd user timer on Linux).
# Everything it writes is listed as it goes, and --uninstall takes exactly
# those things back out.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREFIX="${PREFIX:-$HOME/.local/bin}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
EXT_DIR="$AGENT_DIR/extensions"
STATE_DIR="$HOME/.local/state"
OS=$(uname -s)
LABEL="com.$(id -un).omp-reap-idle"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE="omp-reap-idle"
IDLE_MIN=15
DO_TEMPLATES=0
DO_UNINSTALL=0

SCRIPTS=(omp-pane omp-frozen omp-render omp-hist omp-reap-idle)
EXTENSIONS=(draft-keeper.ts full-hist.ts sleep-state.ts)

# No interval timer covers a herdr restart: launchd's interval runs from load
# and the systemd timer from boot/activation, so after a reboot or server
# restart the first sweep lands up to 15 minutes after herdr has already
# restored every pane as a bare shell — measured at 22 minutes on
# 2026-09-03, long after the human went looking for their sessions. A plugin
# `[[startup]]` hook fires exactly once "after Herdr restores the session and
# its API socket is ready" (herdr 0.7.5+), and again when a new server takes
# over during live handoff, which is the other case that strands panes.
PLUGIN_ID="omp-sleep"
PLUGIN_DIR="$STATE_DIR/omp-sleep-herdr-plugin"

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
	if [ "$OS" = Darwin ]; then
		launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
		rm -f "$PLIST"
		printf 'removed  %s\n' "$PLIST"
	else
		systemctl --user disable --now "$SERVICE.timer" 2>/dev/null || true
		rm -f "$SYSTEMD_DIR/$SERVICE.service" "$SYSTEMD_DIR/$SERVICE.timer"
		printf 'removed  %s/%s.service\n' "$SYSTEMD_DIR" "$SERVICE"
		printf 'removed  %s/%s.timer\n' "$SYSTEMD_DIR" "$SERVICE"
		systemctl --user daemon-reload 2>/dev/null || true
	fi
	herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
	rm -rf "$PLUGIN_DIR"
	printf 'removed  %s (herdr plugin %s)\n' "$PLUGIN_DIR" "$PLUGIN_ID"
	for s in "${SCRIPTS[@]}"; do
		rm -f "$PREFIX/$s"
		printf 'removed  %s\n' "$PREFIX/$s"
	done
	for e in "${EXTENSIONS[@]}"; do
		rm -f "$EXT_DIR/$e"
		printf 'removed  %s\n' "$EXT_DIR/$e"
	done
	printf 'kept     %s (session hints, baked frames, unsent drafts)\n' "$AGENT_DIR/frozen"
	printf '\nPanes parked right now keep their frozen view until you press ENTER.\n'
	exit 0
fi

case "$OS" in
Darwin | Linux) ;;
*) die "unsupported OS: $OS (macOS and Linux only)" ;;
esac

# GNU sed takes -i bare; BSD sed needs -i ''. One array serves both call sites.
if [ "$OS" = Darwin ]; then SED_INPLACE=(sed -i '' -E); else SED_INPLACE=(sed -i -E); fi

missing=()
for c in herdr omp jq less nc; do
	command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "$OS" = Linux ]; then
	command -v systemctl >/dev/null 2>&1 || missing+=("systemctl")
fi

mkdir -p "$PREFIX" "$EXT_DIR" "$STATE_DIR" "$AGENT_DIR/frozen"

for s in "${SCRIPTS[@]}"; do
	install -m 755 "$SRC/bin/$s" "$PREFIX/$s"
	printf 'installed  %s\n' "$PREFIX/$s"
done

for e in "${EXTENSIONS[@]}"; do
	install -m 644 "$SRC/extensions/$e" "$EXT_DIR/$e"
	printf 'installed  %s\n' "$EXT_DIR/$e"
done

# The reaper runs from the scheduler, which hands a process almost no PATH. It
# calls herdr, jq and omp by name, so give it the directories those live in.
sched_path="$PREFIX:$(dirname "$(command -v herdr)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"

if [ "$OS" = Darwin ]; then
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
		<string>$sched_path</string>
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
else
	mkdir -p "$SYSTEMD_DIR"
	cat >"$SYSTEMD_DIR/$SERVICE.service" <<EOF
[Unit]
Description=Park idle omp panes in herdr

[Service]
Type=oneshot
Environment=IDLE_MIN=$IDLE_MIN
Environment=PATH=$sched_path
ExecStart=$PREFIX/omp-reap-idle
StandardError=append:$STATE_DIR/omp-reap.err
EOF
	printf 'installed  %s\n' "$SYSTEMD_DIR/$SERVICE.service"
	cat >"$SYSTEMD_DIR/$SERVICE.timer" <<EOF
[Unit]
Description=Park idle omp panes every 15 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
	printf 'installed  %s\n' "$SYSTEMD_DIR/$SERVICE.timer"

	systemctl --user daemon-reload
	systemctl --user enable --now "$SERVICE.timer"
	printf 'loaded     %s.timer (every 900s, IDLE_MIN=%s)\n' "$SERVICE" "$IDLE_MIN"
fi

# Absolute path, not a bare name: the hook inherits whatever PATH the herdr
# server was started with, and a server launched from anywhere but an
# interactive shell would not have $PREFIX on it.
mkdir -p "$PLUGIN_DIR"
cat >"$PLUGIN_DIR/herdr-plugin.toml" <<EOF
id = "$PLUGIN_ID"
name = "omp sleep revival"
version = "0.1.0"
min_herdr_version = "0.7.5"
description = "Restore parked omp panes to their frozen view after a herdr restart or handoff."
platforms = ["macos", "linux"]

[[startup]]
command = ["$PREFIX/omp-reap-idle"]
EOF
printf 'installed  %s\n' "$PLUGIN_DIR/herdr-plugin.toml"

if herdr plugin link "$PLUGIN_DIR" >/dev/null 2>&1; then
	printf 'linked     herdr plugin %s (revives parked panes on herdr start)\n' "$PLUGIN_ID"
else
	printf 'warning    could not link herdr plugin %s; run: herdr plugin link %s\n' \
		"$PLUGIN_ID" "$PLUGIN_DIR" >&2
fi

# The script's own default has to match the scheduler entry, or a manual run
# acts on a different set of panes than the scheduled one and every diagnosis
# is wrong.
if [ "$IDLE_MIN" != 15 ]; then
	"${SED_INPLACE[@]}" "s/^IDLE_MIN=\\\$\{IDLE_MIN:-[0-9]+\}$/IDLE_MIN=\${IDLE_MIN:-$IDLE_MIN}/" \
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
			"${SED_INPLACE[@]}" 's/^([[:space:]]*command[[:space:]]*=[[:space:]]*)"omp"[[:space:]]*$/\1"omp-pane"/' "$f"
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

if [ "$OS" = Darwin ]; then
	verify_sched="  launchctl print $DOMAIN/$LABEL | grep -E 'state|runs'"
else
	verify_sched="  systemctl --user list-timers $SERVICE.timer"
fi

cat <<EOF

Done. New OMP processes load sleep-state.ts. Existing processes without its
snapshot stay awake; cursorless old parked panes are not revived to a guessed branch.
Preserve/select the intended branch before restarting an old shared-file session.

Verify — what would sleep right now, without touching anything:
  DRY_RUN=1 IDLE_MIN=0 $PREFIX/omp-reap-idle
What it has actually done:
  tail $STATE_DIR/omp-reap.log
The schedule itself:
$verify_sched
EOF
