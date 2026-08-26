#!/bin/sh
# Regenerate docs/menu.png — the picture of the menu in the README.
#
# It is not a photograph of somebody's screen. It runs the plugin against a
# fixture, takes the output the plugin really produces, and lays those exact
# lines out as macOS would draw them. That means the picture cannot drift away
# from the menu: change a line in the plugin, run this, and the README follows.
# It also means the image can never leak a real gateway, address or username.
#
#   docs/make-menu-image.sh
set -eu
cd "$(dirname "$0")/.."

OUT=docs/menu.png
HTML=$(mktemp -t vpn-eta-menu).html
STATE=$(mktemp -d -t vpn-eta-shot)
trap 'rm -rf "$STATE" "$HTML"' EXIT

CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
if [ ! -x "$CHROME" ]; then
	echo "Chrome not found at: $CHROME" >&2
	echo "Set CHROME=/path/to/a/chromium to render." >&2
	exit 1
fi

# A session log entry so the picture shows that feature; the timestamp is fixed
# so re-running produces a byte-identical image rather than a spurious diff.
printf '2026-05-12T09:14:22+0000\tconnected\tremaining=1433m\n' >"$STATE/history.log"

MENU=$(
	VPN_ETA_CONFIG=/dev/null \
		VPN_ETA_STATE_DIR="$STATE" \
		VPN_ETA_LABEL="🦍" \
		VPN_ETA_COMPACT=1 \
		VPN_ETA_TEST_STATS='    Connection State:            Connected
    Session Disconnect:          23 Hours 53 Minutes Remaining
    Client Address (IPv4):       10.0.0.2' \
		./swiftbar/vpn-eta.1m.sh
)

# SwiftBar's format is `text | key=value ...`, with `---` between groups. The
# first line is the menu bar; everything after the first `---` is the menu.
printf '%s\n' "$MENU" | awk -v heightfile="$STATE/height" '
	function esc(s) {
		gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
		return s
	}
	function attr(params, key,   v) {
		if (match(params, key "=[^ ]+")) {
			v = substr(params, RSTART + length(key) + 1, RLENGTH - length(key) - 1)
			return v
		}
		return ""
	}
	BEGIN {
		colour["green"] = "#1c8c3c"; colour["orange"] = "#b45c00"
		colour["red"] = "#c0392b";   colour["gray"] = "#7c7c80"
		rows = 0
	}
	{
		line = $0
		params = ""
		if (index(line, "|")) {
			params = substr(line, index(line, "|") + 1)
			line = substr(line, 1, index(line, "|") - 1)
		}
		sub(/[[:space:]]+$/, "", line)

		if (NR == 1) { bar = line; barcolour = attr(params, "color"); next }
		# SwiftBar puts a separator right after the menu-bar line; a real menu
		# does not draw a rule against its own top edge.
		if (line == "---") { if (rows == 0) next; kind[rows] = "sep"; rows++; next }

		size = attr(params, "size"); if (size == "") size = 13
		c = attr(params, "color")
		kind[rows] = "row"; text[rows] = line; px[rows] = size
		fill[rows] = (c in colour) ? colour[c] : "#1d1d1f"
		rows++
	}
	END {
		# The page is sized to its content so the capture has no dead space and
		# no seam where the gradient stops.
		height = 26 + 7 + 10 + 24
		for (i = 0; i < rows; i++)
			height += (kind[i] == "sep") ? 11 : int(px[i] * 1.35 + 0.5) + 4
		printf "%d\n", height > heightfile
		close(heightfile)
		printf "<!doctype html><meta charset=\"utf-8\"><style>\n"
		printf "  :root { font-family: -apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif; }\n"
		printf "  * { box-sizing: border-box; margin: 0; }\n"
		# A soft desktop behind it, so the picture reads on a light or a dark
		# README page instead of dissolving into one of them.
		printf "  html, body { width: 560px; height: %dpx; }\n", height
		printf "  body { background: linear-gradient(150deg, #6b7f9e 0%%, #8a9bb4 45%%, #b3a898 100%%); overflow: hidden; }\n"
		printf "  .menubar { height: 26px; background: rgba(0,0,0,.55); display: flex; align-items: center; justify-content: flex-end; padding-right: 150px; }\n"
		printf "  .menubar span { color: #fff; font-size: 13px; letter-spacing: .1px; }\n"
		printf "  .menu { width: 372px; margin: 7px 0 0 150px; padding: 5px 0; border-radius: 10px;\n"
		printf "          background: rgba(247,247,249,.97); box-shadow: 0 12px 34px rgba(0,0,0,.34), 0 0 0 .5px rgba(0,0,0,.14); }\n"
		printf "  .row { padding: 2px 13px; white-space: nowrap; }\n"
		printf "  .sep { height: 1px; background: rgba(0,0,0,.13); margin: 5px 12px; }\n"
		printf "</style>\n"
		printf "<div class=\"menubar\"><span>%s</span></div>\n", esc(bar)
		printf "<div class=\"menu\">\n"
		for (i = 0; i < rows; i++) {
			if (kind[i] == "sep") { printf "  <div class=\"sep\"></div>\n"; continue }
			printf "  <div class=\"row\" style=\"font-size:%spx;color:%s\">%s</div>\n", px[i], fill[i], esc(text[i])
		}
		printf "</div>\n"
	}
' >"$HTML"

HEIGHT=$(cat "$STATE/height")
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
	--screenshot="$OUT" --window-size="560,$HEIGHT" "file://$HTML" >/dev/null 2>&1

[ -s "$OUT" ] || { echo "Chrome produced no image" >&2; exit 1; }
echo "wrote $OUT"
