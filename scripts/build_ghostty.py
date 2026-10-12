#!/usr/bin/env python3
"""Build the pinned macOS terminal library in ignored project directories."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import sys
import re

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache" / "dependencies"
MANIFEST = json.loads((ROOT / "Dependencies/manifest.json").read_text())
REVISION = MANIFEST["ghostty"]["revision"]
ZIG_SHA256 = MANIFEST["zig"]["sha256"]


def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    source = CACHE / "ghostty"
    if not source.exists():
        run(["git", "clone", "--depth", "1", "--branch", "v1.3.1", "https://github.com/ghostty-org/ghostty.git", str(source)])
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != REVISION:
        raise SystemExit("Ghostty checkout does not match the pinned revision.")
    zig = CACHE / "zig-aarch64-macos-0.15.2" / "zig"
    if not zig.exists():
        archive = CACHE / "zig-0.15.2.tar.xz"
        run(["curl", "-fL", "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz", "-o", str(archive)])
        if hashlib.sha256(archive.read_bytes()).hexdigest() != ZIG_SHA256:
            raise SystemExit("Zig archive checksum mismatch.")
        with tarfile.open(archive) as content:
            content.extractall(CACHE, filter="data")
    if subprocess.check_output([str(zig), "version"], text=True).strip() != "0.15.2":
        raise SystemExit("Zig version mismatch.")
    highway = source / "pkg/highway/build.zig"
    flag = '-ffile-prefix-map=' + str(Path.home()) + '=.'
    privacy_patch = '    try flags.append(b.allocator, ' + json.dumps(flag) + ');\n'
    contents = highway.read_text()
    if privacy_patch not in contents:
        anchor = '    lib.addCSourceFiles(.{ .flags = flags.items, .files = &.{"bridge.cpp"} });'
        if anchor not in contents: raise SystemExit("Unexpected Highway build flags; source-path mapping was not applied.")
        highway.write_text(contents.replace(anchor, privacy_patch + anchor))
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    sdk = Path(subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip())
    system_tbd = sdk / "usr/lib/libSystem.tbd"
    if "arm64-macos" not in system_tbd.read_text().split("install-name:", 1)[0]:
        candidates = [Path(env["SPOOKKY_ZIG_SDK"])] if env.get("SPOOKKY_ZIG_SDK") else (
            list(Path("/Library/Developer/CommandLineTools/SDKs").glob("MacOSX*.sdk")) +
            list(Path("/Applications").glob("Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk")))
        compatible = next((candidate for candidate in sorted(candidates, reverse=True)
                           if (candidate / "usr/lib/libSystem.tbd").is_file() and
                           "arm64-macos" in (candidate / "usr/lib/libSystem.tbd").read_text().split("install-name:", 1)[0]), None)
        if compatible is None:
            raise SystemExit("Zig 0.15.2 requires an installed SDK exporting arm64-macos. Set SPOOKKY_ZIG_SDK to a compatible installed SDK. See Dependencies/README.md.")
        tools = ROOT / ".cache/tools"
        tools.mkdir(exist_ok=True)
        shim = tools / "xcrun"
        import shlex
        shim.write_text("#!/bin/sh\nif [ \"$1\" = \"--sdk\" ] && [ \"$2\" = \"macosx\" ] && [ \"$3\" = \"--show-sdk-path\" ]; then\n  printf '%s\\n' " + shlex.quote(str(compatible)) + "\nelse\n  exec /usr/bin/xcrun \"$@\"\nfi\n")
        shim.chmod(0o700)
        archiver = tools / "libtool"
        archiver.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(ROOT / "scripts/merge_macos_archives.py")) + ' "$@"\n')
        archiver.chmod(0o700)
        step = source / "src/build/LibtoolStep.zig"
        original = 'run_step.addArgs(&.{ "libtool", "-static", "-o" });'
        previous = 'run_step.addArgs(&.{ "/Library/Developer/CommandLineTools/usr/bin/libtool", "-static", "-o" });'
        patched = 'run_step.addArgs(&.{ ' + json.dumps(str(archiver)) + ', "-static", "-o" });'
        contents = step.read_text()
        if original in contents:
            step.write_text(contents.replace(original, patched))
        elif previous in contents:
            step.write_text(contents.replace(previous, patched))
        elif patched not in contents:
            raise SystemExit("Unexpected upstream archive build step; compatibility patch was not applied.")
        env["PATH"] = str(tools) + ":" + env.get("PATH", "")
        print("Using compatible SDK for Zig:", compatible, flush=True)
    run([str(zig), "build", "-Doptimize=ReleaseFast", "-Dapp-runtime=none", "-Demit-macos-app=false",
         "-Dxcframework-target=native", "-Dsentry=false", "-Demit-docs=false", "-Demit-themes=false", "-Di18n=false", "-j4"], cwd=source, env=env)
    run([sys.executable, ROOT / "scripts/collect_notices.py"])


if __name__ == "__main__":
    main()
