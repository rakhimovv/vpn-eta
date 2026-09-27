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
# The neutral states are template images: macOS tints them from the menu bar
# the way it tints Wi-Fi, where a light/dark pair is chosen by SwiftBar's own
# guess at the appearance and can show white ink on a light bar. Only the alpha
# of a template counts, so `off` is the same shield at reduced opacity. Amber
# and red have to carry colour, which a template cannot, and keep a pair.
TEMPLATES = {
    "NORMAL": 1.0,
    "MUTED": 0.4,
}
COLORS = {
    "AMBER": ("#B76A0E", "#F3B544"),
    "RED": ("#C83548", "#FF6878"),
}


def svg(color: str, opacity: float = 1.0) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'width="24" height="24"><path d="'
        + SHIELD
        + '" fill="none" stroke="'
        + color
        + f'" stroke-opacity="{opacity}"'
        + ' stroke-width="1.8" stroke-linejoin="round"/>'
        + "</svg>"
    )


def render(folder: pathlib.Path, stem: str, image: str) -> str:
    source = folder / f"{stem}.svg"
    target = folder / f"{stem}.png"
    source.write_text(image)
    subprocess.run(
        ["inkscape", str(source), "--export-filename", str(target), "--export-width", "24"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return base64.b64encode(target.read_bytes()).decode("ascii")


def main() -> None:
    lines = [START]
    with tempfile.TemporaryDirectory(prefix="vpn-eta-icons-") as tmp:
        folder = pathlib.Path(tmp)
        for name, opacity in TEMPLATES.items():
            lines.append(f"ICON_{name}='{render(folder, name, svg('#000000', opacity))}'")
        for name, pair in COLORS.items():
            images = [
                render(folder, f"{name}-{appearance}", svg(color))
                for appearance, color in zip(("light", "dark"), pair)
            ]
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
