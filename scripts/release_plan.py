#!/usr/bin/env python3
"""Resolve committed release intent for the main-merge workflow."""
import argparse
import json
from pathlib import Path
import re
import subprocess

from prepare_release import validate_config, validate_source_commit

ROOT = Path(__file__).resolve().parents[1]


def metadata(config, previous):
    tag = "v" + config["version"]
    if config["channel"] == "preview":
        tag += "-preview." + str(config["build"])
    validate_config(config, tag, previous)
    return {"tag": tag, "notes": "docs/releases/" + config["version"] + ".md"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path, required=True)
    parser.add_argument("--tag")
    parser.add_argument("--notes")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    refs = subprocess.check_output(["git", "ls-remote", "origin", "refs/heads/main"], cwd=ROOT, text=True).split()
    validate_source_commit(head, refs[0] if refs else "")
    config = json.loads((ROOT / "release.json").read_text())
    previous = json.loads((ROOT / "website/release-manifest.json").read_text()).get("release")
    if args.tag:
        validate_config(config, args.tag, previous)
        if not args.notes or not re.fullmatch(r"docs/releases/[a-zA-Z0-9.-]+\.md", args.notes) or not (ROOT / args.notes).is_file():
            raise ValueError("Use a committed release notes file under docs/releases.")
        result = {"ready": "true", "tag": args.tag, "notes": args.notes}
    elif previous and config["build"] <= previous["build"]:
        result = {"ready": "false"}
        print("No new release build was requested.")
    else:
        result = metadata(config, previous)
        if not (ROOT / result["notes"]).is_file():
            raise ValueError("Commit release notes before requesting a release.")
        releases = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp",
            "repos/Pamekitti/spookky/releases?per_page=100"], text=True))
        exists = any(release["tag_name"] == result["tag"] for page in releases for release in page)
        result["ready"] = "false" if exists else "true"
        print("This release tag already exists." if exists else "Signed release candidate requested: " + result["tag"])
    with args.github_output.open("a") as output:
        for key, value in result.items():
            output.write(key + "=" + value + "\n")


if __name__ == "__main__":
    main()
