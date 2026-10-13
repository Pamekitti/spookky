#!/usr/bin/env python3
"""Select PR checks from changed paths, with full coverage for unknown inputs."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_TOOLS = {"scripts/check_repo.py", "scripts/check_public.py",
                "scripts/render_prototype.py"}
WEB_TOOLS = {"scripts/build_website.py", "scripts/serve_website.py"}


def classify(paths, *, unknown_base=False):
    result = {"native": unknown_base, "website": unknown_base}
    for path in paths:
        if path.startswith(("App/", "Sources/", "Tests/", "Dependencies/", "Spookky.xcodeproj/")) or path in {"Package.swift", "Package.resolved"}:
            result["native"] = True
        elif path.startswith("website/") or path in WEB_TOOLS or path == ".github/workflows/pages.yml":
            result["website"] = True
        elif path.startswith("docs/") or ("/" not in path and path.endswith(".md")) or path.startswith("prototype/"):
            continue
        elif path.startswith((".agents/skills/", ".claude/skills/")) and (path.endswith((".md", ".yaml", ".yml")) or len(Path(path).parts) == 3):
            continue
        elif path in SOURCE_TOOLS or (path.startswith("scripts/test_") and path.endswith(".py")):
            continue
        elif path.startswith("scripts/build_") or path in {"scripts/dev.py", "scripts/verify_bundle.py", "scripts/runtime_paths.py", "scripts/create_xcode_project.py", "scripts/collect_notices.py", "scripts/merge_macos_archives.py"}:
            result["native"] = True
        elif path.startswith(".github/") or path == "scripts/check_scope.py":
            # Changed CI machinery must exercise its native and website jobs.
            result["native"] = result["website"] = True
        else:
            result = dict.fromkeys(result, True)
    return result


def changed_paths(base, *, root=ROOT):
    def git(*arguments):
        return subprocess.check_output(["/usr/bin/git", "-c", "trace2.eventTarget=0", *arguments], cwd=root)
    unknown = not base or base.startswith("-") or set(base) == {"0"}
    paths = set()
    if not unknown:
        try:
            paths.update(git("diff", "--no-renames", "--name-only", "-z", base + "...HEAD").decode().split("\0"))
        except subprocess.CalledProcessError:
            unknown = True
    return sorted(paths - {""}), unknown


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--event", type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    base = args.base
    if args.event:
        event = json.loads(args.event.read_text())
        base = event.get("pull_request", {}).get("base", {}).get("sha") or event.get("before")
    paths, unknown = changed_paths(base)
    scope = classify(paths, unknown_base=unknown)
    print(json.dumps({"files": paths, "unknownBase": unknown, **scope}, indent=2))
    if args.github_output:
        with args.github_output.open("a") as output:
            for key, value in scope.items():
                output.write(key + "=" + str(value).lower() + "\n")


if __name__ == "__main__":
    main()
