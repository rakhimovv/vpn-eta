#!/bin/bash
# Fixture tests for install.sh and uninstall.sh. Run: ./install.test.sh
#
# These run entirely inside a temporary directory against a fake Cisco client.
# Nothing here may touch a real installation — one of these tests exists
# precisely because an earlier uninstall.sh ignored --plugin-dir and deleted a
# live session history.
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d -t vpn-eta-install-test)
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0
check() {
	if [ "$3" = "$2" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL: $1"
		echo "  expected: $2"
		echo "  actual:   $3"
	fi
}

# install.sh and uninstall.sh end by restarting SwiftBar, and their prompts treat
# "no terminal attached" as yes — so a suite that runs them nine times would
# quit and relaunch the menu bar of whoever is running it nine times. Stub the
# two commands that reach outside the sandbox. Everything under test still runs;
# only its effect on this Mac is intercepted.
mkdir -p "$SANDBOX/stub"
for stubbed in osascript open; do
	printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/stub/$stubbed"
	chmod +x "$SANDBOX/stub/$stubbed"
done
PATH=$SANDBOX/stub:$PATH
export PATH

mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/vpn" <<'FAKE'
#!/bin/sh
# Two saved profiles, and the first carries spaces the way real Cisco ones do.
case ${1-} in
hosts) printf '    [hosts]:\n\n    > Americas East - SSL\n    > lab-gw.example.net\n' ;;
esac
FAKE
chmod +x "$SANDBOX/bin/vpn"

# $1 a name for the case, the rest arguments. Always scoped to the sandbox.
installer() {
	case_dir=$SANDBOX/$1
	shift
	mkdir -p "$case_dir/plugins"
	VPN_ETA_VPN_BIN="$SANDBOX/bin/vpn" "$REPO/install.sh" \
		--plugin-dir "$case_dir/plugins" --config "$case_dir/config" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# A fresh install, and the quoting that keeps a profile name from becoming code.

installer fresh >/dev/null
check "the plugin is installed" "true" \
	"$([ -x "$SANDBOX/fresh/plugins/vpn-eta.1m.sh" ] && echo true || echo false)"
check "the config is not world-readable" "600" \
	"$(stat -f '%OLp' "$SANDBOX/fresh/config" 2>/dev/null)"
# A profile name with spaces is the common case, not the exotic one.
check "a profile name with spaces survives" "VPN_ETA_HOST='Americas East - SSL'" \
	"$(grep '^VPN_ETA_HOST=' "$SANDBOX/fresh/config")"

# The config is sourced by the plugin every minute, so a hostile value in it is
# not a formatting problem, it is execution. The single quotes below are the
# point of the test: the $(...) must reach the installer unexpanded.
# shellcheck disable=SC2016
installer hostile --label 'My "Work" $(id -un) VPN' >/dev/null
check "a hostile label is quoted, not interpolated" \
	"VPN_ETA_LABEL='My \"Work\" \$(id -un) VPN'" \
	"$(grep '^VPN_ETA_LABEL=' "$SANDBOX/hostile/config")"
# shellcheck disable=SC2016
check "and the plugin renders it literally" 'My "Work" $(id -un) VPN 2h 0m' \
	"$(VPN_ETA_CONFIG="$SANDBOX/hostile/config" \
		VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          2 Hours Remaining' \
		"$REPO/swiftbar/vpn-eta.1m.sh" | head -1 | sed 's/ |.*//')"

# ---------------------------------------------------------------------------
# Re-running must not throw away what you already set.

mkdir -p "$SANDBOX/rerun"
printf "VPN_ETA_HOST='keep.example.com'\n" >"$SANDBOX/rerun/config"
installer rerun >/dev/null
check "an existing config is left alone" "VPN_ETA_HOST='keep.example.com'" \
	"$(grep '^VPN_ETA_HOST=' "$SANDBOX/rerun/config")"

# ... but an explicit --host is an instruction, and must actually land.
installer rerun --host new.example.com >/dev/null
check "--host updates an existing config" "VPN_ETA_HOST='new.example.com'" \
	"$(grep '^VPN_ETA_HOST=' "$SANDBOX/rerun/config")"
check "and does not leave a second line behind" "1" \
	"$(grep -c '^VPN_ETA_HOST=' "$SANDBOX/rerun/config" | tr -d ' ')"
installer rerun --label Lab >/dev/null
check "--label lands on an existing config too" "VPN_ETA_LABEL='Lab'" \
	"$(grep '^VPN_ETA_LABEL=' "$SANDBOX/rerun/config")"

# ---------------------------------------------------------------------------
# Argument handling.

out=$("$REPO/install.sh" --terminal ghostty 2>&1)
check "--terminal rejects a value SwiftBar would not understand" \
	"--terminal must be one of: Terminal, iTerm, Ghostty, Kitty" "$(printf '%s\n' "$out" | head -1)"
"$REPO/install.sh" --terminal ghostty >/dev/null 2>&1
check "and exits with a usage error" "64" "$?"

out=$("$REPO/install.sh" --host 2>&1 | head -1)
check "a flag missing its value prints usage" "usage: ./install.sh [options]" "$out"

check "--print-hosts writes only hostnames to stdout" "Americas East - SSL lab-gw.example.net" \
	"$(VPN_ETA_VPN_BIN="$SANDBOX/bin/vpn" "$REPO/install.sh" --print-hosts 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# SwiftBar keeps one folder per plugin, named after the plugin file, under its
# data directory. A plugin installed there would collide with its own data.
mkdir -p "$SANDBOX/data/Library/Application Support/SwiftBar/Plugins"
HOME_SAVE=$HOME
HOME=$SANDBOX/data VPN_ETA_VPN_BIN="$SANDBOX/bin/vpn" "$REPO/install.sh" \
	--plugin-dir "$SANDBOX/data/Library/Application Support/SwiftBar/Plugins" \
	--config "$SANDBOX/data/config" >/dev/null 2>&1
check "installing into SwiftBar's data directory is refused" "1" "$?"
HOME=$HOME_SAVE

# ---------------------------------------------------------------------------
# The regression that cost real data: uninstall.sh reached past the directories
# it was given and deleted the live session history under $HOME.

canary=$SANDBOX/data/Library/Application\ Support/vpn-eta
mkdir -p "$canary"
echo "irreplaceable" >"$canary/history.log"
mkdir -p "$SANDBOX/scoped/plugins"
: >"$SANDBOX/scoped/config"
HOME=$SANDBOX/data "$REPO/uninstall.sh" --plugin-dir "$SANDBOX/scoped/plugins" \
	--config "$SANDBOX/scoped/config" --all >/dev/null 2>&1
check "a scoped uninstall does not delete state it was not pointed at" "irreplaceable" \
	"$(cat "$canary/history.log" 2>/dev/null)"

# Pointed at one explicitly, it removes exactly that one.
HOME=$SANDBOX/data "$REPO/uninstall.sh" --plugin-dir "$SANDBOX/scoped/plugins" \
	--config "$SANDBOX/scoped/config" --state-dir "$canary" --all >/dev/null 2>&1
check "and removes the state directory it is given" "false" \
	"$([ -d "$canary" ] && echo true || echo false)"

# --all means "do not ask me", which matters because these prompts default to no.
mkdir -p "$SANDBOX/allyes/plugins"
cp "$REPO/swiftbar/vpn-eta.1m.sh" "$SANDBOX/allyes/plugins/"
printf "VPN_ETA_HOST='x.example.com'\n" >"$SANDBOX/allyes/config"
"$REPO/uninstall.sh" --plugin-dir "$SANDBOX/allyes/plugins" \
	--config "$SANDBOX/allyes/config" --all </dev/null >/dev/null 2>&1
check "--all removes the config without being asked twice" "false" \
	"$([ -e "$SANDBOX/allyes/config" ] && echo true || echo false)"
check "and removes the plugin" "false" \
	"$([ -e "$SANDBOX/allyes/plugins/vpn-eta.1m.sh" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# The unscoped run — the one a user actually types. Every test above passes
# --plugin-dir, which takes a different branch, so nothing here exercised the
# default state-directory list until this case existed. That gap is what let the
# list go stale: SwiftBar names a plugin's data directory after the plugin FILE
# only while the plugin folder is SwiftBar's own, and after the plugin's full
# PATH once it is not — which is every installation this project documents.
#
# An unscoped run reads the folder out of SwiftBar's preferences and deletes the
# plugin it finds there, so it may only be let loose once the stub that redirects
# that read is proven to be in effect. A stub that silently missed would point
# this at the real menu bar.
mkdir -p "$SANDBOX/unscoped-stub"
cat >"$SANDBOX/unscoped-stub/defaults" <<STUB
#!/bin/sh
printf '%s\n' "$SANDBOX/unscoped/plugins"
STUB
chmod +x "$SANDBOX/unscoped-stub/defaults"
stubbed_dir=$(PATH=$SANDBOX/unscoped-stub:$PATH defaults read com.ameba.SwiftBar PluginDirectory)

if [ "$stubbed_dir" = "$SANDBOX/unscoped/plugins" ]; then
	mkdir -p "$SANDBOX/unscoped/plugins"
	cp "$REPO/swiftbar/vpn-eta.1m.sh" "$SANDBOX/unscoped/plugins/"
	swiftbar_data=$SANDBOX/data/Library/Application\ Support/SwiftBar/Plugins
	by_path=$swiftbar_data/${SANDBOX#/}/unscoped/plugins/vpn-eta.1m.sh
	by_name=$swiftbar_data/vpn-eta.1m.sh
	fallback=$SANDBOX/data/Library/Application\ Support/vpn-eta
	for d in "$by_path" "$by_name" "$fallback"; do
		mkdir -p "$d"
		echo "history" >"$d/history.log"
	done

	env -u XDG_CONFIG_HOME -u VPN_ETA_CONFIG -u VPN_ETA_STATE_DIR \
		HOME="$SANDBOX/data" PATH="$SANDBOX/unscoped-stub:$PATH" \
		"$REPO/uninstall.sh" --all </dev/null >/dev/null 2>&1
	check "an unscoped uninstall clears the data directory SwiftBar really used" "false" \
		"$([ -d "$by_path" ] && echo true || echo false)"
	check "and the by-name one, for a plugin folder that was SwiftBar's own" "false" \
		"$([ -d "$by_name" ] && echo true || echo false)"
	check "and the fallback a terminal run writes to" "false" \
		"$([ -d "$fallback" ] && echo true || echo false)"
	check "and it removed the plugin it was pointed at" "false" \
		"$([ -e "$SANDBOX/unscoped/plugins/vpn-eta.1m.sh" ] && echo true || echo false)"
else
	echo "skip: the defaults stub did not take effect; unscoped uninstall not exercised"
fi

# Without --all and with no terminal to answer, deletion must not happen.
mkdir -p "$SANDBOX/timid/plugins"
printf "VPN_ETA_HOST='x.example.com'\n" >"$SANDBOX/timid/config"
"$REPO/uninstall.sh" --plugin-dir "$SANDBOX/timid/plugins" \
	--config "$SANDBOX/timid/config" </dev/null >/dev/null 2>&1
check "a piped uninstall keeps the config it could not ask about" "true" \
	"$([ -e "$SANDBOX/timid/config" ] && echo true || echo false)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
