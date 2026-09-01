#!/bin/bash
# Fixture tests for vpn-eta.1m.sh. Run: ./vpn-eta.test.sh
set -u

# The tests live outside swiftbar/ on purpose: SwiftBar runs every executable
# file in its plugin folder — and chmods them executable itself — so a test
# script parked next to the plugin gets loaded as one.
PLUGIN=$(dirname "$0")/../swiftbar/vpn-eta.1m.sh
STATE_DIR=$(mktemp -d -t vpn-eta-test)
trap 'rm -rf "$STATE_DIR"' EXIT
export SWIFTBAR_PLUGIN_DATA_PATH=$STATE_DIR
# Set for every test, not just the notification ones: a suite that can reach the
# real notification centre would interrupt whoever runs it.
export VPN_ETA_NOTIFY_SINK=$STATE_DIR/notifications
# Whoever runs the suite probably uses the plugin too, and their own config would
# otherwise decide what these assertions are measuring. /dev/null is readable and
# sources to nothing, so the plugin takes its documented defaults.
export VPN_ETA_CONFIG=/dev/null

pass=0
fail=0

check() {
	name=$1
	expected=$2
	actual=$3
	if [ "$actual" = "$expected" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: $name"
		echo "  expected: $expected"
		echo "  actual:   $actual"
	fi
}

first_line() { printf '%s\n' "$1" | head -1; }

# The plugin is copied out of the repository, so its own VERSION is the only
# provenance an installed copy has — and the bug-report template asks for it.
# Drift between it and the CHANGELOG is silent otherwise.
version_line=$("$PLUGIN" --version)
check "the plugin reports a version" "vpn-eta" "${version_line% *}"
changelog_version=$(awk '/^## \[/ { gsub(/[^0-9.]/, "", $2); print $2; exit }' \
	"$(dirname "$0")/../CHANGELOG.md")
check "and it matches the newest CHANGELOG entry" "vpn-eta $changelog_version" "$version_line"

CONNECTED='[ Connection Information ]

    Connection State:            Connected
    Duration:                    21:08:38
    Session Disconnect:          2 Hours 51 Minutes Remaining

[ Address Information ]

    Client Address (IPv4):       10.3.3.3'

CONNECTED_NO_COUNTDOWN='[ Connection Information ]

    Connection State:            Connected
    Duration:                    00:04:12

[ Address Information ]

    Client Address (IPv4):       10.3.3.3'

DISCONNECTED='[ Connection Information ]

    Connection State:            Disconnected'

# What the client prints when the CLI never attaches to the daemon: a banner and
# nothing else. This is the read that used to render as a confident "VPN off".
# The version is deliberately a round placeholder — nothing here should hint at
# which build any particular organisation deploys.
NOT_ATTACHED='Cisco Secure Client (version 5.1.0.0) release.

Copyright (c) 2004 - 2025, Cisco Systems, Inc. All rights reserved.

  >> state: Unknown
VPN>'

out=$(VPN_ETA_TEST_STATS=$CONNECTED "$PLUGIN")
check "connected shows the countdown" "VPN 2h 51m | color=green" "$(first_line "$out")"

out=$(VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          58 Minutes Remaining' "$PLUGIN")
check "under an hour turns orange" "VPN 58m | color=orange" "$(first_line "$out")"

out=$(VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          11 Minutes Remaining' "$PLUGIN")
check "the last quarter hour turns red" "VPN 11m | color=red" "$(first_line "$out")"

out=$(VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          1 Day 3 Hours 5 Minutes Remaining' "$PLUGIN")
check "days are formatted" "VPN 1d 3h | color=green" "$(first_line "$out")"

rm -f "$STATE_DIR/last-session"
out=$(VPN_ETA_TEST_STATS=$CONNECTED_NO_COUNTDOWN "$PLUGIN")
check "connected without a countdown is not off" "VPN on | color=green" "$(first_line "$out")"

# The regression this pair guards: Cisco intermittently drops Session Disconnect
# from an otherwise healthy reply, which used to blank the number out for that
# whole refresh even though a good reading was sitting in the cache.
# Age in seconds, minutes remaining, client address. Named apart from the
# seed_cache below, which fixes the countdown at 180 and takes the address
# second: one name for both is how a 3-arg call silently became a 2-arg one,
# seeding the address 500.
seed_cache_minutes() {
	printf 'epoch=%s\nminutes=%s\naddress=%s\n' "$(($(date +%s) - $1))" "$2" "$3" \
		>"$STATE_DIR/last-session"
}

seed_cache_minutes 600 180 10.3.3.3
out=$(VPN_ETA_TEST_STATS=$CONNECTED_NO_COUNTDOWN "$PLUGIN")
check "a dropped countdown is extrapolated" "VPN 2h 50m | color=green" "$(first_line "$out")"

# A different address is a different session, so its deadline says nothing.
seed_cache_minutes 600 180 10.0.0.1
out=$(VPN_ETA_TEST_STATS=$CONNECTED_NO_COUNTDOWN "$PLUGIN")
check "a cache from another session is not extrapolated" "VPN on | color=green" "$(first_line "$out")"

seed_cache_minutes 7200 180 10.3.3.3
out=$(VPN_ETA_TEST_STATS=$CONNECTED_NO_COUNTDOWN "$PLUGIN")
check "a stale cache is not extrapolated" "VPN on | color=green" "$(first_line "$out")"
rm -f "$STATE_DIR/last-session"

# A field that is present but not a countdown lands in the same branch as a
# missing one. Print what the client sent, so the two stay tellable apart.
CONNECTED_ODD_COUNTDOWN='[ Connection Information ]

    Connection State:            Connected
    Session Disconnect:          Not Available

[ Address Information ]

    Client Address (IPv4):       10.3.3.3'

out=$(VPN_ETA_TEST_STATS=$CONNECTED_ODD_COUNTDOWN "$PLUGIN")
check "a non-countdown value is quoted back" "Session Disconnect: Not Available" \
	"$(printf '%s\n' "$out" | sed -n '4s/ | .*//p')"
out=$(VPN_ETA_TEST_STATS=$CONNECTED_NO_COUNTDOWN "$PLUGIN")
check "a missing field says so instead" "No session countdown reported" \
	"$(printf '%s\n' "$out" | sed -n '4s/ | .*//p')"

out=$(VPN_ETA_TEST_STATS=$DISCONNECTED "$PLUGIN")
check "a reported disconnect is off" "VPN off | color=gray" "$(first_line "$out")"

# The regression: an unreadable reply must never claim the VPN is off while a
# tunnel is up. With no cache and no tunnel to corroborate, it must say unknown
# only if a tunnel exists — so assert on which branch was taken, not the host.
rm -f "$STATE_DIR/last-session"
out=$(VPN_ETA_TEST_STATS=$NOT_ATTACHED "$PLUGIN")
case $(first_line "$out") in
"VPN ? | color=orange")
	check "unreadable with a tunnel up says unknown" \
		"A tunnel is up but the session could not be read" \
		"$(printf '%s\n' "$out" | sed -n '3s/ | .*//p')"
	;;
"VPN off | color=gray")
	check "unreadable with no tunnel may say off" \
		"No tunnel interface and no readable session" \
		"$(printf '%s\n' "$out" | sed -n '3s/ | .*//p')"
	;;
*)
	fail=$((fail + 1))
	echo "FAIL: unreadable reply produced an unexpected first line: $(first_line "$out")"
	;;
esac

out=$(VPN_ETA_TEST_STATS=$CONNECTED VPN_ETA_TEST_RC=1 "$PLUGIN")
case $(first_line "$out") in
"VPN ? | color=orange" | "VPN off | color=gray") pass=$((pass + 1)) ;;
*)
	fail=$((fail + 1))
	echo "FAIL: a nonzero exit produced: $(first_line "$out")"
	;;
esac

# What the menu says about a silent client is the whole of what a bug report can
# carry, and "did not answer" covered a stopped daemon, a call that ran out of
# time and an unrecognised reply alike. Every branch of render_unreadable prints
# the detail, so which one this host takes does not matter — grep the lot.
#
# Cisco's launchd audit, which is where a client that never came up says so. The
# version banner sits in the same reply and names no cause, so it must lose.
rm -f "$STATE_DIR/last-session"
out=$(VPN_ETA_TEST_STATS='Overall: not ok
LaunchDaemon(com.cisco.secureclient.vpn.service.agent.plist) status: disabled
Cisco Secure Client (version 5.1.14.145) release.' "$PLUGIN")
check "a silent client quotes its own audit, not a banner" "true" \
	"$(printf '%s\n' "$out" | grep -q 'said: Overall: not ok' && echo true || echo false)"

# The banner is what a client with nothing else to say leads with, and dropping
# it must not leave the menu quoting a blank.
out=$(VPN_ETA_TEST_STATS='Cisco Secure Client (version 5.1.14.145) release.

Copyright (c) 2004 - 2025, Cisco Systems, Inc. All rights reserved.' "$PLUGIN")
check "a reply that is only a banner is not quoted" "true" \
	"$(printf '%s\n' "$out" | grep -q 'sent no reply' && echo true || echo false)"

# A complaint outranks whatever the client printed before it.
out=$(VPN_ETA_TEST_STATS='Overall: ok
  >> error: Connection attempt has failed.' "$PLUGIN")
# The trailing ` |` is load-bearing: the detail has to be ONE menu item. awk's
# `exit` runs END on the way out, so the fallback line printed under the
# complaint and stripped the params off it — a defect a bare text match misses.
check "an error line outranks the lines above it" "true" \
	"$(printf '%s\n' "$out" | grep -q 'said: error: Connection attempt has failed |' &&
		echo true || echo false)"
check "and the detail stays a single menu item" "1" \
	"$(printf '%s\n' "$out" | grep -c 'Overall\|said:')"

# The watchdog fired: the reply is not the evidence, its absence is.
out=$(VPN_ETA_TEST_STATS=$CONNECTED VPN_ETA_TEST_RC=124 "$PLUGIN")
check "a timed-out call blames the clock, not the reply" "true" \
	"$(printf '%s\n' "$out" | grep -q 'did not answer within 12s' && echo true || echo false)"
check "and the timeout wording follows the configured limit" "true" \
	"$(env VPN_ETA_TIMEOUT=5 VPN_ETA_TEST_STATS="$CONNECTED" VPN_ETA_TEST_RC=124 "$PLUGIN" |
		grep -q 'did not answer within 5s' && echo true || echo false)"

# Nothing at all is its own diagnosis and must not be dressed as a quotation.
out=$(VPN_ETA_TEST_STATS='' "$PLUGIN")
check "an empty reply says so rather than quoting nothing" "true" \
	"$(printf '%s\n' "$out" | grep -q 'sent no reply' && echo true || echo false)"

# The menu is as wide as its widest item, so a runaway line is cut — between
# words, because half a word is not a shorter sentence.
long=$(awk 'BEGIN { for (i = 0; i < 40; i++) printf "widget " }')
out=$(VPN_ETA_TEST_STATS=">> error: $long" "$PLUGIN")
said=$(printf '%s\n' "$out" | sed -n 's/.*said: \(.*\) | color.*/\1/p')
check "a runaway line is shortened" "true" \
	"$([ "${#said}" -le 101 ] && echo true || echo false)"
check "and it is cut between words" "true" \
	"$(printf '%s' "$said" | grep -q 'widget…$' && echo true || echo false)"

# The word boundary is a preference with a floor under it. Honouring it as a rule
# drops a word longer than the whole budget, and the menu then says `error:…` —
# less than the sentence this replaced, in the one case where the client's own
# words are all there is.
tok=$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "x" }')
out=$(VPN_ETA_TEST_STATS=">> error: $tok" "$PLUGIN")
said=$(printf '%s\n' "$out" | sed -n 's/.*said: \(.*\) | color.*/\1/p')
check "an over-long word is clipped, not dropped" "true" \
	"$([ "${#said}" -ge 80 ] && [ "${#said}" -le 101 ] && echo true || echo false)"

# The quote lands mid-sentence in the extrapolating branch, which appends
# ", last confirmed Nm ago" — so `has failed., last confirmed` is a collision.
out=$(VPN_ETA_TEST_STATS='  >> error: Connection attempt has failed.' "$PLUGIN")
check "a quoted sentence loses its full stop" "false" \
	"$(printf '%s\n' "$out" | grep -q 'has failed\.' && echo true || echo false)"
# Paired with the above so it cannot pass by quoting nothing at all.
check "and the sentence itself survives the trim" "true" \
	"$(printf '%s\n' "$out" | grep -q 'said: error: Connection attempt has failed' &&
		echo true || echo false)"
rm -f "$STATE_DIR/last-session" "$STATE_DIR/last-event"

# A stale countdown is extrapolated only while the cached address is still bound
# to a utun. This used to read the host's OWN ifconfig and skip the whole block
# when it found no tunnel — so the branch the plugin exists for went untested on
# exactly the machine most likely to run the suite, a CI runner, and the "no
# tunnel at all" direction could not be tested on a developer's machine that had
# one. VPN_ETA_TEST_IFCONFIG substitutes the reading, so both directions run
# everywhere and the awk that parses it is still the code under test.
TUNNEL_UP='lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1300
	inet 10.0.0.2 --> 10.0.0.2 netmask 0xffffffff'
NO_TUNNEL='lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255'

seed_cache() {
	printf 'epoch=%s\nminutes=180\naddress=%s\n' "$(($(date +%s) - $1))" "${2:-10.0.0.2}" \
		>"$STATE_DIR/last-session"
}

seed_cache 600
out=$(VPN_ETA_TEST_IFCONFIG=$TUNNEL_UP VPN_ETA_TEST_STATS=$NOT_ATTACHED "$PLUGIN")
check "a live tunnel keeps the countdown alive" "VPN 2h 50m | color=green" "$(first_line "$out")"
# This render says a session is up and how long it has left, so the item that
# ends one belongs here too — otherwise the picture and the actions disagree. It
# is also the branch where Start cannot help: a client that will not answer
# `stats` will not answer `hosts` either, while disconnect needs neither.
check "a countdown held up by a live tunnel can still be ended" "1" \
	"$(printf '%s\n' "$out" | grep -c 'param0=disconnect')"

# The cached address is a session identity, not a liveness flag: a tunnel holding
# a DIFFERENT address is a different session, whose deadline says nothing here.
seed_cache 600 10.9.9.9
check "a tunnel holding another address does not revive the countdown" "VPN ? | color=orange" \
	"$(first_line "$(VPN_ETA_TEST_IFCONFIG=$TUNNEL_UP VPN_ETA_TEST_STATS=$NOT_ATTACHED "$PLUGIN")")"

seed_cache 7200
check "a cache past the staleness limit is dropped" "VPN ? | color=orange" \
	"$(first_line "$(VPN_ETA_TEST_IFCONFIG=$TUNNEL_UP VPN_ETA_TEST_STATS=$NOT_ATTACHED "$PLUGIN")")"

# The other direction, which no machine with a VPN up could reach before: no
# tunnel and no readable reply is the only evidence strong enough for `off`.
seed_cache 600
check "no tunnel and no readable reply may say off" "VPN off | color=gray" \
	"$(first_line "$(VPN_ETA_TEST_IFCONFIG=$NO_TUNNEL VPN_ETA_TEST_STATS=$NOT_ATTACHED "$PLUGIN")")"

# A real disconnect must clear the cache so it cannot resurface later.
printf 'epoch=%s\nminutes=180\naddress=%s\n' "$(date +%s)" "10.0.0.1" \
	>"$STATE_DIR/last-session"
VPN_ETA_TEST_STATS=$DISCONNECTED "$PLUGIN" >/dev/null
if [ -e "$STATE_DIR/last-session" ]; then
	fail=$((fail + 1))
	echo "FAIL: a reported disconnect left the cache in place"
else
	pass=$((pass + 1))
fi

# Both actions carried the ↻ glyph and sat next to each other, so an instant
# reread and a tear-down-plus-SMS-reauth read as the same kind of button.
# Every action item carries refresh=true now, so the reread is picked out by
# being the only one that runs no command: `param0=` is what the others have.
out=$(VPN_ETA_TEST_STATS=$CONNECTED "$PLUGIN")
start_glyph=$(printf '%s\n' "$out" | grep 'param0=start' | awk '{print $1}')
refresh_glyph=$(printf '%s\n' "$out" | grep 'refresh=true' | grep -v 'param0=' | awk '{print $1}')
check "the session action does not wear the refresh glyph" "false" \
	"$([ "$start_glyph" = "$refresh_glyph" ] && echo true || echo false)"
check "the reread says what it does not touch" \
	"Re-reads the client; the VPN session is left alone" \
	"$(printf '%s\n' "$out" | grep 'Re-reads' | sed 's/ | .*//')"
start_at=$(printf '%s\n' "$out" | grep -n 'param0=start' | cut -d: -f1)
refresh_at=$(printf '%s\n' "$out" | grep -n 'refresh=true' | grep -v 'param0=' | cut -d: -f1)
check "the cheap action comes first" "true" \
	"$([ "$refresh_at" -lt "$start_at" ] && echo true || echo false)"

# Ending a session and starting one are one rule apart: the first is offered
# only when there is a session to end, and both sit below the rule that fences
# them off from the items that leave the VPN alone.
check "a live session can be ended from the menu" "1" \
	"$(printf '%s\n' "$out" | grep -c 'param0=disconnect')"
disconnect_at=$(printf '%s\n' "$out" | grep -n 'param0=disconnect' | cut -d: -f1)
rule_at=$(printf '%s\n' "$out" | grep -n '^---$' | tail -1 | cut -d: -f1)
check "and it is fenced off with the other costly one" "true" \
	"$([ "$disconnect_at" -gt "$rule_at" ] && echo true || echo false)"
out=$(VPN_ETA_TEST_STATS=$DISCONNECTED "$PLUGIN")
check "nothing to end means nothing to offer" "0" \
	"$(printf '%s\n' "$out" | grep -c 'param0=disconnect')"
# A tunnel renegotiating is still a session, and being unable to end one that
# will not settle is exactly when the button is wanted.
out=$(VPN_ETA_TEST_STATS='    Connection State:            Reconnecting' "$PLUGIN")
check "a reconnecting session can still be ended" "1" \
	"$(printf '%s\n' "$out" | grep -c 'param0=disconnect')"

# ---------------------------------------------------------------------------
# The start path: it disconnects and reconnects a live VPN, so it is exercised
# against a fake client rather than Cisco's. VPN_ETA_VPN_BIN is the only reason
# that override exists.

FAKE_DIR=$STATE_DIR/fake
mkdir -p "$FAKE_DIR"
export FAKE_VPN_DIR=$FAKE_DIR
cat >"$FAKE_DIR/vpn" <<'FAKE'
#!/bin/bash
# Stands in for /opt/cisco/secureclient/bin/vpn. Records every call, and answers
# `stats` from whichever fixture the current state names.
printf '%s\n' "$*" >>"$FAKE_VPN_DIR/log"
case ${1-} in
hosts) cat "$FAKE_VPN_DIR/hosts" ;;
stats) cat "$FAKE_VPN_DIR/$(cat "$FAKE_VPN_DIR/state").stats" ;;
connect)
	printf '%s\n' "${FAKE_VPN_AFTER_CONNECT:-connected}" >"$FAKE_VPN_DIR/state"
	exit "${FAKE_VPN_CONNECT_RC:-0}"
	;;
disconnect)
	printf 'disconnected\n' >"$FAKE_VPN_DIR/state"
	exit "${FAKE_VPN_DISCONNECT_RC:-0}"
	;;
esac
FAKE
chmod +x "$FAKE_DIR/vpn"

printf '    [hosts]:\n\n    > gw.example.com\n' >"$FAKE_DIR/hosts"
printf '    Connection State:            Disconnected\n' >"$FAKE_DIR/disconnected.stats"
printf '    Connection State:            Connected\n    Session Disconnect:          23 Hours 59 Minutes Remaining\n    Client Address (IPv4):       10.9.9.9\n' >"$FAKE_DIR/connected.stats"
printf '    Connection State:            Connected\n    Session Disconnect:          Not Available\n' >"$FAKE_DIR/nocountdown.stats"

# Runs the start path with the fake client. $1 is the answer piped to the
# prompt, $2 the state the fake starts in; the rest are extra environment.
run_start() {
	answer=$1
	printf '%s\n' "$2" >"$FAKE_DIR/state"
	: >"$FAKE_DIR/log"
	shift 2
	# `env -u` first, assignments after, so a case that wants SwiftBar still gets
	# it. Without the scrub these two leak in from whoever runs the suite — a
	# shell started by SwiftBar itself exports both — and the case that asserts a
	# terminal run refreshes NOTHING passes or fails on the ambient environment
	# rather than on the plugin. Measured: it failed on an untouched checkout.
	printf '%s\n' "$answer" | env -u SWIFTBAR -u SWIFTBAR_PLUGIN_PATH "$@" \
		VPN_ETA_VPN_BIN="$FAKE_DIR/vpn" \
		VPN_ETA_CONNECT_ATTEMPTS=2 VPN_ETA_CONNECT_SLEEP=0 \
		"$PLUGIN" start
}

seed_cache 60 10.9.9.9
out=$(run_start n connected)
start_rc=$?
# The prompt has no trailing newline, so the reply lands on the prompt's line.
check "declining leaves the session alone" "Cancelled; the VPN session was not changed." \
	"$(printf '%s\n' "$out" | tail -1 | sed 's/^Continue? \[Y\/n\] //')"
check "declining is not an error" "0" "$start_rc"
check "declining runs no connect" "" "$(grep -c '^connect' "$FAKE_DIR/log" | tr -d ' ' | sed 's/^0$//')"

# Enter is the answer the prompt already assumes, and the only reason the prompt
# is still there is that a live session is about to go.
seed_cache 60 10.9.9.9
out=$(run_start "" connected)
check "an empty answer accepts" \
	"New VPN session established: 23 Hours 59 Minutes Remaining." \
	"$(printf '%s\n' "$out" | tail -1)"

# Nothing to lose, nothing to ask: the click was the confirmation.
out=$(run_start "" disconnected)
check "no session means no prompt at all" "" \
	"$(printf '%s\n' "$out" | grep -c 'Continue?' | sed 's/^0$//')"
check "and it starts anyway" "connect gw.example.com" "$(grep '^connect' "$FAKE_DIR/log")"

# An unanswerable prompt is not a yes: EOF must not tear a live session down.
seed_cache 60 10.9.9.9
printf 'connected\n' >"$FAKE_DIR/state"
: >"$FAKE_DIR/log"
out=$(env VPN_ETA_VPN_BIN="$FAKE_DIR/vpn" VPN_ETA_CONNECT_ATTEMPTS=2 VPN_ETA_CONNECT_SLEEP=0 \
	"$PLUGIN" start </dev/null)
check "a prompt at EOF cancels" "Cancelled; the VPN session was not changed." \
	"$(printf '%s\n' "$out" | tail -1 | sed 's/^Continue? \[Y\/n\] //')"
check "and disconnects nothing" "0" "$(grep -c '^disconnect' "$FAKE_DIR/log" | tr -d ' ')"

out=$(run_start y disconnected)
check "a fresh start reports the new countdown" \
	"New VPN session established: 23 Hours 59 Minutes Remaining." \
	"$(printf '%s\n' "$out" | tail -1)"
check "a fresh start does not disconnect first" "0" "$(grep -c '^disconnect' "$FAKE_DIR/log" | tr -d ' ')"
check "a fresh start connects the saved host" "connect gw.example.com" \
	"$(grep '^connect' "$FAKE_DIR/log")"

seed_cache 60 10.9.9.9
out=$(run_start y connected)
check "an active session is torn down first" "1" "$(grep -c '^disconnect' "$FAKE_DIR/log" | tr -d ' ')"
check "and replaced by a new one" \
	"New VPN session established: 23 Hours 59 Minutes Remaining." \
	"$(printf '%s\n' "$out" | tail -1)"

# The regression this guards: a connect that returns without a countdown used to
# leave the previous session's deadline cached. The address cannot veto it —
# a gateway may hand the same one back — so the cache has to go at teardown.
seed_cache 60 10.9.9.9
out=$(run_start y connected FAKE_VPN_AFTER_CONNECT=nocountdown)
start_rc=$?
check "a connect without a countdown is an error" "1" "$start_rc"
if [ -e "$STATE_DIR/last-session" ]; then
	fail=$((fail + 1))
	echo "FAIL: a replaced session left its old countdown in the cache"
else
	pass=$((pass + 1))
fi

# Several saved profiles: the plugin must not guess which network you meant.
printf '    [hosts]:\n\n    > gw.example.com\n    > gw2.example.com\n' >"$FAKE_DIR/hosts"
out=$(run_start "" disconnected)
start_rc=$?
check "several saved hosts are refused" \
	"Cisco Secure Client has 2 saved profiles, so this needs telling which one:" \
	"$(first_line "$out")"
check "and refusing is an error" "1" "$start_rc"
check "and nothing was connected" "0" "$(grep -c '^connect' "$FAKE_DIR/log" | tr -d ' ')"
check "and both are named, so choosing is a copy" "gw.example.com gw2.example.com" \
	"$(printf '%s\n' "$out" | awk '/^    gw/ { printf "%s%s", sep, $1; sep = " " }')"
check "and the config line is spelled out" 'VPN_ETA_HOST="gw.example.com"' \
	"$(printf '%s\n' "$out" | awk '/VPN_ETA_HOST=/ { $1 = $1; print; exit }')"

# ... and with one configured, several saved profiles stop being a problem.
out=$(run_start "" disconnected VPN_ETA_HOST=gw2.example.com)
check "a configured host is used as given" "connect gw2.example.com" \
	"$(grep '^connect' "$FAKE_DIR/log")"
check "and the countdown comes back" \
	"New VPN session established: 23 Hours 59 Minutes Remaining." \
	"$(printf '%s\n' "$out" | tail -1)"

# A configured host is passed through untouched, so a full URL works where a
# profile name would not — Cisco accepts either.
out=$(run_start "" disconnected VPN_ETA_HOST=https://vpn.example.org/group)
check "a URL is passed through untouched" "connect https://vpn.example.org/group" \
	"$(grep '^connect' "$FAKE_DIR/log")"

# No profiles at all is a different failure from too many, and says so.
printf '    [hosts]:\n\n' >"$FAKE_DIR/hosts"
out=$(run_start "" disconnected)
start_rc=$?
check "no saved hosts is its own message" \
	"Cisco Secure Client has no saved VPN profiles to connect to." \
	"$(first_line "$out")"
check "and that is an error too" "1" "$start_rc"

printf '    [hosts]:\n\n    > gw.example.com\n' >"$FAKE_DIR/hosts"

# SwiftBar refreshes the item when it is CLICKED — before the old tunnel is even
# down. Without a nudge at the end, a brand new session sits behind a stale
# "VPN off" until the next scheduled minute, which is what sent a user hunting
# for the Refresh item by hand.
REFRESH_SINK=$STATE_DIR/refreshes
: >"$REFRESH_SINK"
run_start "" disconnected SWIFTBAR=1 SWIFTBAR_PLUGIN_PATH=/somewhere/vpn-eta.1m.sh \
	VPN_ETA_REFRESH_SINK="$REFRESH_SINK" >/dev/null
# SwiftBar names a plugin by the part before the first dot. The full filename is
# accepted and matches nothing, so the wrong form fails silently — this assertion
# is the only thing standing between that and a fix that does nothing.
check "a finished start asks SwiftBar to read again" \
	"swiftbar://refreshplugin?name=vpn-eta" "$(tail -1 "$REFRESH_SINK")"

# A connect that failed also leaves the menu bar describing a world that is gone.
: >"$REFRESH_SINK"
run_start "" connected SWIFTBAR=1 SWIFTBAR_PLUGIN_PATH=/somewhere/vpn-eta.1m.sh \
	VPN_ETA_REFRESH_SINK="$REFRESH_SINK" FAKE_VPN_AFTER_CONNECT=nocountdown >/dev/null
check "and so does a failed one" "1" "$(grep -c . "$REFRESH_SINK" | tr -d ' ')"

# Outside SwiftBar there is nothing to refresh, so no URL is opened.
: >"$REFRESH_SINK"
run_start "" disconnected VPN_ETA_REFRESH_SINK="$REFRESH_SINK" >/dev/null
check "a terminal run opens no URL" "0" "$(grep -c . "$REFRESH_SINK" | tr -d ' ')"

printf '    [hosts]:\n\n    > gw.example.com\n' >"$FAKE_DIR/hosts"

# ---------------------------------------------------------------------------
# Warnings before a session ends, and the log of how one ended. Both write to
# STATE_DIR, which a fixture run refuses to do until VPN_ETA_TEST_PERSIST says
# the state dir is a throwaway.

NOTIFY_SINK=$VPN_ETA_NOTIFY_SINK

stats_for() {
	printf '    Connection State:            Connected\n'
	printf '    Session Disconnect:          %s\n' "$1"
	printf '    Client Address (IPv4):       %s\n' "${2:-10.1.1.1}"
}

run_live() { VPN_ETA_TEST_STATS=$1 VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null; }

# ---------------------------------------------------------------------------
# The menu bar is the scarcest space on the screen, so it formats independently
# of the dropdown: compact drops the minutes only while an hour or more is left.

bar_line() {
	# $1 remaining text, rest environment. Prints just the menu-bar line.
	remaining=$1
	shift
	env "$@" VPN_ETA_TEST_STATS="$(stats_for "$remaining")" "$PLUGIN" | head -1 | sed 's/ |.*//'
}

check "the menu bar shows hours and minutes by default" "VPN 23h 53m" \
	"$(bar_line '23 Hours 53 Minutes Remaining')"
check "compact drops the minutes above an hour" "VPN 23h" \
	"$(bar_line '23 Hours 53 Minutes Remaining' VPN_ETA_COMPACT=1)"
# Under an hour the minutes are the whole point, so compact keeps them.
check "compact keeps the minutes below an hour" "VPN 45m" \
	"$(bar_line '45 Minutes Remaining' VPN_ETA_COMPACT=1)"
check "compact rounds down, never claiming time you do not have" "VPN 1h" \
	"$(bar_line '1 Hours 59 Minutes Remaining' VPN_ETA_COMPACT=1)"
# An empty label is a real choice, not a missing value, so it must survive the
# default — and must not leave a leading space behind.
check "an empty label leaves no stray space" "23h" \
	"$(bar_line '23 Hours 53 Minutes Remaining' VPN_ETA_COMPACT=1 VPN_ETA_LABEL=)"
check "and a custom label is used verbatim" "Lab 23h 53m" \
	"$(bar_line '23 Hours 53 Minutes Remaining' VPN_ETA_LABEL=Lab)"
# An emoji is the narrowest label there is, and it is multi-byte — the plugin
# must pass it through untouched rather than counting or trimming characters.
check "an emoji label survives intact" "🦍 23h" \
	"$(bar_line '23 Hours 53 Minutes Remaining' VPN_ETA_COMPACT=1 VPN_ETA_LABEL=🦍)"

# Two gateways in one menu bar: a copy under a different filename must find its
# own config without anyone editing the copy, because there is nowhere to set a
# per-plugin environment variable under launchd.
multi_dir=$STATE_DIR/multi
mkdir -p "$multi_dir/cfg/vpn-eta" "$multi_dir/plugins"
cp "$PLUGIN" "$multi_dir/plugins/vpn-eta-lab.1m.sh"
cp "$PLUGIN" "$multi_dir/plugins/vpn-eta.1m.sh"
printf 'VPN_ETA_LABEL="Lab"\nVPN_ETA_COMPACT=1\n' >"$multi_dir/cfg/vpn-eta/vpn-eta-lab.config"
printf 'VPN_ETA_LABEL="Work"\n' >"$multi_dir/cfg/vpn-eta/config"
multi_bar() {
	env -u VPN_ETA_CONFIG XDG_CONFIG_HOME="$multi_dir/cfg" \
		VPN_ETA_TEST_STATS="$(stats_for '23 Hours 53 Minutes Remaining')" \
		"$multi_dir/plugins/$1" | head -1 | sed 's/ |.*//'
}
check "a renamed copy reads its own config" "Lab 23h" "$(multi_bar vpn-eta-lab.1m.sh)"
check "and the original still reads the shared one" "Work 23h 53m" "$(multi_bar vpn-eta.1m.sh)"
# The dropdown is not short of space and keeps the exact number.
check "the dropdown keeps the full countdown under compact" "🔐  23h 53m remaining" \
	"$(env VPN_ETA_COMPACT=1 VPN_ETA_TEST_STATS="$(stats_for '23 Hours 53 Minutes Remaining')" \
		"$PLUGIN" | sed -n '3p' | sed 's/ |.*//')"


reset_session_state() {
	rm -f "$STATE_DIR/last-session" "$STATE_DIR/last-event" \
		"$STATE_DIR/history.log" "$STATE_DIR/expected-teardown" \
		"$STATE_DIR/muted-until" "$NOTIFY_SINK"
	rm -rf "$STATE_DIR/incidents"
}

notifications() {
	[ -f "$NOTIFY_SINK" ] || { echo 0; return; }
	wc -l <"$NOTIFY_SINK" | tr -d ' '
}

last_notification() { tail -1 "$NOTIFY_SINK" 2>/dev/null | cut -f1; }
history_lines() { wc -l <"$STATE_DIR/history.log" 2>/dev/null | tr -d ' '; }
last_event() { awk -F'\t' 'END { print $2 }' "$STATE_DIR/history.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Cisco between states is not a session ending. A reconnect is the single most
# ordinary thing that happens to a laptop VPN, and the whole premise of this
# plugin is that it does not call an ambiguous reading a disconnect.

# The last spelling is the one a Wi-Fi handover actually produces, and it is
# the whole reason the word is compared rather than the field: read literally it
# matches no transition arm, and every check below fails on a gray `off`.
for transient in Connecting Reconnecting Disconnecting \
	'Reconnecting (waiting for network connectivity)'; do
	reset_session_state
	seed_cache 60
	out=$(VPN_ETA_TEST_STATS="    Connection State:            $transient" \
		VPN_ETA_TEST_PERSIST=1 "$PLUGIN")

	check "$transient does not render as off" "false" \
		"$(printf '%s\n' "$out" | head -1 | grep -q 'off' && echo true || echo false)"
	# The deadline did not move because the tunnel is renegotiating, so the
	# countdown must survive rather than be thrown away and re-learned — and it
	# must not be drawn as a confirmed one, which is the whole of what the menu
	# bar can say. The ellipsis is what separates the two.
	check "$transient keeps the cached countdown, marked" "VPN 2h 59m…" \
		"$(printf '%s\n' "$out" | head -1 | sed 's/ |.*//')"
	check "$transient does not leave the bar looking healthy" "color=orange" \
		"$(printf '%s\n' "$out" | head -1 | sed 's/.* | //')"
	check "$transient says what is happening" "${transient}…" \
		"$(printf '%s\n' "$out" | sed -n '4s/ | .*//p')"
	# The regression that matters most: a false "VPN disconnected" alert.
	check "$transient raises no drop notification" "0" "$(notifications)"
	# And the cache must still be there for the next run.
	check "$transient does not clear the session cache" "true" \
		"$([ -e "$STATE_DIR/last-session" ] && echo true || echo false)"
	check "$transient still offers to tear the session down" "true" \
		"$(printf '%s\n' "$out" | grep -q 'Disconnects the current session first' && echo true || echo false)"
done

# A renegotiation that will not end. It renders exactly like a healthy session
# minus the mark, which is how one gets noticed an hour later by hand — so past
# VPN_ETA_TRANSITION_LIMIT the bar goes red, the menu says why, and the
# notification carries it off the screen the user is not looking at.
#
# The clock is the transition's own, kept in the dedupe identity, and seeding it
# is how these cases reach minute five without waiting five minutes.
seed_transition() {
	printf 'transition|%s\n' "$(($(date +%s) - $1))" >"$STATE_DIR/last-event"
}

reconnecting() {
	# $1 the age of the cached reading in seconds, $2 the age of the transition,
	# rest environment.
	reset_session_state
	seed_cache "$1"
	seed_transition "$2"
	shift 2
	env "$@" VPN_ETA_TEST_STATS='    Connection State:            Reconnecting' \
		VPN_ETA_TEST_PERSIST=1 "$PLUGIN"
}

out=$(reconnecting 240 240)
check "a reconnect inside the limit is still routine" "VPN 2h 56m… | color=orange" \
	"$(first_line "$out")"
check "and says where its number came from" "Deadline carried from a reading 4m ago" \
	"$(printf '%s\n' "$out" | sed -n '5s/ | .*//p')"
check "and interrupts nobody" "0" "$(notifications)"

out=$(reconnecting 600 600)
check "a reconnect past the limit turns red" "VPN 2h 50m… | color=red" "$(first_line "$out")"
check "and times the transition, not the reading" \
	"Reconnecting for 10m — the tunnel may be stuck" \
	"$(printf '%s\n' "$out" | sed -n '5s/ | .*//p')"
check "and says so where it will be seen" "VPN Reconnecting" "$(last_notification)"
check "and the escalation is logged" "transition" "$(last_event)"
# Every minute of a stuck tunnel is another run of this branch; only the first
# may interrupt, or a wedged reconnect becomes a notification per minute. The
# latch is in the event file, so this second run also proves the identity kept
# it rather than the clock being re-read from a rewritten stamp.
VPN_ETA_TEST_STATS='    Connection State:            Reconnecting' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "but only once, however long it stays stuck" "1" "$(notifications)"

# The regression that made this clock the transition's own: a Mac asleep for
# nine hours wakes into an ordinary handover, and the cached reading is nine
# hours old while the reconnect is one minute old. Timing the reading alarms on
# every wake — the exact false alarm the whole branch exists to avoid.
out=$(reconnecting 32400 0)
check "a wake into a fresh reconnect is not called stuck" "VPN … | color=orange" \
	"$(first_line "$out")"
check "and wakes nobody" "0" "$(notifications)"

# ... and the same clock is the reason a transition with nothing cached still
# escalates: there is no reading to age, and a stuck Connecting is stuck either
# way. The countdown is gone here, the alarm is not.
reset_session_state
seed_transition 600
out=$(VPN_ETA_TEST_STATS='    Connection State:            Connecting' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "a stuck transition with no countdown still escalates" "VPN … | color=red" \
	"$(first_line "$out")"
check "and names the state it is stuck in" "Connecting for 10m — the tunnel may be stuck" \
	"$(printf '%s\n' "$out" | sed -n '4s/ | .*//p')"
check "and interrupts once" "VPN Connecting" "$(last_notification)"

# Mute covers this like every other alert — the menu bar is still red, so the
# fact is not hidden, only the interruption.
reset_session_state
seed_cache 600
seed_transition 600
"$PLUGIN" mute
out=$(VPN_ETA_TEST_STATS='    Connection State:            Reconnecting' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "a mute silences the stuck alert" "0" "$(notifications)"
check "and the menu bar still shows it" "VPN 2h 50m… | color=red" "$(first_line "$out")"
rm -f "$STATE_DIR/muted-until"

# A teardown the plugin started sits in Disconnecting on purpose; alarming about
# it would undo the whole point of the expected-teardown mark.
reset_session_state
seed_cache 600
seed_transition 600
date +%s >"$STATE_DIR/expected-teardown"
VPN_ETA_TEST_STATS='    Connection State:            Disconnecting' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "our own teardown does not raise a stuck alert" "0" "$(notifications)"

# Zero is off, the way it is for the mute item — and must not read as "every
# transition is stuck", which is what a bare comparison would make of it.
out=$(reconnecting 7200 7200 VPN_ETA_TRANSITION_LIMIT=0)
check "zero switches the escalation off" "VPN … | color=orange" "$(first_line "$out")"
check "and raises nothing" "0" "$(notifications)"
reset_session_state

# A real disconnect must still be called one — the fix above must not have
# swallowed the case the plugin exists to report.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
out=$(VPN_ETA_TEST_STATS="    Connection State:            Disconnected" \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "a real disconnect still renders off" "VPN off" \
	"$(printf '%s\n' "$out" | head -1 | sed 's/ |.*//')"
check "and still announces the drop" "VPN disconnected" "$(last_notification)"

# The corner the transition fix opens up: most real drops go connected ->
# Reconnecting -> gone. If only `connected` counted as "we had a session", the
# transition would swallow the announcement for the majority of actual drops.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
VPN_ETA_TEST_STATS="    Connection State:            Reconnecting" \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "a drop seen through a reconnect is still announced" "VPN disconnected" \
	"$(VPN_ETA_TEST_STATS="    Connection State:            Disconnected" \
		VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null; last_notification)"

# ... but a teardown we started ourselves still must not announce, even when it
# passes through Disconnecting on the way out.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
date +%s >"$STATE_DIR/expected-teardown"
VPN_ETA_TEST_STATS="    Connection State:            Disconnecting" \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
VPN_ETA_TEST_STATS="    Connection State:            Disconnected" \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "our own teardown stays quiet through a transition" "0" "$(notifications)"
reset_session_state

# The other half of the qualified-state trap, and the worse one: the client says
# Connected, and the plugin says off. Cisco spells the last hour of a session
# `Connected (session expiring soon)`, and drops the Session Disconnect field on
# some of those replies — so a literal comparison sends the most confident
# reading there is down the disconnect path, with the drop notification behind
# it. Measured on a real client with 23 minutes left.
reset_session_state
seed_cache 60 10.0.0.2
out=$(VPN_ETA_TEST_STATS='    Connection State:            Connected (session expiring soon)
    Client Address (IPv4):       10.0.0.2' VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "a qualified Connected is not a disconnect" "VPN 2h 59m" \
	"$(printf '%s\n' "$out" | head -1 | sed 's/ |.*//')"
check "and raises no drop notification" "0" "$(notifications)"

# What the client volunteered is the informative half, so it survives into the
# menu whole. Comparing the word is not the same as storing it: normalising at
# the source would have passed every check above and silently thrown the one
# thing the client went out of its way to say.
reset_session_state
out=$(VPN_ETA_TEST_STATS='    Connection State:            Connected (session expiring soon)
    Session Disconnect:          23 Minutes Remaining
    Client Address (IPv4):       10.0.0.2' VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "the qualifier still reaches the menu" "1" \
	"$(printf '%s\n' "$out" | grep -c 'Connection state: Connected (session expiring soon)')"
reset_session_state

# ---------------------------------------------------------------------------
# The incident capture. history.log records THAT the tunnel changed state; the
# client's own log is the only account of why, and macOS evicts that within
# hours. VPN_ETA_LOG_BIN is the only reason this path can be tested at all on a
# machine that has never run a VPN — and on CI, where the real reader would
# happily return its header and nothing else.

FAKE_LOG=$FAKE_DIR/log-reader
cat >"$FAKE_LOG" <<'FAKE'
#!/bin/sh
# Stands in for /usr/bin/log, which prints a header before any rows — and prints
# it even when it matched nothing, which is the case worth telling apart.
printf 'Timestamp               Ty Process[PID:TID]\n'
[ -n "${FAKE_LOG_HEADER_ONLY:-}" ] && exit 0
printf '2026-01-01 00:00:00 Df vpnagentd[100] gateway 192.0.2.1 is not reachable\n'
FAKE
chmod +x "$FAKE_LOG"

incidents() { find "$STATE_DIR/incidents" -name '*.log' 2>/dev/null | wc -l | tr -d ' '; }
capture() {
	# $1 is the fixture state; the rest is extra environment.
	state=$1
	shift
	env "$@" VPN_ETA_INCIDENT_LOG=1 VPN_ETA_LOG_BIN="$FAKE_LOG" \
		VPN_ETA_TEST_STATS="    Connection State:            $state" \
		VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
}

# A diagnostic that reads the system log is not something to switch on for
# somebody, so the default has to be measured rather than assumed.
reset_session_state
seed_cache 60
VPN_ETA_TEST_STATS='    Connection State:            Reconnecting' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "the capture stays off until it is asked for" "0" "$(incidents)"

reset_session_state
seed_cache 60
capture Reconnecting
check "a transition saves the client's account beside the history" "1" "$(incidents)"
check "and saves what the client actually said" "1" \
	"$(grep -rh 'is not reachable' "$STATE_DIR/incidents" 2>/dev/null | wc -l | tr -d ' ')"

# A session that came up needs no explaining, and capturing one would spend
# seconds and hundreds of kilobytes saying so.
reset_session_state
capture Connected VPN_ETA_TEST_IFCONFIG="$TUNNEL_UP"
check "a healthy connect explains itself" "0" "$(incidents)"

# The reader prints its header whether or not it matched anything, so a
# header-only file is the shape of a capture that did not work. Leaving it
# behind would read as "the client said nothing", which is a different claim.
reset_session_state
seed_cache 60
capture Reconnecting FAKE_LOG_HEADER_ONLY=1
check "a capture that caught nothing leaves nothing behind" "0" "$(incidents)"

# Bounded by count, not by age: the point is that the directory has a ceiling.
reset_session_state
mkdir -p "$STATE_DIR/incidents"
for stamp in 2026-01-01T000001 2026-01-02T000002 2026-01-03T000003; do
	printf 'older capture\n' >"$STATE_DIR/incidents/$stamp-transition.log"
done
seed_cache 60
capture Reconnecting VPN_ETA_INCIDENT_KEEP=2
check "the directory is bounded by count" "2" "$(incidents)"
check "and it is the oldest that goes" "false" \
	"$([ -e "$STATE_DIR/incidents/2026-01-01T000001-transition.log" ] && echo true || echo false)"
reset_session_state

reset_session_state
run_live "$(stats_for '5 Hours 0 Minutes Remaining')"
check "hours left is not worth interrupting for" "0" "$(notifications)"

run_live "$(stats_for '58 Minutes Remaining')"
check "the first mark warns" "1" "$(notifications)"
run_live "$(stats_for '57 Minutes Remaining')"
check "and does not warn again a minute later" "1" "$(notifications)"

run_live "$(stats_for '14 Minutes Remaining')"
check "the second mark warns" "2" "$(notifications)"
run_live "$(stats_for '13 Minutes Remaining')"
check "and also fires once" "2" "$(notifications)"
check "the warning names the session, not the tunnel" "VPN session ending" "$(last_notification)"

# A Mac asleep through both marks must not wake up to a stack of them.
reset_session_state
run_live "$(stats_for '12 Minutes Remaining')"
check "waking below every mark warns once" "1" "$(notifications)"

# Marks belong to the session they were recorded against.
reset_session_state
run_live "$(stats_for '10 Minutes Remaining' 10.1.1.1)"
run_live "$(stats_for '10 Minutes Remaining' 10.2.2.2)"
check "a different session is warned about separately" "2" "$(notifications)"

# The log exists so the next unexplained drop has a timestamp to point at.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
check "a live session is logged" "connected" "$(last_event)"
run_live '    Connection State:            Disconnected'
check "a drop nobody asked for is announced" "VPN disconnected" "$(last_notification)"
check "the drop is logged" "disconnected" "$(last_event)"
check "one line per change, not per minute" "2" "$(history_lines)"
run_live '    Connection State:            Disconnected'
check "an unchanged state adds no line" "2" "$(history_lines)"

# The start path tears the tunnel down on purpose; that is not news.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
date +%s >"$STATE_DIR/expected-teardown"
run_live '    Connection State:            Disconnected'
check "a teardown we started is not announced" "0" "$(notifications)"
check "but it is still logged" "disconnected" "$(last_event)"

printf '    [hosts]:\n\n    > gw.example.com\n' >"$FAKE_DIR/hosts"
reset_session_state
run_start y connected >/dev/null
if [ -e "$STATE_DIR/expected-teardown" ]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
	echo "FAIL: the start path did not mark its own teardown"
fi

# ---------------------------------------------------------------------------
# Ending a session from the menu. It runs with no terminal attached, so nothing
# it prints is ever read: what it did to the client, to the state and to the
# notification centre is the whole of its behaviour.

# $1 is the state the fake starts in; the rest are extra environment.
run_disconnect() {
	printf '%s\n' "$1" >"$FAKE_DIR/state"
	: >"$FAKE_DIR/log"
	shift
	env "$@" VPN_ETA_VPN_BIN="$FAKE_DIR/vpn" "$PLUGIN" disconnect
}

reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
run_disconnect connected >/dev/null
disconnect_rc=$?
check "the menu item ends the session" "1" "$(grep -c '^disconnect' "$FAKE_DIR/log" | tr -d ' ')"
check "and reports success" "0" "$disconnect_rc"
check "and does not start a new one" "0" "$(grep -c '^connect' "$FAKE_DIR/log" | tr -d ' ')"
# The deadline belonged to a session that no longer exists; left behind, the
# next unreadable reply would extrapolate from it.
check "and drops the countdown with the session" "false" \
	"$([ -e "$STATE_DIR/last-session" ] && echo true || echo false)"

# The point of the button over Cisco's own window: a teardown you asked for is
# not a drop, and must not raise the alarm the plugin exists to raise.
VPN_ETA_TEST_STATS='    Connection State:            Disconnected' \
	VPN_ETA_TEST_PERSIST=1 "$PLUGIN" >/dev/null
check "a teardown from the menu is not announced as a drop" "0" "$(notifications)"
check "but it is still logged" "disconnected" "$(last_event)"

# Nothing prints anywhere on this path, so a failure that only printed would be
# a silent one — and the session it failed to end still has its deadline.
reset_session_state
seed_cache 60 10.9.9.9
run_disconnect connected FAKE_VPN_DISCONNECT_RC=1 >/dev/null
disconnect_rc=$?
check "a refused disconnect is an error" "1" "$disconnect_rc"
check "and says so where it can be seen" "VPN disconnect failed" "$(last_notification)"
check "and keeps the countdown of the session still running" "true" \
	"$([ -e "$STATE_DIR/last-session" ] && echo true || echo false)"

# Same reason as the start path: SwiftBar's own refresh fires on the click,
# minutes before the tunnel is actually down.
reset_session_state
: >"$REFRESH_SINK"
run_disconnect connected SWIFTBAR=1 SWIFTBAR_PLUGIN_PATH=/somewhere/vpn-eta.1m.sh \
	VPN_ETA_REFRESH_SINK="$REFRESH_SINK" >/dev/null
check "a finished disconnect asks SwiftBar to read again" \
	"swiftbar://refreshplugin?name=vpn-eta" "$(tail -1 "$REFRESH_SINK")"

# ---------------------------------------------------------------------------
# Muting the alerts. A mute is a deadline rather than a switch, so when it lifts
# matters as much as what it silences.

reset_session_state
run_live "$(stats_for '5 Hours 0 Minutes Remaining')"
"$PLUGIN" mute
run_live "$(stats_for '58 Minutes Remaining')"
check "a mark crossed under a mute does not interrupt" "0" "$(notifications)"
"$PLUGIN" unmute
run_live "$(stats_for '57 Minutes Remaining')"
# The mark was recorded while muted precisely so that lifting the mute does not
# hand over the hour of warnings it was asked to suppress.
check "lifting the mute releases no backlog" "0" "$(notifications)"
run_live "$(stats_for '14 Minutes Remaining')"
check "and the next mark is heard again" "1" "$(notifications)"

reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
"$PLUGIN" mute
run_live '    Connection State:            Disconnected'
check "a drop under a mute is silent too" "0" "$(notifications)"
check "and still logged, because the log is not an interruption" "disconnected" "$(last_event)"

# The property that makes a mute safe to click: it runs out on its own.
reset_session_state
run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
printf '%s\n' "$(($(date +%s) - 1))" >"$STATE_DIR/muted-until"
run_live '    Connection State:            Disconnected'
check "an expired mute is no mute at all" "VPN disconnected" "$(last_notification)"

rm -f "$STATE_DIR/muted-until"
VPN_ETA_MUTE_MINUTES=90 "$PLUGIN" mute
mute_until=$(cat "$STATE_DIR/muted-until")
mute_span_seconds=$((mute_until - $(date +%s)))
check "the mute lasts as long as the item promised" "true" \
	"$([ "$mute_span_seconds" -gt 5390 ] && [ "$mute_span_seconds" -le 5400 ] && echo true || echo false)"

# A silence with no switch in sight is indistinguishable from notifications that
# have quietly stopped working, so the menu has to carry both states.
rm -f "$STATE_DIR/muted-until"
out=$(VPN_ETA_TEST_STATS=$CONNECTED "$PLUGIN")
check "the menu offers the mute by its span" "🔕  Mute alerts for 1h" \
	"$(printf '%s\n' "$out" | grep 'param0=mute' | sed 's/ | .*//')"
check "and a custom span is what the item promises" "🔕  Mute alerts for 1h 30m" \
	"$(env VPN_ETA_MUTE_MINUTES=90 VPN_ETA_TEST_STATS="$CONNECTED" "$PLUGIN" |
		grep 'param0=mute' | sed 's/ | .*//')"
printf '%s\n' "$(($(date +%s) + 1800))" >"$STATE_DIR/muted-until"
out=$(VPN_ETA_TEST_STATS=$CONNECTED "$PLUGIN")
check "a mute in force offers the way out of it" "🔔  Resume alerts" \
	"$(printf '%s\n' "$out" | grep 'param0=unmute' | sed 's/ | .*//')"
check "and says how much of it is left" "Muted for another 30m" \
	"$(printf '%s\n' "$out" | grep 'Muted for another' | sed 's/ | .*//')"
check "and does not also offer to mute again" "0" \
	"$(printf '%s\n' "$out" | grep -c 'param0=mute')"
# Zero is the way to take the item off the menu; "" on NOTIFY_MARKS is the way
# to switch the warnings off for good, and the two must not be confused.
rm -f "$STATE_DIR/muted-until"
check "zero minutes removes the item entirely" "0" \
	"$(env VPN_ETA_MUTE_MINUTES=0 VPN_ETA_TEST_STATS="$CONNECTED" "$PLUGIN" |
		grep -c 'param0=mute')"
reset_session_state

# The menu is the only place the log is discoverable from.
out=$(VPN_ETA_TEST_STATS=$CONNECTED VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
check "the menu links the session log" "true" \
	"$(printf '%s\n' "$out" | grep -q 'Session log:.*href=file://' && echo true || echo false)"

# The real state dir is under "Application Support", and a raw space would cut
# the href short in the middle of a menu parameter.
SPACED="$STATE_DIR/with space"
mkdir -p "$SPACED"
SWIFTBAR_PLUGIN_DATA_PATH="$SPACED" run_live "$(stats_for '3 Hours 0 Minutes Remaining')"
out=$(SWIFTBAR_PLUGIN_DATA_PATH="$SPACED" VPN_ETA_TEST_STATS=$CONNECTED VPN_ETA_TEST_PERSIST=1 "$PLUGIN")
log_line=$(printf '%s\n' "$out" | grep 'Session log:')
check "a state path with spaces is encoded" "true" \
	"$(printf '%s' "$log_line" | grep -q '%20' && echo true || echo false)"
# A raw space would end the href parameter mid-path, so what SwiftBar receives
# has to still reach the file name.
href=${log_line#*href=}
href=${href%% *}
check "the href reaches the end of the path" "history.log" "${href##*/}"

echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
