#!/bin/sh
# vpn-eta installer.
#
# Does the whole setup: finds Cisco Secure Client, reads YOUR saved VPN profiles
# out of it, finds (or creates) SwiftBar's plugin folder, writes a config file
# with your answers, and drops the plugin in.
#
# Nothing about your VPN is shipped in this repository — no hostname, no profile
# name, no username. All of it is read from the client already installed on this
# Mac, at the moment you run this, and written only to your own config file.
#
#   ./install.sh                 # ask about anything ambiguous
#   ./install.sh --yes           # take the defaults, ask nothing
#   ./install.sh --host vpn.example.com --label Work
#   ./install.sh --print-hosts   # just show the saved profiles and exit
set -eu
cd "$(dirname "$0")"

PLUGIN_SRC=swiftbar/vpn-eta.1m.sh
CONFIG_PATH=${VPN_ETA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/vpn-eta/config}
PLUGIN_DIR=""
HOST=""
HOST_EXPLICIT=0
LABEL=""
TERMINAL_APP=""
ASSUME_YES=0
PRINT_HOSTS=0
# SwiftBar has no default plugin folder — it asks you to pick one on first
# launch — so this is only a fallback for when it has not been set yet.
# NOT "~/Library/Application Support/SwiftBar/Plugins": that is SwiftBar's own
# per-plugin *data* directory, which already holds a folder named after every
# plugin file. Installing a plugin there collides with its own data folder.
DEFAULT_PLUGIN_DIR="$HOME/SwiftBar"
SWIFTBAR_DATA_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"

usage() {
	cat >&2 <<EOF
usage: ./install.sh [options]

  --plugin-dir DIR   SwiftBar plugin folder (default: ask SwiftBar, else
                     $DEFAULT_PLUGIN_DIR)
  --config PATH      config file to write (default: $CONFIG_PATH)
  --host HOST        Cisco profile name or URL to connect to
  --label TEXT       what the menu bar says before the countdown
  --terminal APP     which terminal SwiftBar opens for "Start new session"
                     (Terminal, iTerm, Ghostty, Kitty)
  --yes              never prompt; take defaults
  --print-hosts      list the saved Cisco profiles and exit
  -h, --help         this
EOF
	exit 64
}

while [ $# -gt 0 ]; do
	case "$1" in
	--plugin-dir) [ $# -ge 2 ] || usage; PLUGIN_DIR=$2; shift 2 ;;
	--config) [ $# -ge 2 ] || usage; CONFIG_PATH=$2; shift 2 ;;
	--host) [ $# -ge 2 ] || usage; HOST=$2; HOST_EXPLICIT=1; shift 2 ;;
	--label) [ $# -ge 2 ] || usage; LABEL=$2; shift 2 ;;
	--terminal) [ $# -ge 2 ] || usage; TERMINAL_APP=$2; shift 2 ;;
	--yes | -y) ASSUME_YES=1; shift ;;
	--print-hosts) PRINT_HOSTS=1; shift ;;
	-h | --help) usage ;;
	*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

# Progress goes to stderr so stdout stays clean for --print-hosts, which is the
# one output another script might want to read.
# A Cisco profile name is not a shell literal — real ones carry spaces, and a
# name holding a quote, a backtick or a $ would otherwise corrupt or EXECUTE
# inside a config file the plugin sources every single minute. Single quotes,
# with the only escape single quoting needs.
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Sets NAME=value in the config, replacing an existing line rather than adding a
# second one the shell would silently let win.
set_config_line() {
	tmp=$(mktemp) || return 1
	awk -v name="$1" -v line="$1=$(shquote "$2")" '
		$0 ~ "^[[:space:]]*" name "=" { if (!done) { print line; done = 1 } ; next }
		{ print }
		END { if (!done) print line }
	' "$CONFIG_PATH" >"$tmp" && mv "$tmp" "$CONFIG_PATH"
	chmod 0600 "$CONFIG_PATH"
}

case "${TERMINAL_APP:-}" in
'' | Terminal | iTerm | Ghostty | Kitty) ;;
*)
	echo "--terminal must be one of: Terminal, iTerm, Ghostty, Kitty" >&2
	exit 64
	;;
esac

say() { printf '%s\n' "$*" >&2; }
warn() { printf '  ! %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }

# Prompts default to yes. --yes answers yes without asking, and a run with no
# terminal attached (a pipe, CI) must not block waiting for an answer nobody
# can give, so it takes the default too.
confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ -t 0 ] || return 0
	printf '%s [Y/n] ' "$1"
	IFS= read -r reply || reply=n
	case "$reply" in '' | y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

ask() {
	# $1 prompt, $2 default. Non-interactive runs take the default silently.
	if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
		printf '%s\n' "$2"
		return 0
	fi
	printf '%s [%s] ' "$1" "$2" >&2
	IFS= read -r reply || reply=
	printf '%s\n' "${reply:-$2}"
}

# What the config already says is decided before anything is asked, so the
# installer never collects an answer it is going to throw away.
CONFIG_EXISTS=0
CONFIG_HAS_HOST=0
if [ -e "$CONFIG_PATH" ]; then
	CONFIG_EXISTS=1
	grep -q '^[[:space:]]*VPN_ETA_HOST=' "$CONFIG_PATH" && CONFIG_HAS_HOST=1
fi

# ---------------------------------------------------------------------------
step "Cisco Secure Client"

VPN=""
for candidate in \
	"${VPN_ETA_VPN_BIN:-}" \
	/opt/cisco/secureclient/bin/vpn \
	/opt/cisco/anyconnect/bin/vpn; do
	[ -n "$candidate" ] && [ -x "$candidate" ] && { VPN=$candidate; break; }
done

if [ -n "$VPN" ]; then
	say "  found: $VPN"
else
	warn "not found at /opt/cisco/secureclient/bin/vpn or /opt/cisco/anyconnect/bin/vpn."
	warn "The plugin needs Cisco's own CLI to read the session. Install Cisco"
	warn "Secure Client, or pass --host and set VPN_ETA_VPN_BIN in the config."
fi

# The saved profiles live in the client, never in this repository. `vpn hosts`
# is read-only and does not touch the connection.
hosts=""
if [ -n "$VPN" ]; then
	hosts=$("$VPN" hosts 2>/dev/null | awk '
		/^[[:space:]]*\[hosts\]:/ { in_hosts = 1; next }
		in_hosts && /^[[:space:]]*>/ {
			sub(/^[[:space:]]*>[[:space:]]*/, "")
			sub(/[[:space:]]*$/, "")
			if ($0 != "") print
		}
	') || hosts=""
fi

if [ "$PRINT_HOSTS" = 1 ]; then
	if [ -z "$hosts" ]; then
		say "  no saved profiles found"
		exit 1
	fi
	printf '%s\n' "$hosts"
	exit 0
fi

host_count=$(printf '%s' "$hosts" | grep -c . || true)
host_count=$(printf '%s' "$host_count" | tr -d ' ')

if [ -n "$HOST" ]; then
	say "  using the profile you passed: $HOST"
elif [ "$CONFIG_HAS_HOST" = 1 ]; then
	# Asking here and discarding the answer at the config step is worse than not
	# asking: --host, or editing the file, is how you change an existing choice.
	say "  $CONFIG_PATH already names a profile — leaving it alone"
	say "  (pass --host to change it)"
elif [ "$host_count" = 1 ]; then
	HOST=$hosts
	say "  one saved profile: $HOST"
elif [ "$host_count" = 0 ]; then
	say "  no saved profiles yet — connect once in Cisco Secure Client, or set"
	say "  VPN_ETA_HOST later in $CONFIG_PATH"
else
	say "  $host_count saved profiles:"
	printf '%s\n' "$hosts" | awk '{ printf "    %d) %s\n", NR, $0 }'
	choice=$(ask "  which one should \"Start new session\" use? (number)" 1)
	HOST=$(printf '%s\n' "$hosts" | awk -v n="$choice" 'NR == n { print; exit }')
	if [ -z "$HOST" ]; then
		warn "not a listed number; leaving the profile unset."
	else
		say "  chose: $HOST"
	fi
fi

# ---------------------------------------------------------------------------
step "SwiftBar"

if [ -z "$PLUGIN_DIR" ]; then
	PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
fi

if [ ! -d "/Applications/SwiftBar.app" ] && ! command -v swiftbar >/dev/null 2>&1; then
	warn "SwiftBar does not look installed. The plugin is a SwiftBar plugin —"
	warn "install it with:  brew install --cask swiftbar"
fi

set_plugin_dir=0
if [ -z "$PLUGIN_DIR" ]; then
	PLUGIN_DIR=$DEFAULT_PLUGIN_DIR
	say "  SwiftBar has no plugin folder set; using $PLUGIN_DIR"
	set_plugin_dir=1
else
	say "  plugin folder: $PLUGIN_DIR"
fi

case "$PLUGIN_DIR" in
"$SWIFTBAR_DATA_DIR" | "$SWIFTBAR_DATA_DIR"/*)
	warn "$PLUGIN_DIR is inside SwiftBar's data directory, which holds one folder"
	warn "per plugin. A plugin installed there collides with its own data folder."
	warn "Pick a plugin folder elsewhere, e.g. --plugin-dir \"$DEFAULT_PLUGIN_DIR\"."
	exit 1
	;;
esac

mkdir -p "$PLUGIN_DIR"
install -m 0755 "$PLUGIN_SRC" "$PLUGIN_DIR/"
say "  installed $(basename "$PLUGIN_SRC") $("$PLUGIN_SRC" --version 2>/dev/null || echo '(version unknown)')"

if [ "$set_plugin_dir" = 1 ]; then
	# SwiftBar reads this once at launch, so it only takes effect on restart —
	# which the last step does anyway.
	defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
	say "  pointed SwiftBar at it"
fi

# ---------------------------------------------------------------------------
step "Config"

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ "$CONFIG_EXISTS" = 1 ]; then
	say "  $CONFIG_PATH exists — your settings are not overwritten"
	# An explicit --host or --label is an instruction, not a guess, so it is
	# applied to the existing file. Anything merely inferred from the client is
	# only ever offered.
	if [ "$HOST_EXPLICIT" = 1 ] && [ -n "$HOST" ]; then
		if confirm "  set VPN_ETA_HOST to $HOST?"; then
			set_config_line VPN_ETA_HOST "$HOST"
			say "  updated VPN_ETA_HOST"
		fi
	elif [ -n "$HOST" ] && [ "$CONFIG_HAS_HOST" = 0 ]; then
		if confirm "  it names no profile — add VPN_ETA_HOST=$HOST?"; then
			set_config_line VPN_ETA_HOST "$HOST"
			say "  added VPN_ETA_HOST"
		fi
	fi
	if [ -n "$LABEL" ]; then
		if confirm "  set VPN_ETA_LABEL to $LABEL?"; then
			set_config_line VPN_ETA_LABEL "$LABEL"
			say "  updated VPN_ETA_LABEL"
		fi
	fi
else
	# The mode matters before the first byte, not after it: this file carries the
	# name of a corporate gateway.
	(
		umask 077
		{
			echo "# vpn-eta — written by install.sh on $(date +%Y-%m-%d)."
			echo "# Every available setting is documented in config.example in the repo."
			echo
			if [ -n "$HOST" ]; then
				echo "# The Cisco profile \"Start new session\" connects to. Read from the"
				echo "# client on this Mac at install time."
				echo "VPN_ETA_HOST=$(shquote "$HOST")"
			else
				echo "# Set this if Cisco Secure Client has more than one saved profile."
				echo "#VPN_ETA_HOST='vpn.example.com'"
			fi
			echo
			if [ -n "$LABEL" ]; then
				echo "VPN_ETA_LABEL=$(shquote "$LABEL")"
			else
				echo "# What the menu bar says before the countdown. An emoji is the"
				echo "# narrowest label there is; an empty string removes it."
				echo "#VPN_ETA_LABEL='VPN'"
			fi
			echo
			echo "# Drop the minutes from the menu bar while over an hour is left."
			echo "#VPN_ETA_COMPACT=1"
			echo
			echo "# Minutes-remaining marks that raise a notification. '' turns them off."
			echo "#VPN_ETA_NOTIFY_MARKS='60 15'"
		} >"$CONFIG_PATH"
	)
	chmod 0600 "$CONFIG_PATH"
	say "  wrote $CONFIG_PATH"
fi

# ---------------------------------------------------------------------------
step "Terminal for \"Start new session\""

# That action needs a terminal: Cisco asks for a password, and usually a one-time
# code, and there is nowhere else to type them. SwiftBar decides which terminal.
current_terminal=$(defaults read com.ameba.SwiftBar Terminal 2>/dev/null || echo Terminal)
say "  SwiftBar currently opens: $current_terminal"

if [ -n "$TERMINAL_APP" ]; then
	defaults write com.ameba.SwiftBar Terminal -string "$TERMINAL_APP"
	say "  set to $TERMINAL_APP"
	current_terminal=$TERMINAL_APP
elif [ -t 0 ] && [ "$ASSUME_YES" != 1 ]; then
	# Which terminal you like is a preference, not part of installing, so it is
	# only ever offered to a human sitting here. A scripted run changes nothing
	# unless --terminal said to.
	for app in Ghostty iTerm Kitty; do
		case $app in
		Ghostty) bundle=/Applications/Ghostty.app ;;
		iTerm) bundle=/Applications/iTerm.app ;;
		Kitty) bundle=/Applications/kitty.app ;;
		esac
		[ "$current_terminal" = "$app" ] && break
		[ -d "$bundle" ] || continue
		if confirm "  $app is installed — use it instead of $current_terminal?"; then
			defaults write com.ameba.SwiftBar Terminal -string "$app"
			say "  SwiftBar will use $app"
			current_terminal=$app
		fi
		break
	done
else
	say "  unchanged (pass --terminal to set it)"
fi

# ---------------------------------------------------------------------------
step "Done"

if confirm "  restart SwiftBar now so it picks all of this up?"; then
	osascript -e 'tell application "SwiftBar" to quit' >/dev/null 2>&1 || true
	sleep 1
	if open -a SwiftBar >/dev/null 2>&1; then
		say "  SwiftBar restarted"
	else
		warn "could not launch SwiftBar; start it yourself."
	fi
else
	say "  restart SwiftBar yourself to load the plugin."
fi

say ""
say "The countdown appears in the menu bar within a minute."
say "Settings:      $CONFIG_PATH"
say "All options:   config.example"
say "Uninstall:     ./uninstall.sh"
