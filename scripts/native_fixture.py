"""Own the process, private tmux socket, and files for one native fixture."""

from contextlib import contextmanager
from gui_lock import gui_lock
from dataclasses import dataclass
import os
import errno
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import json
from binary_identity import code_hashes

ROOT = Path(__file__).resolve().parents[1]
NATIVE_BINARY = (
    ROOT
    / "DerivedData/Build/Products/Release/SpookkyHarness.app/Contents/MacOS/SpookkyHarness"
)
from runtime_paths import tmux_path

TMUX = tmux_path()


def save_fixture_evidence(root, output, patterns):
    root, output = Path(root), Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    destination = Path(
        tempfile.mkdtemp(prefix=output.stem + "-failure-", dir=output.parent)
    )
    for pattern in patterns:
        for source in root.rglob(pattern):
            if source.is_file() and not source.is_symlink():
                target = destination / source.relative_to(root)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    return destination


def validate_harness(binary):
    import plistlib

    binary = Path(binary).resolve()
    try:
        info = plistlib.loads((binary.parent.parent / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException):
        info = {}
    if (
        not binary.is_file()
        or not os.access(binary, os.X_OK)
        or binary.name != "SpookkyHarness"
        or info.get("CFBundleExecutable") != binary.name
        or not info.get("CFBundleIdentifier", "").startswith("dev.spookky.harness")
    ):
        raise ValueError(
            "Native fixtures require SpookkyHarness. Build the SpookkyHarness scheme and pass its executable with --binary."
        )


@dataclass
class NativeFixture:
    root: Path
    process: subprocess.Popen
    started_at: float | None = None

    def wait_ready(self, timeout, failure_message, *, poll_interval=0.2):
        self.wait_for(
            lambda: (self.root / "ready.json").exists(),
            timeout,
            failure_message,
            poll_interval=poll_interval,
        )

    def wait_for(self, predicate, timeout, failure_message, *, poll_interval=0.2):
        deadline = time.monotonic() + timeout
        while not predicate():
            if self.process.poll() is not None or time.monotonic() > deadline:
                evidence = self.preserve_evidence(
                    ROOT / ".cache/fixture-failures", ["*.json", "*.png", "*.log"]
                )
                raise RuntimeError(failure_message + " Evidence: " + str(evidence))
            time.sleep(poll_interval)

    def read_checks(self, name):
        from fixture_results import read_checks
        import json

        contracts = json.loads(
            (ROOT / "Tests/Inventory/native-assertions.json").read_text()
        )
        return read_checks(self.root / name, contracts[name])

    def preserve_evidence(self, output, patterns):
        return save_fixture_evidence(self.root, output, patterns)


@contextmanager
def _native_fixture(
    arguments, *, prefix, binary=NATIVE_BINARY, prepare=None, workspace=False
):
    if not os.access(TMUX, os.X_OK):
        raise RuntimeError("Build the pinned runtime: python3 scripts/build_runtime.py")
    validate_harness(binary)
    identity = code_hashes(binary)
    root = Path(tempfile.mkdtemp(prefix=prefix, dir="/tmp"))
    from fixture_environment import git_environment

    environment = git_environment(os.environ)
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
            launch_arguments = (
                list(arguments) if workspace else ["--terminal-harness", *arguments]
            )
            started_at = time.monotonic()
            process = subprocess.Popen(
                [str(binary), *launch_arguments],
                env=environment,
                stdout=log,
                stderr=log,
            )
            fixture = NativeFixture(root, process, started_at)
            (root / "binary-identity.json").write_text(
                json.dumps(identity, indent=2) + "\n"
            )
            yield fixture
            if code_hashes(binary) != identity:
                raise RuntimeError(
                    "Fixture executable code changed during verification"
                )
    except BaseException:
        save_fixture_evidence(
            root, ROOT / ".cache/fixture-failures", ["*.json", "*.png", "*.log"]
        )
        raise
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
            subprocess.run(
                [TMUX, "-S", str(root / "socket"), "kill-server"],
                check=False,
                capture_output=True,
            )
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


@contextmanager
def native_fixture(*args, **kwargs):
    with gui_lock():
        with _native_fixture(*args, **kwargs) as fixture:
            yield fixture
