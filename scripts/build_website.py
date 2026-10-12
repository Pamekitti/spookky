#!/usr/bin/env python3
"""Stage only public static assets for GitHub Pages."""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "website"
DESTINATION = ROOT / ".cache/site"


def main():
    if DESTINATION.exists(): shutil.rmtree(DESTINATION)
    (DESTINATION / "assets").mkdir(parents=True)
    for name in ["index.html", "privacy.html", "style.css", "site.js", "release-manifest.json", "robots.txt", "sitemap.xml"]:
        shutil.copy2(SOURCE / name, DESTINATION / name)
    for name in ["favicon.png", "mascot.png", "workspace-dark.png", "workspace-light.png", "social.png"]:
        shutil.copy2(SOURCE / "assets" / name, DESTINATION / "assets" / name)
    if (SOURCE / "appcast.xml").exists(): shutil.copy2(SOURCE / "appcast.xml", DESTINATION / "appcast.xml")
    print("Static website staged in .cache/site")


if __name__ == "__main__": main()
