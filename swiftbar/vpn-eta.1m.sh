#!/bin/bash
# SwiftBar plugin — show the time left in the current Cisco VPN session.
# <xbar.title>VPN session ETA</xbar.title>
# <xbar.desc>Shows the server-reported time remaining in the VPN session.</xbar.desc>
# <xbar.author>Ruslan Rakhimov</xbar.author>
# <xbar.version>v1.0.0</xbar.version>

# The plugin is COPIED into SwiftBar's folder, so the installed file has no link
# back to the tag it came from. Without this a bug report can name the macOS,
# SwiftBar and Cisco versions and still not say which vpn-eta is running.
VERSION=1.0.0

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

# A hand-edited setting that is not a number must degrade to the default rather
# than to a shell error printed into the middle of the menu.
number_or() {
	case ${1:-} in
	'' | *[!0-9]*) printf '%s\n' "$2" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# Every setting below can be changed in a config file, and that file is the only
# place a setting reliably reaches this script: SwiftBar starts plugins from
# launchd, which never reads your shell profile, so an exported variable applies
# to a terminal run and not to the menu bar. The file is a shell fragment —
# `VPN_ETA_NOTIFY_MARKS="120 30"`, one per line. See config.example.
#
# A second copy of this plugin under a different filename gets its own config
# for free: vpn-eta-lab.1m.sh reads vpn-eta-lab.config if that exists, and the
# shared config otherwise. Watching two gateways therefore needs no edit to
# either copy — which matters because there is nowhere to set an environment
# variable per plugin in the first place.
if [ -z "${VPN_ETA_CONFIG:-}" ]; then
	config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/vpn-eta
	config_name=$(basename "$0")
	config_name=${config_name%%.*}
	if [ -r "$config_dir/$config_name.config" ]; then
		VPN_ETA_CONFIG=$config_dir/$config_name.config
	else
		VPN_ETA_CONFIG=$config_dir/config
	fi
fi
# A config with an unbalanced quote would otherwise spray shell errors into the
# menu and silently drop every setting after the mistake — which looks like the
# plugin ignoring you. Check it first, and say so plainly instead.
CONFIG_ERROR=
if [ -r "$VPN_ETA_CONFIG" ]; then
	if bash -n "$VPN_ETA_CONFIG" 2>/dev/null; then
		# shellcheck source=/dev/null
		. "$VPN_ETA_CONFIG"
	else
		CONFIG_ERROR=$VPN_ETA_CONFIG
	fi
fi

# SwiftBar hands every plugin its own data directory; outside SwiftBar there is
# none, so fall back to a fixed one rather than scattering state per working dir.
STATE_DIR=${VPN_ETA_STATE_DIR:-${SWIFTBAR_PLUGIN_DATA_PATH:-$HOME/Library/Application Support/vpn-eta}}
STATE_FILE=$STATE_DIR/last-session
EVENT_FILE=$STATE_DIR/last-event
HISTORY_FILE=$STATE_DIR/history.log
TEARDOWN_FILE=$STATE_DIR/expected-teardown

# What the menu bar says in front of the countdown. Two menu-bar items showing
# "VPN" tell you nothing, so a second gateway can be labelled "Work" or "Lab".
# Deliberately `-` and not `:-`: an empty value means "no label", which is how
# you get the narrowest possible item, and `:-` would override that with VPN.
LABEL=${VPN_ETA_LABEL-VPN}
# Built once so an empty label leaves no stray leading space in the menu bar.
BAR_PREFIX=${LABEL:+$LABEL }
# Drops the minutes from the menu bar while more than an hour is left. Written
# out because `0` is a word people reach for to mean off, and a bare emptiness
# test would read it as on.
case ${VPN_ETA_COMPACT:-} in
'' | 0 | no | off | false) COMPACT= ;;
*) COMPACT=1 ;;
esac

# Minutes-remaining marks that get a notification, high to low. Each fires once
# per session, and a Mac that slept through several fires only the lowest, so
# waking up never brings a stack of stale warnings. Empty switches them off.
NOTIFY_MARKS=${VPN_ETA_NOTIFY_MARKS-60 15}
HISTORY_MAX_LINES=$(number_or "${VPN_ETA_HISTORY_LINES:-500}" 500)
# A teardown this plugin started itself is not a drop worth announcing.
TEARDOWN_GRACE_SECONDS=$(number_or "${VPN_ETA_TEARDOWN_GRACE:-300}" 300)

# Colour thresholds for the countdown, in minutes: at or below the first it goes
# red, at or below the second orange, otherwise green. They are independent of
# NOTIFY_MARKS on purpose — a colour you glance at and a notification that
# interrupts you do not deserve the same threshold.
CRITICAL_MINUTES=$(number_or "${VPN_ETA_CRITICAL_MINUTES:-15}" 15)
WARN_MINUTES=$(number_or "${VPN_ETA_WARN_MINUTES:-60}" 60)

# How long an extrapolated countdown stays trustworthy once the client stops
# answering. Past this the plugin admits it does not know.
STALE_LIMIT_MINUTES=$(number_or "${VPN_ETA_STALE_LIMIT:-45}" 45)
VPN_TIMEOUT_SECONDS=$(number_or "${VPN_ETA_TIMEOUT:-12}" 12)
# How long to wait for a freshly connected session to report its countdown.
CONNECT_POLL_ATTEMPTS=$(number_or "${VPN_ETA_CONNECT_ATTEMPTS:-15}" 15)
CONNECT_POLL_SLEEP=$(number_or "${VPN_ETA_CONNECT_SLEEP:-2}" 2)

find_vpn() {
	# Set VPN_ETA_VPN_BIN when the client lives somewhere the two standard paths
	# below do not cover; the test suite uses the same door to point at a fake.
	if [ -n "${VPN_ETA_VPN_BIN:-}" ] && [ -x "$VPN_ETA_VPN_BIN" ]; then
		VPN=$VPN_ETA_VPN_BIN
	elif [ -x /opt/cisco/secureclient/bin/vpn ]; then
		VPN=/opt/cisco/secureclient/bin/vpn
	elif [ -x /opt/cisco/anyconnect/bin/vpn ]; then
		VPN=/opt/cisco/anyconnect/bin/vpn
	else
		return 1
	fi
}

now_epoch() { date +%s; }

# The client CLI talks to a daemon and has been seen to return successfully
# without ever attaching, so every call gets a watchdog. macOS ships no
# timeout(1); the inline fallback is safe here only because the CLI spawns no
# children of its own, so killing the direct child is the whole job.
run_vpn() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$VPN_TIMEOUT_SECONDS" "$VPN" "$@" 2>/dev/null
		return $?
	fi
	out_file=$(mktemp -t vpn-eta) || return 1
	"$VPN" "$@" >"$out_file" 2>/dev/null &
	vpn_pid=$!
	waited=0
	while kill -0 "$vpn_pid" 2>/dev/null; do
		if [ "$waited" -ge "$VPN_TIMEOUT_SECONDS" ]; then
			kill -9 "$vpn_pid" 2>/dev/null
			wait "$vpn_pid" 2>/dev/null
			rm -f "$out_file"
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$vpn_pid"
	rc=$?
	cat "$out_file"
	rm -f "$out_file"
	return "$rc"
}

field() {
	printf '%s\n' "$2" | awk -v key="$1" '
		index($0, key) {
			line = $0
			sub(/\r/, "", line)
			pos = index(line, key)
			value = substr(line, pos + length(key))
			sub(/^[[:space:]]*/, "", value)
			sub(/[[:space:]]*$/, "", value)
			if (value != "") {
				print value
				exit
			}
		}
	'
}

connection_state() { field "Connection State:" "$1"; }
client_address() {
	addr=$(field "Client Address (IPv4):" "$1")
	[ "$addr" = "Not Available" ] && addr=
	printf '%s\n' "$addr"
}

session_remaining() {
	remaining=$(field "Session Disconnect:" "$1")
	case $remaining in
	*Remaining) printf '%s\n' "$remaining" ;;
	esac
}

# A reply that carries neither field never reached the daemon. Distinguishing
# that from a genuine disconnect is the whole point: only the second one may
# ever render as "off".
stats_is_readable() {
	[ -n "$(connection_state "$1")" ] || [ -n "$(session_remaining "$1")" ]
}

read_stats() {
	# Retrying is for a client that would not answer. With no tunnel at all the
	# VPN is simply off, and retrying would burn three CLI spawns every minute
	# for as long as it stays off.
	attempts=3
	any_tunnel_up || attempts=1
	attempt=1
	while [ "$attempt" -le "$attempts" ]; do
		stats=$(run_vpn stats)
		stats_rc=$?
		if [ "$stats_rc" -eq 0 ] && stats_is_readable "$stats"; then
			return 0
		fi
		[ "$attempt" -lt "$attempts" ] && sleep 2
		attempt=$((attempt + 1))
	done
	return 1
}

# Independent of the CLI: is the address the tunnel last held still bound to a
# utun interface? Only a "no" here is strong enough to claim the VPN is down.
tunnel_has_address() {
	[ -n "$1" ] || return 1
	ifconfig 2>/dev/null | awk -v want="$1" '
		/^[a-z0-9]+:/ { iface = $1 }
		$1 == "inet" && $2 == want && iface ~ /^utun/ { found = 1 }
		END { exit !found }
	'
}

any_tunnel_up() {
	ifconfig 2>/dev/null | awk '
		/^[a-z0-9]+:/ { iface = $1 }
		$1 == "inet" && iface ~ /^utun/ { found = 1 }
		END { exit !found }
	'
}

remaining_to_minutes() {
	printf '%s\n' "$1" | awk '
		{
			days = hours = minutes = 0
			for (i = 1; i < NF; i++) {
				if ($(i+1) ~ /^Days?$/) days = $i
				else if ($(i+1) ~ /^Hours?$/) hours = $i
				else if ($(i+1) ~ /^Minutes?$/) minutes = $i
			}
			print days * 1440 + hours * 60 + minutes
		}
	'
}

format_minutes() {
	awk -v total="$1" '
		BEGIN {
			if (total < 0) total = 0
			d = int(total / 1440)
			h = int((total % 1440) / 60)
			m = total % 60
			if (d > 0) printf "%dd %dh\n", d, h
			else if (h > 0) printf "%dh %dm\n", h, m
			else printf "%dm\n", m
		}
	'
}

# The menu bar is the scarcest space on the screen, so it gets its own format.
# Compact drops the minutes while there is more than an hour left: at 23h they
# are noise, and under an hour they are the entire point. It rounds DOWN, which
# is the safe direction — the bar never claims more time than you have.
format_menubar() {
	[ -n "$COMPACT" ] || { format_minutes "$1"; return; }
	awk -v total="$1" '
		BEGIN {
			if (total < 0) total = 0
			d = int(total / 1440)
			h = int((total % 1440) / 60)
			if (d > 0) printf "%dd\n", d
			else if (h > 0) printf "%dh\n", h
			else printf "%dm\n", total % 60
		}
	'
}

color_for_minutes() {
	if [ "$1" -le "$CRITICAL_MINUTES" ]; then
		echo red
	elif [ "$1" -le "$WARN_MINUTES" ]; then
		echo orange
	else
		echo green
	fi
}

save_state() {
	mkdir -p "$STATE_DIR" 2>/dev/null || return 0
	{
		echo "epoch=$(now_epoch)"
		echo "minutes=$1"
		echo "address=$2"
		echo "notified=$3"
	} >"$STATE_FILE" 2>/dev/null
}

clear_state() { rm -f "$STATE_FILE" 2>/dev/null; }

# A fixture run must not scribble on a real session's bookkeeping or pop a
# notification at whoever is testing by hand. The suite opts back in, because it
# points STATE_DIR at a temp dir of its own.
may_write_state() {
	[ "${VPN_ETA_TEST_STATS+x}" != x ] || [ -n "${VPN_ETA_TEST_PERSIST:-}" ]
}

# Percent-encodes for a URL query. $2 lists extra characters to leave alone,
# which is how a file path keeps its slashes.
urlencode() {
	printf '%s' "$1" | awk -v keep="${2-}" '
		BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
		{
			for (i = 1; i <= length($0); i++) {
				c = substr($0, i, 1)
				if (c ~ /[A-Za-z0-9._~-]/ || (keep != "" && index(keep, c) > 0)) printf "%s", c
				else printf "%%%02X", ord[c]
			}
		}
	'
}

# SwiftBar holds the notification permission for the plugins it runs, so a
# warning routed through it arrives as SwiftBar rather than as some scripting
# host. Outside SwiftBar — a terminal run — osascript is the only sender there
# is. The first notification asks the user to allow SwiftBar once.
notify() {
	if [ -n "${VPN_ETA_NOTIFY_SINK:-}" ]; then
		printf '%s\t%s\n' "$1" "$2" >>"$VPN_ETA_NOTIFY_SINK" 2>/dev/null
		return 0
	fi
	if [ -n "${SWIFTBAR:-}" ] && [ -n "${SWIFTBAR_PLUGIN_PATH:-}" ]; then
		open -g "swiftbar://notify?plugin=$(urlencode "$(basename "$SWIFTBAR_PLUGIN_PATH")")&title=$(urlencode "$1")&body=$(urlencode "$2")" 2>/dev/null && return 0
	fi
	osascript -e "display notification $(printf '%s' "$2" | sed 's/["\\]/\\&/g; s/^/"/; s/$/"/') with title $(printf '%s' "$1" | sed 's/["\\]/\\&/g; s/^/"/; s/$/"/')" >/dev/null 2>&1
}

# One line per change of state, so an unexplained drop leaves a timestamp and a
# last known countdown behind instead of nothing. $2 is the identity of the
# state — an unchanged event with an unchanged identity writes nothing, which is
# what keeps a minute-by-minute plugin from filling a log with "still up".
# Sets previous_event, and returns 0 only when it wrote a new line.
record_event() {
	previous_event=
	may_write_state || return 1
	mkdir -p "$STATE_DIR" 2>/dev/null || return 1
	previous=$(cat "$EVENT_FILE" 2>/dev/null)
	previous_event=${previous%%|*}
	[ "$1|$2" = "$previous" ] && return 1
	printf '%s\n' "$1|$2" >"$EVENT_FILE" 2>/dev/null || return 1
	printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$3" >>"$HISTORY_FILE" 2>/dev/null
	trim_history
	return 0
}

trim_history() {
	lines=$(wc -l <"$HISTORY_FILE" 2>/dev/null | tr -d ' ')
	case $lines in '' | *[!0-9]*) return 0 ;; esac
	[ "$lines" -le $((HISTORY_MAX_LINES + 100)) ] && return 0
	tail -n "$HISTORY_MAX_LINES" "$HISTORY_FILE" >"$HISTORY_FILE.new" 2>/dev/null &&
		mv "$HISTORY_FILE.new" "$HISTORY_FILE" 2>/dev/null
}

mark_expected_teardown() {
	mkdir -p "$STATE_DIR" 2>/dev/null || return 0
	now_epoch >"$TEARDOWN_FILE" 2>/dev/null
}

expected_teardown() {
	[ -r "$TEARDOWN_FILE" ] || return 1
	stamp=$(cat "$TEARDOWN_FILE" 2>/dev/null)
	case $stamp in '' | *[!0-9]*) return 1 ;; esac
	[ $(($(now_epoch) - stamp)) -le "$TEARDOWN_GRACE_SECONDS" ]
}

# Marks already announced for the session now running. A different client
# address, or a countdown that jumped forward, is a different session, and its
# predecessor's marks say nothing about it.
carried_marks() {
	[ -n "$cached_notified" ] && [ -n "$cached_minutes" ] || return 0
	if [ -n "$cached_address" ] && [ -n "$2" ] && [ "$cached_address" != "$2" ]; then
		return 0
	fi
	[ "$1" -gt $((cached_minutes + 2)) ] && return 0
	printf '%s\n' "$cached_notified"
}

# Announces the lowest mark crossed since the last run and records every mark
# crossed, so one wake-up after a long sleep is one notification, not three.
# Prints the new mark list.
announce_marks() {
	minutes=$1
	marks=$2
	fresh=
	for mark in $NOTIFY_MARKS; do
		[ "$minutes" -le "$mark" ] || continue
		case ",$marks," in *",$mark,"*) continue ;; esac
		marks=${marks:+$marks,}$mark
		fresh=$mark
	done
	[ -n "$fresh" ] && notify "VPN session ending" \
		"About $(format_minutes "$minutes") left. Start a new session from the menu bar."
	printf '%s\n' "$marks"
}

# A session that ends by itself is worth interrupting for; one this plugin tore
# down on purpose is not.
announce_drop() {
	# A drop is only news if we believed a session was there. `transition` counts:
	# a tunnel seen renegotiating and then gone is exactly the drop worth hearing
	# about, and requiring `connected` would silence every disconnect that passed
	# through Reconnecting on the way out — which is most of them.
	case ${previous_event:-} in
	connected | transition) ;;
	*) return 0 ;;
	esac
	expected_teardown && return 0
	case ${1:-} in
	'' | *[!0-9]*) notify "VPN disconnected" "The tunnel is down." ;;
	*) notify "VPN disconnected" "The session ended with $(format_minutes "$1") of its time unused." ;;
	esac
}

# Sets cached_minutes / cached_address / cached_age_minutes, or returns 1.
load_state() {
	cached_minutes=
	cached_address=
	cached_age_minutes=
	cached_notified=
	[ -r "$STATE_FILE" ] || return 1
	cached_epoch=$(field "epoch=" "$(cat "$STATE_FILE")")
	cached_minutes=$(field "minutes=" "$(cat "$STATE_FILE")")
	cached_address=$(field "address=" "$(cat "$STATE_FILE")")
	cached_notified=$(field "notified=" "$(cat "$STATE_FILE")")
	case $cached_epoch$cached_minutes in
	'' | *[!0-9]*) return 1 ;;
	esac
	cached_age_minutes=$((($(now_epoch) - cached_epoch) / 60))
	[ "$cached_age_minutes" -ge 0 ] || return 1
	cached_minutes=$((cached_minutes - cached_age_minutes))
	return 0
}

cache_is_fresh() {
	[ "$cached_age_minutes" -le "$STALE_LIMIT_MINUTES" ] && [ "$cached_minutes" -gt 0 ]
}

# A cached countdown belongs to the session now running only if the tunnel still
# holds the address it was saved against — a different address means a new
# session with a new deadline. An address neither side reports proves nothing
# either way, so it does not veto.
cache_matches_session() {
	[ -z "$cached_address" ] || [ -z "$1" ] || [ "$cached_address" = "$1" ]
}

# The two actions differ by minutes and an SMS code, so they must not look
# alike: the countdown reread is instant and touches nothing, while starting a
# session tears the tunnel down and re-authenticates.
start_button() {
	echo "🔑  Start new session… | bash=$0 param0=start terminal=true refresh=true"
	if [ "${1-}" = active ]; then
		echo "Disconnects the current session first; Cisco sign-in may be required | color=gray size=11"
	else
		echo "Connects the saved VPN profile; Cisco sign-in may be required | color=gray size=11"
	fi
}

refresh_button() {
	echo "↻  Refresh countdown | refresh=true"
	echo "Re-reads the client; the VPN session is left alone | color=gray size=11"
}

# A history nobody can find is not worth keeping, so the menu says when the
# session last changed and opens the log on a click.
history_line() {
	[ -s "$HISTORY_FILE" ] || return 0
	last=$(tail -1 "$HISTORY_FILE" | awk -F'\t' '{ split($1, at, "T"); split(at[2], hm, ":"); printf "%s at %s:%s", $2, hm[1], hm[2] }')
	[ -n "$last" ] || return 0
	echo "🕘  Session log: ${last} | href=file://$(urlencode "$HISTORY_FILE" "/") size=11"
}

# One block, so every render offers the same two actions in the same order: the
# free one next to the reading it refreshes, the costly one fenced off below.
menu_actions() {
	if [ -n "$CONFIG_ERROR" ]; then
		echo "⚠️  Settings ignored: ${CONFIG_ERROR} has a syntax error | color=red size=12"
	fi
	history_line
	refresh_button
	echo "---"
	start_button "$1"
}

start_new_session() {
	if ! find_vpn; then
		echo "Cisco Secure Client not found."
		return 1
	fi

	# A configured host wins outright, and is passed to the client verbatim —
	# Cisco accepts a saved profile name or a full URL there, and second-guessing
	# which one this is would only rule out the valid other.
	host=${VPN_ETA_HOST:-}
	if [ -z "$host" ]; then
		hosts=$(run_vpn hosts)
		hosts_rc=$?
		if [ "$hosts_rc" -ne 0 ]; then
			echo "Could not read the saved Cisco VPN profiles."
			return 1
		fi

		host_list=$(printf '%s\n' "$hosts" | awk '
			/^[[:space:]]*\[hosts\]:/ { in_hosts=1; next }
			in_hosts && /^[[:space:]]*>/ {
				sub(/^[[:space:]]*>[[:space:]]*/, "")
				print
			}
		')
		host_count=$(printf '%s' "$host_list" | grep -c . | tr -d ' ')

		# One saved profile needs no configuring; several are ambiguous, and
		# guessing would connect somebody to the wrong network. Name them, so
		# choosing is a copy of one line rather than a hunt through Cisco's UI.
		if [ "$host_count" -eq 0 ]; then
			echo "Cisco Secure Client has no saved VPN profiles to connect to."
			echo "Add one in Cisco Secure Client, or set VPN_ETA_HOST in ${VPN_ETA_CONFIG}."
			return 1
		fi
		if [ "$host_count" -gt 1 ]; then
			echo "Cisco Secure Client has ${host_count} saved profiles, so this needs telling which one:"
			printf '%s\n' "$host_list" | sed 's/^/    /'
			echo
			echo "Put one of them in ${VPN_ETA_CONFIG}, for example:"
			echo "    VPN_ETA_HOST=\"$(printf '%s\n' "$host_list" | head -1)\""
			return 1
		fi
		host=$host_list
	fi

	if ! read_stats; then
		echo "Could not read the current Cisco VPN state."
		return 1
	fi

	case $(connection_state "$stats") in
	Connected | Connecting | Reconnecting | Disconnecting)
		has_session=1
		echo "This will disconnect the current VPN and start a new session."
		echo "Cisco sign-in may be required, and VPN access will be unavailable until it succeeds."
		;;
	*)
		has_session=0
		# No prompt follows on this path, so the line says what is happening
		# rather than what is about to be asked.
		echo "Starting a new VPN session. Cisco sign-in may be required."
		;;
	esac
	# Clicking the menu item is the decision, so there is nothing left to ask
	# when no session stands to be lost. Tearing a live one down is the case
	# worth a second look, and there Enter is yes: anything else cancels, and
	# Cisco's own sign-in is another chance to walk away. A prompt nobody is
	# there to answer — stdin at EOF — is not a yes.
	if [ "$has_session" -eq 1 ]; then
		printf "Continue? [Y/n] "
		IFS= read -r answer || answer=n
		case "$answer" in
		'' | y | Y | yes | YES) ;;
		*)
			echo "Cancelled; the VPN session was not changed."
			return 0
			;;
		esac
	fi

	# The drop that follows is this plugin's doing, so it must not surface as a
	# notification the way an unexpected one does.
	mark_expected_teardown
	# From here the old session is gone whatever happens next, so its countdown
	# must not outlive it. Clearing only on success leaves the previous deadline
	# cached whenever connect returns without one — a reply Cisco does send — and
	# the guard that normally catches a foreign deadline is the client address,
	# which proves nothing when the gateway hands the same one back.
	clear_state

	if [ "$has_session" -eq 1 ]; then
		echo "Disconnecting the current VPN session..."
		if ! "$VPN" disconnect; then
			echo "Cisco could not disconnect the current session."
			return 1
		fi
		sleep 2
	fi

	if ! "$VPN" connect "$host"; then
		echo "Cisco could not establish a new session."
		return 1
	fi

	new_remaining=
	attempt=1
	while [ "$attempt" -le "$CONNECT_POLL_ATTEMPTS" ]; do
		if new_stats=$(run_vpn stats); then
			new_remaining=$(session_remaining "$new_stats")
			[ -n "$new_remaining" ] && break
		fi
		sleep "$CONNECT_POLL_SLEEP"
		attempt=$((attempt + 1))
	done

	if [ -z "$new_remaining" ]; then
		echo "Cisco returned from connect, but no new session countdown appeared."
		echo "Check Cisco Secure Client before relying on the VPN connection."
		return 1
	fi
	echo "New VPN session established: ${new_remaining}."
}

# Renders the "the client would not answer" case, which is where the old plugin
# wrongly claimed the VPN was off. Falls back to the last known countdown for as
# long as the tunnel the client reported is still bound.
render_unreadable() {
	detail=$1
	if load_state && tunnel_has_address "$cached_address" && cache_is_fresh; then
		short=$(format_minutes "$cached_minutes")
		record_event unreadable "$cached_address" "estimated=${cached_minutes}m tunnel=up"
		echo "${BAR_PREFIX}$(format_menubar "$cached_minutes") | color=$(color_for_minutes "$cached_minutes")"
		echo "---"
		echo "🔐  about ${short} remaining | size=14"
		echo "Tunnel is still up; countdown estimated | color=gray size=12"
		echo "${detail}, last confirmed ${cached_age_minutes}m ago | color=gray size=12"
	elif any_tunnel_up; then
		record_event unreadable "" "tunnel=up client=silent"
		echo "${BAR_PREFIX}? | color=orange"
		echo "---"
		echo "A tunnel is up but the session could not be read | color=orange size=12"
		echo "${detail} | color=gray size=12"
		echo "Open Cisco Secure Client to check | color=gray size=12"
	else
		# No tunnel and no readable reply is the strongest evidence this render
		# has that a session ended, so it is the one that may announce a drop.
		if record_event down "" "tunnel=none client=silent last_remaining=${cached_minutes:-unknown}"; then
			announce_drop "${cached_minutes:-}"
		fi
		echo "${BAR_PREFIX}off | color=gray"
		echo "---"
		echo "No tunnel interface and no readable session | color=gray size=12"
		echo "${detail} | color=gray size=12"
	fi
	echo "---"
	menu_actions disconnected
}

# SwiftBar's `refresh=true` fires when the item is CLICKED, which is a minute or
# more before any of this finishes — it reads the menu bar while the old tunnel
# is still coming down, so a fresh session leaves "off" on screen until the next
# scheduled run. Ask SwiftBar to read again once there is something new to read.
refresh_menu_bar() {
	[ -n "${SWIFTBAR:-}" ] || return 0
	# SwiftBar names a plugin by the part before the first dot — `vpn-eta`, not
	# `vpn-eta.1m.sh`. The full filename is accepted by the URL handler and then
	# matches nothing, so it fails silently. Measured against a run counter:
	# `?name=vpn-eta.1m.sh` re-ran the plugin zero times, `?name=vpn-eta` once.
	plugin_name=$(basename "${SWIFTBAR_PLUGIN_PATH:-$0}")
	plugin_name=${plugin_name%%.*}
	url="swiftbar://refreshplugin?name=$(urlencode "$plugin_name")"
	# The suite cannot stub `open` on PATH, because this script sets its own PATH
	# above. Same seam as VPN_ETA_NOTIFY_SINK, for the same reason.
	if [ -n "${VPN_ETA_REFRESH_SINK:-}" ]; then
		printf '%s\n' "$url" >>"$VPN_ETA_REFRESH_SINK" 2>/dev/null
		return 0
	fi
	open -g "$url" >/dev/null 2>&1 || true
}

if [ "${1-}" = --version ] || [ "${1-}" = -v ]; then
	printf 'vpn-eta %s\n' "$VERSION"
	exit 0
fi

if [ "${1-}" = start ]; then
	start_new_session
	start_rc=$?
	# Every exit path, not just success: a connect that failed also leaves the
	# menu bar showing something that is no longer true.
	refresh_menu_bar
	exit "$start_rc"
fi

if [ "${VPN_ETA_TEST_STATS+x}" = x ]; then
	stats=$VPN_ETA_TEST_STATS
	stats_rc=${VPN_ETA_TEST_RC:-0}
	if [ "$stats_rc" -ne 0 ] || ! stats_is_readable "$stats"; then
		render_unreadable "Cisco Secure Client did not answer"
		exit 0
	fi
else
	if ! find_vpn; then
		echo "${BAR_PREFIX}? | color=red"
		echo "---"
		echo "Cisco Secure Client not found | color=red"
		exit 0
	fi

	if ! read_stats; then
		render_unreadable "Cisco Secure Client did not answer"
		exit 0
	fi
fi

state=$(connection_state "$stats")
# The client owns the deadline. Its Session Disconnect field is more
# reliable than an ETA derived from the uptime of a long-lived daemon — but it
# is optional, so its absence says nothing about whether the tunnel is up.
remaining=$(session_remaining "$stats")

# Cisco between states is not a session ending. A reconnect is the most ordinary
# thing that happens to a laptop VPN — a Wi-Fi handover is enough — and calling
# it a drop would flash "off", wipe the deadline and fire a notification about a
# disconnect that never happened. The deadline has not moved, so it is carried.
# The same three states already count as a live session at the teardown prompt;
# this is what keeps the two halves of the script telling the same story.
if [ -z "$remaining" ]; then
	case $state in
	Connecting | Reconnecting | Disconnecting)
		record_event transition "" "state=$state"
		if load_state && cache_is_fresh; then
			short=$(format_minutes "$cached_minutes")
			echo "${BAR_PREFIX}$(format_menubar "$cached_minutes") | color=$(color_for_minutes "$cached_minutes")"
			echo "---"
			echo "🔐  about ${short} remaining | size=14"
			echo "${state}… | color=orange size=12"
			echo "Deadline carried from a reading ${cached_age_minutes}m ago | color=gray size=12"
		else
			echo "${BAR_PREFIX}… | color=orange"
			echo "---"
			echo "🔐  ${state}… | color=orange size=14"
			echo "No countdown yet for this session | color=gray size=12"
		fi
		echo "---"
		menu_actions active
		exit 0
		;;
	esac
fi

if [ -z "$remaining" ] && [ "$state" != Connected ]; then
	# Read the cache before clearing it: how much of the session went unused is
	# the one thing worth saying in the notification, and it lives there.
	load_state || :
	if record_event disconnected "" "state=${state:-Disconnected} last_remaining=${cached_minutes:-unknown}"; then
		announce_drop "${cached_minutes:-}"
	fi
	clear_state
	echo "${BAR_PREFIX}off | color=gray"
	echo "---"
	echo "${state:-Disconnected} | color=gray"
	echo "---"
	menu_actions disconnected
	exit 0
fi

if [ -z "$remaining" ]; then
	# Connected, but this reply carries no countdown this parse accepts. A
	# deadline the client already reported does not move, so extrapolate rather
	# than blank the number out, on the same trust window an unreadable reply
	# gets. Here the client itself vouches for the tunnel, so the address only
	# has to rule out a *different* session.
	#
	# Two different replies land here — no Session Disconnect line at all, or a
	# line whose value is not a countdown — and they are indistinguishable once
	# session_remaining has dropped the value. So print whatever the client did
	# send. Observed 2026-08-08 on a healthy session 18h in, with the GUI showing
	# a correct countdown at the same moment: `Session Disconnect: Not Available`,
	# gone again two minutes later. Without this line that reply is impossible to
	# tell from a missing field, and the wrong one gets blamed.
	reported=$(field "Session Disconnect:" "$stats")
	# The client vouches for the tunnel here, so this is still the same session
	# as far as the log is concerned. No mark is announced off an extrapolated
	# countdown: nothing may refresh the state file on this path, and a mark that
	# cannot be written down would fire again every minute.
	record_event connected "$(client_address "$stats")" "remaining=unreported (client sent ${reported:-nothing})"
	if load_state && cache_is_fresh && cache_matches_session "$(client_address "$stats")"; then
		short=$(format_minutes "$cached_minutes")
		echo "${BAR_PREFIX}$(format_menubar "$cached_minutes") | color=$(color_for_minutes "$cached_minutes")"
		echo "---"
		echo "🔐  about ${short} remaining | size=14"
		echo "Estimated from a reading ${cached_age_minutes}m ago | color=gray size=12"
		echo "${reported:-Connected, but the client sent no session countdown} | color=gray size=12"
	else
		echo "${BAR_PREFIX}on | color=green"
		echo "---"
		echo "🔐  Connected | color=green size=14"
		if [ -n "$reported" ]; then
			echo "Session Disconnect: ${reported} | color=gray size=12"
		else
			echo "No session countdown reported | color=gray size=12"
		fi
	fi
	echo "---"
	menu_actions active
	exit 0
fi

total_minutes=$(remaining_to_minutes "$remaining")
short=$(format_minutes "$total_minutes")
color=$(color_for_minutes "$total_minutes")

address=$(client_address "$stats")
if may_write_state; then
	# Which marks this session has already announced rides along in the state
	# file, so the warning fires once rather than every minute for an hour.
	load_state || :
	marks=$(carried_marks "$total_minutes" "$address")
	marks=$(announce_marks "$total_minutes" "$marks")
	save_state "$total_minutes" "$address" "$marks"
	record_event connected "$address" "remaining=${total_minutes}m"
fi

echo "${BAR_PREFIX}$(format_menubar "$total_minutes") | color=$color"
echo "---"
echo "🔐  ${short} remaining | color=$color size=14"
echo "Session limit set by the gateway | color=gray size=12"
echo "Cisco Secure Client: ${remaining} | color=gray size=12"
if [ -n "$state" ] && [ "$state" != Connected ]; then
	echo "Connection state: ${state} | color=orange size=12"
fi
echo "---"
menu_actions active
