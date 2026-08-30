#!/bin/sh
# Remove what install.sh added. The config file and the session log are yours,
# so they are only removed if you say so — the plugin comes out either way.
#
#   ./uninstall.sh              # remove the plugin, ask about the rest
#   ./uninstall.sh --all --yes  # remove everything, ask nothing
set -eu
cd "$(dirname "$0")"

PLUGIN_NAME=vpn-eta.1m.sh
CONFIG_PATH=${VPN_ETA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/vpn-eta/config}
PLUGIN_DIR=""
STATE_DIR=""
ASSUME_YES=0
ALL=0
# Set as soon as a path is named on the command line. A run that was told where
# to look must never reach past that into the real installation — an audit or a
# test pointed at a temp directory has to be incapable of deleting live data.
SCOPED=0

usage() {
	cat >&2 <<EOF
usage: ./uninstall.sh [--plugin-dir DIR] [--config PATH] [--all] [--yes]

  --plugin-dir DIR   where the plugin was installed (default: ask SwiftBar)
  --config PATH      config file to remove (default: $CONFIG_PATH)
  --state-dir DIR    session state and history to remove (default: autodetected)
  --all              also remove the config file and the saved session state
                     (implies --yes)
EOF
	exit 64
}

while [ $# -gt 0 ]; do
	case "$1" in
	--plugin-dir) PLUGIN_DIR=$2; SCOPED=1; shift 2 ;;
	--config) CONFIG_PATH=$2; SCOPED=1; shift 2 ;;
	--state-dir) STATE_DIR=$2; SCOPED=1; shift 2 ;;
	--all) ALL=1; ASSUME_YES=1; shift ;;
	--yes | -y) ASSUME_YES=1; shift ;;
	-h | --help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

say() { printf '%s\n' "$*"; }

# Deleting is the irreversible direction, so these prompts default to NO — the
# opposite of the installer's. A run with no terminal keeps the file.
confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ -t 0 ] || return 1
	printf '%s [y/N] ' "$1"
	IFS= read -r reply || reply=n
	case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

[ -z "$PLUGIN_DIR" ] && PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)

if [ -n "$PLUGIN_DIR" ] && [ -e "$PLUGIN_DIR/$PLUGIN_NAME" ]; then
	rm -f "$PLUGIN_DIR/$PLUGIN_NAME"
	say "removed $PLUGIN_DIR/$PLUGIN_NAME"
else
	say "no plugin found to remove${PLUGIN_DIR:+ in $PLUGIN_DIR}"
fi

if [ -e "$CONFIG_PATH" ]; then
	if [ "$ALL" = 1 ] || confirm "remove your settings at $CONFIG_PATH?"; then
		rm -f "$CONFIG_PATH"
		rmdir "$(dirname "$CONFIG_PATH")" 2>/dev/null || true
		say "removed $CONFIG_PATH"
	else
		say "kept $CONFIG_PATH"
	fi
fi

# The session log and the cached countdown. A configured VPN_ETA_STATE_DIR wins,
# because otherwise "remove all of it" would clear the default directory and
# leave the one actually in use untouched.
if [ -z "$STATE_DIR" ] && [ -r "$CONFIG_PATH" ] && bash -n "$CONFIG_PATH" 2>/dev/null; then
	STATE_DIR=$(
		# shellcheck source=/dev/null
		. "$CONFIG_PATH" 2>/dev/null
		printf '%s' "${VPN_ETA_STATE_DIR:-}"
	)
fi

if [ -n "$STATE_DIR" ]; then
	state_dirs=$STATE_DIR
elif [ "$SCOPED" = 1 ]; then
	# Told where to look and given no state directory: the caller is pointed at
	# something other than the real installation, so there is nothing here this
	# run is entitled to delete.
	state_dirs=""
	say "state directories left alone (this run was scoped by --plugin-dir/--config;"
	say "  pass --state-dir to remove one explicitly)"
else
	# SwiftBar names a plugin's data directory after the plugin FILE only when
	# the plugin folder is its own; point it at a folder of your own — which is
	# what install.sh does, and what the README documents — and the directory is
	# named after the plugin's full path instead. Listing only the first shape is
	# how `--all` came to report success while leaving the entire session history
	# on disk. Which shape a given SwiftBar produced is recorded nowhere the
	# uninstaller can read, so both are offered; neither exists in the other case.
	state_dirs="$HOME/Library/Application Support/SwiftBar/Plugins/$PLUGIN_NAME
$HOME/Library/Application Support/vpn-eta"
	if [ -n "$PLUGIN_DIR" ]; then
		state_dirs="$HOME/Library/Application Support/SwiftBar/Plugins/${PLUGIN_DIR#/}/$PLUGIN_NAME
$state_dirs"
	fi
fi

printf '%s\n' "$state_dirs" | while IFS= read -r dir; do
	if [ -z "$dir" ] || [ ! -d "$dir" ]; then
		continue
	fi
	if [ "$ALL" = 1 ] || confirm "remove the saved session history in $dir?"; then
		rm -rf "$dir"
		say "removed $dir"
	else
		say "kept $dir"
	fi
done

if [ "$ALL" = 1 ] || confirm "restart SwiftBar so the menu-bar item goes away now?"; then
	osascript -e 'tell application "SwiftBar" to quit' >/dev/null 2>&1 || true
	sleep 1
	open -a SwiftBar >/dev/null 2>&1 || true
fi

say "Done."
