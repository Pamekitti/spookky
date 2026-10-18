#!/usr/bin/env python3
"""Build checksum-pinned tmux with only Apple system libraries at runtime."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache/runtime-build"
PREFIX = ROOT / ".cache/runtime"
MANIFEST = json.loads((ROOT / "Dependencies/manifest.json").read_text())
FOCUS_PATCH = ROOT / "Dependencies/patches/tmux-focus-null-session.patch"


def run(arguments, **kwargs):
    subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def source(name):
    pin = MANIFEST[name]
    archive = CACHE / (name + ".tar.gz")
    if not archive.exists():
        run(["curl", "--fail", "--location", "--retry", "3", pin["url"], "-o", archive])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
        raise SystemExit(name + " archive checksum mismatch; remove the cached archive and retry.")
    directory = CACHE / name
    if not directory.exists():
        directory.mkdir()
        with tarfile.open(archive) as content:
            content.extractall(directory, filter="data")
    return next(path for path in directory.iterdir() if path.is_dir())


def main():
    if os.uname().sysname != "Darwin" or os.uname().machine != "arm64":
        raise SystemExit("The initial packaged runtime supports Apple Silicon macOS.")
    for tool in ["cmake", "make", "pkg-config"]:
        if not shutil.which(tool):
            raise SystemExit("Runtime builds require " + tool + ". See docs/development.md.")
    CACHE.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256(json.dumps(MANIFEST, sort_keys=True).encode() + FOCUS_PATCH.read_bytes() +
                                 (ROOT / "Dependencies/patches/tmux-focus-probe.c").read_bytes() +
                                 (ROOT / "scripts/check_tmux_focus.py").read_bytes()).hexdigest()
    stamp = PREFIX / "build.json"
    if stamp.exists() and json.loads(stamp.read_text()).get("fingerprint") == fingerprint and json.loads(stamp.read_text()).get("recipe") == 5:
        audit(PREFIX / "bin/tmux")
        print("Pinned runtime already built.")
        return
    env = os.environ.copy()
    env["MACOSX_DEPLOYMENT_TARGET"] = MANIFEST["minimumOS"]
    env["DEVELOPER_DIR"] = env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
    env["CC"] = subprocess.check_output(["xcrun", "--find", "clang"], env=env, text=True).strip()
    env["CFLAGS"] = f'-O2 -isysroot {env["SDKROOT"]} -arch arm64 -mmacosx-version-min=14.0 -fdebug-prefix-map={ROOT}=.'
    env["CPPFLAGS"] = f'-I{PREFIX}/include -I{PREFIX}/include/ncursesw'
    env["LDFLAGS"] = f'-L{PREFIX}/lib -arch arm64 -mmacosx-version-min=14.0'
    env["PKG_CONFIG_LIBDIR"] = str(PREFIX / "lib/pkgconfig")
    env["PKG_CONFIG_PATH"] = env["PKG_CONFIG_LIBDIR"]
    ncurses = source("ncurses")
    run(["./configure", "--prefix=" + str(PREFIX), "--enable-widec", "--with-termlib", "--with-normal",
         "--with-terminfo-dirs=/usr/share/terminfo", "--with-default-terminfo-dir=/usr/share/terminfo", "--without-shared", "--without-debug", "--without-cxx", "--without-cxx-binding", "--without-ada",
         "--without-tests", "--with-progs", "--enable-pc-files", "--with-pkg-config-libdir=" + str(PREFIX / "lib/pkgconfig")], cwd=ncurses, env=env)
    run(["make", "-j4"], cwd=ncurses, env=env)
    run(["make", "install.libs", "install.includes"], cwd=ncurses, env=env)
    (PREFIX / "share/terminfo").mkdir(parents=True, exist_ok=True)
    run([ncurses / "progs/tic", "-x", "-e", "tmux-256color,xterm-256color", "-o", PREFIX / "share/terminfo", ncurses / "misc/terminfo.src"], env=env)
    event = source("libevent")
    run(["cmake", "-S", event, "-B", event / "build", "-DCMAKE_INSTALL_PREFIX=" + str(PREFIX),
         "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DEVENT__LIBRARY_TYPE=STATIC",
         "-DEVENT__DISABLE_OPENSSL=ON", "-DEVENT__DISABLE_TESTS=ON", "-DEVENT__DISABLE_REGRESS=ON",
         "-DEVENT__HAVE_PIPE2=OFF", "-DEVENT__HAVE_ACCEPT4=OFF", "-DEVENT__DISABLE_SAMPLES=ON", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"], env=env)
    run(["cmake", "--build", event / "build", "-j", "4"], env=env)
    run(["cmake", "--install", event / "build"], env=env)
    utf8 = source("utf8proc")
    run(["make", "-j4", "libutf8proc.a"], cwd=utf8, env=env)
    shutil.copy2(utf8 / "libutf8proc.a", PREFIX / "lib")
    shutil.copy2(utf8 / "utf8proc.h", PREFIX / "include")
    tmux = source("tmux")
    pending = subprocess.run(["patch", "--forward", "--batch", "--dry-run", "-p1", "-i", str(FOCUS_PATCH)], cwd=tmux, capture_output=True)
    if pending.returncode == 0:
        run(["patch", "--forward", "--batch", "-p1", "-i", FOCUS_PATCH], cwd=tmux)
    else:
        applied = subprocess.run(["patch", "--reverse", "--force", "--dry-run", "-p1", "-i", str(FOCUS_PATCH)], cwd=tmux, capture_output=True)
        if applied.returncode:
            raise SystemExit("Pinned tmux focus patch does not match its source.")
    env["LIBEVENT_CFLAGS"] = env["CPPFLAGS"]
    env["LIBEVENT_LIBS"] = str(PREFIX / "lib/libevent_core.a")
    env["LIBNCURSES_CFLAGS"] = env["CPPFLAGS"]
    env["LIBNCURSES_LIBS"] = f'{PREFIX}/lib/libncursesw.a {PREFIX}/lib/libtinfow.a'
    env["LIBUTF8PROC_CFLAGS"] = env["CPPFLAGS"]
    env["LIBUTF8PROC_LIBS"] = str(PREFIX / "lib/libutf8proc.a")
    run(["./configure", "--prefix=" + str(PREFIX), "--sysconfdir=/etc", "--enable-utf8proc"], cwd=tmux, env=env)
    run(["make", "-j4"], cwd=tmux, env=env)
    run([sys.executable, ROOT / "scripts/check_tmux_focus.py", "--source", tmux], env=env)
    (PREFIX / "bin").mkdir(exist_ok=True)
    shutil.copy2(tmux / "tmux", PREFIX / "bin/tmux.pending")
    os.replace(PREFIX / "bin/tmux.pending", PREFIX / "bin/tmux")
    audit(PREFIX / "bin/tmux")
    licenses = ROOT / "Dependencies/licenses"
    for name, path in [("tmux", tmux / "COPYING"), ("libevent", event / "LICENSE"),
                       ("ncurses", ncurses / "COPYING"), ("utf8proc", utf8 / "LICENSE.md")]:
        shutil.copy2(path, licenses / (name + ".txt"))
    stamp.write_text(json.dumps({"fingerprint": fingerprint, "recipe": 5, "pins": MANIFEST}, indent=2) + "\n")
    print("Built self-contained tmux:", PREFIX / "bin/tmux")


def audit(binary):
    import tempfile
    with tempfile.TemporaryDirectory(prefix="spookky-runtime-audit-", dir="/tmp") as temporary:
        socket = str(Path(temporary) / "socket")
        try:
            run([binary, "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "spookky-audit", "/bin/cat"])
            result = subprocess.check_output([binary, "-S", socket, "list-sessions", "-F", "#{session_name}"], text=True)
            if result.strip() != "spookky-audit": raise SystemExit("Packaged runtime session probe failed.")
        finally:
            subprocess.run([str(binary), "-S", socket, "kill-server"], capture_output=True)

    libraries = subprocess.check_output(["otool", "-L", binary], text=True).splitlines()[1:]
    for line in libraries:
        name = line.strip().split(" (", 1)[0]
        if not name.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit("External runtime library: " + name)


if __name__ == "__main__":
    main()
