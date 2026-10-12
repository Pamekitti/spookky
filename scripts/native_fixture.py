"""Own the process, private tmux socket, and files for one native fixture."""
from contextlib import contextmanager
from dataclasses import dataclass
import os
import errno
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NATIVE_BINARY = ROOT / "DerivedData/Build/Products/Release/Spookky.app/Contents/MacOS/Spookky"
from runtime_paths import tmux_path

TMUX = tmux_path()


@dataclass
class NativeFixture:
    root: Path
    process: subprocess.Popen

    def wait_ready(self, timeout, failure_message, *, poll_interval=0.2):
        deadline = time.monotonic() + timeout
        while not (self.root / "ready.json").exists():
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(failure_message + " " + (self.root / "app.log").read_text()[-1500:])
            time.sleep(poll_interval)


@contextmanager
def native_fixture(arguments, *, prefix, binary=NATIVE_BINARY, prepare=None, workspace=False):
    if not os.access(TMUX, os.X_OK):
        raise RuntimeError("Build the pinned runtime: python3 scripts/build_runtime.py")
    root = Path(tempfile.mkdtemp(prefix=prefix, dir="/tmp"))
    environment = os.environ.copy()
    environment["SPOOKKY_M0_ROOT"] = str(root)
    if workspace:
        environment["SPOOKKY_M1_ROOT"] = str(root)
        environment["SPOOKKY_M1_DATA"] = str(root / "metadata")
    process = None
    fixture = None
    try:
        if prepare is not None:
            prepare(root)
        with (root / "app.log").open("w") as log:
            launch_arguments = list(arguments) if workspace else ["--terminal-harness", *arguments]
            process = subprocess.Popen([str(binary), *launch_arguments], env=environment, stdout=log, stderr=log)
            fixture = NativeFixture(root, process)
            yield fixture
    finally:
        if fixture is not None:
            process = fixture.process
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if (root / "socket").exists():
            subprocess.run([TMUX, "-S", str(root / "socket"), "kill-server"], check=False, capture_output=True)
        for attempt in range(20):
            try:
                shutil.rmtree(root)
                break
            except FileNotFoundError:
                break
            except OSError as error:
                if error.errno != errno.ENOTEMPTY or attempt == 19:
                    raise
                time.sleep(0.05)
