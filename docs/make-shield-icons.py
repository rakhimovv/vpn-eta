#!/usr/bin/env python3
"""Render the menu-bar shield variants and embed them in the standalone plugin."""

import base64
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "swiftbar/vpn-eta.1m.sh"
START = "# BEGIN SHIELD ICONS"
END = "# END SHIELD ICONS"

SHIELD = (
    'M3 3h18v9.05c0 2.32-1.24 4.47-3.25 5.63L12 21l-5.75-3.32'
    'C4.24 16.52 3 14.37 3 12.05V3z'
)
COLORS = {
    "normal": ("#303238", "#F4F4F6"),
    "muted": ("#8A8D94", "#A6A8AF"),
    "amber": ("#B76A0E", "#F3B544"),
    "red": ("#C83548", "#FF6878"),
}
VARIANTS = {
    "NORMAL": "normal",
    "AMBER": "amber",
    "RED": "red",
    "MUTED": "muted",
}


def svg(color: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'width="24" height="24"><path d="'
        + SHIELD
        + '" fill="none" stroke="'
        + color
        + '" stroke-width="1.8" stroke-linejoin="round"/>'
        + "</svg>"
    )


def main() -> None:
    lines = [START]
    with tempfile.TemporaryDirectory(prefix="vpn-eta-icons-") as tmp:
        folder = pathlib.Path(tmp)
        for name, tone in VARIANTS.items():
            images = []
            for appearance, color in zip(("light", "dark"), COLORS[tone]):
                source = folder / f"{name}-{appearance}.svg"
                target = folder / f"{name}-{appearance}.png"
                source.write_text(svg(color))
                subprocess.run(
                    ["inkscape", str(source), "--export-filename", str(target), "--export-width", "24"],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
                images.append(base64.b64encode(target.read_bytes()).decode("ascii"))
            lines.append(f"ICON_{name}='{images[0]},{images[1]}'")
    lines.append(END)
    source = PLUGIN.read_text()
    if source.count(START) != 1 or source.count(END) != 1:
        raise SystemExit("shield icon markers missing or repeated")
    first = source.index(START)
    last = source.index(END, first) + len(END)
    PLUGIN.write_text(source[:first] + "\n".join(lines) + source[last:])


if __name__ == "__main__":
    main()
