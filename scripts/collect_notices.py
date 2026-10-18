#!/usr/bin/env python3
"""Collect notices from Ghostty's pinned macOS dependency sources."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / ".cache/dependencies/ghostty"
DESTINATION = ROOT / "Dependencies/licenses"
MAC_PACKAGES = {"freetype", "harfbuzz", "libpng", "zlib", "oniguruma", "glslang", "spirv-cross", "simdutf", "highway", "utfcpp", "wuffs", "dcimgui"}
ROOT_PACKAGES = {"libxev", "vaxis", "z2d", "zig_objc", "uucode", "zf", "jetbrains_mono", "nerd_fonts_symbols_only", "iterm2_themes"}


def main():
    zig = ROOT / ".cache/dependencies/zig-aarch64-macos-0.15.2/zig"
    output = subprocess.check_output([str(zig), "env"], text=True)
    cache = Path(re.search(r'\.global_cache_dir = "([^"]+)"', output)[1]) / "p"
    index = []
    zones = [SOURCE / "build.zig.zon"] + sorted((SOURCE / "pkg").glob("*/build.zig.zon"))
    for zone in zones:
        if zone.parent != SOURCE and zone.parent.name not in MAC_PACKAGES: continue
        text = zone.read_text()
        for match in re.finditer(r'\.url = "([^"]+)".*?\.hash = "([^"]+)"', text, re.S):
            url, digest = match.groups()
            keys = list(re.finditer(r'\.(\w+) = \.\{', text[:match.start()]))
            key = keys[-1][1]
            if zone.parent == SOURCE and key not in ROOT_PACKAGES: continue
            component = key if zone.parent == SOURCE else zone.parent.name + "-" + key
            package = cache / digest
            if not package.exists(): continue  # Lazy dependencies absent from this native build.
            names = []
            for path in sorted(package.rglob("*")):
                relative = path.relative_to(package)
                if not path.is_file() or len(relative.parts) > 2: continue
                if not re.fullmatch(r'(?:licen[sc]e|copying|copyright|notice|ofl|ftl|unicode-license)[^/]*', path.name, re.I): continue
                if path.suffix == ".cfg": continue
                name = "Ghostty-" + component + "-" + "-".join(relative.parts) + ".txt"
                (DESTINATION / name).write_bytes(path.read_bytes())
                names.append(name)
            if component == "iterm2_themes": names.append("iTerm2-Color-Schemes.txt")
            if component == "z2d": names += ["z2d.txt", "z2d-COPYING.txt"]
            if component == "dcimgui-bindings": names.append("DearBindings.txt")
            if not names: raise SystemExit("Missing dependency notice: " + component)
            index.append({"component": component, "sourceURL": url, "zigHash": digest, "notices": names})
    (DESTINATION / "Zig.txt").write_bytes((zig.parent / "LICENSE").read_bytes())
    index.append({"component": "zig-runtime", "sourceURL": "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz", "notices": ["Zig.txt"]})
    index.append({"component": "simdutf", "sourceURL": "https://github.com/simdutf/simdutf/tree/v5.2.8", "notices": ["simdutf-MIT.txt", "simdutf-APACHE.txt"]})
    font_notice = "Ghostty-FontResources-OFL.txt"
    (DESTINATION / font_notice).write_bytes((SOURCE / "src/font/res/OFL.txt").read_bytes())
    index.append({"component": "font-resources", "sourceURL": "https://github.com/ghostty-org/ghostty/tree/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28/src/font/res", "notices": [font_notice]})
    (ROOT / "Dependencies/notice-inventory.json").write_text(json.dumps(index, indent=2) + "\n")
    (DESTINATION / "SourceAvailability.txt").write_text("Spookky dependency sources\n\nThe unmodified z2d 0.10.0 component is available under MPL 2.0 at:\nhttps://github.com/vancluever/z2d/archive/refs/tags/v0.10.0.tar.gz\n\nGhostty source and its exact dependency URLs/hashes are recorded in:\nhttps://github.com/Pamekitti/spookky/blob/main/Dependencies/notice-inventory.json\n\nFreeType is distributed under the FreeType License. This software uses the FreeType Project (https://freetype.org).\n")
    print("Collected notices for", len(index), "terminal dependency sources.")


if __name__ == "__main__": main()
