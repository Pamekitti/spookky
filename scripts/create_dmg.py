#!/usr/bin/env python3
"""Create a branded drag-to-Applications disk image without Finder automation."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(arguments):
    subprocess.run([str(value) for value in arguments], check=True)


def create(app, background, output):
    from ds_store import DSStore
    from mac_alias import Alias
    if output.exists(): raise ValueError("Disk image already exists; use a fresh output path.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="spookky-dmg-", dir="/tmp") as temporary:
        root = Path(temporary); staging = root / "content"; staging.mkdir()
        run(["ditto", app, staging / "Spookky.app"])
        (staging / "Applications").symlink_to("/Applications")
        (staging / ".background").mkdir()
        background_name = "background" + background.suffix
        shutil.copy2(background, staging / ".background" / background_name)
        icon = app / "Contents/Resources/AppIcon.icns"
        if icon.exists(): shutil.copy2(icon, staging / ".VolumeIcon.icns")
        writable = root / "writable.dmg"
        run(["hdiutil", "create", "-volname", "Spookky", "-srcfolder", staging, "-fs", "HFS+", "-format", "UDRW", writable])
        mount = root / "mounted"; mount.mkdir()
        run(["hdiutil", "attach", "-nobrowse", "-mountpoint", mount, writable])
        try:
            with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
                store["."]["bwsp"] = {"ShowStatusBar": False, "ShowToolbar": False, "ShowSidebar": False,
                    "ShowPathbar": False, "ShowTabView": False, "WindowBounds": "{{100, 100}, {660, 420}}", "ContainerShowSidebar": False,
                    "PreviewPaneVisibility": False, "SidebarWidth": 0}
                store["."]["icvp"] = {"viewOptionsVersion": 1, "backgroundType": 2,
                    "backgroundImageAlias": Alias.for_file(str(mount / ".background" / background_name)).to_bytes(),
                    "iconSize": 96.0, "textSize": 13.0, "gridSpacing": 100.0, "gridOffsetX": 0.0,
                    "gridOffsetY": 0.0, "arrangeBy": "none", "labelOnBottom": True, "showItemInfo": False, "showIconPreview": False,
                    "backgroundColorRed": 0.976, "backgroundColorGreen": 0.976, "backgroundColorBlue": 0.980,
                    "scrollPositionX": 0.0, "scrollPositionY": 0.0}
                store["."]["vSrn"] = ("long", 1)
                store["."]["icvl"] = ("type", b"icnv")
                store["Spookky.app"]["Iloc"] = (180, 200)
                store["Applications"]["Iloc"] = (480, 200)
            run(["xcrun", "SetFile", "-a", "C", mount])
        finally:
            run(["hdiutil", "detach", mount])
        run(["hdiutil", "convert", writable, "-format", "UDZO", "-o", output])
    print("Created branded disk image:", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--background", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    create(args.app.resolve(), args.background.resolve(), args.output.resolve())
