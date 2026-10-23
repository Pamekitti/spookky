"""Serialize native GUI fixtures across checkouts with a kernel-owned lock."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import tempfile
import time

LOCK = Path(tempfile.gettempdir()) / ('spookky-gui-' + str(os.getuid()) + '.lock')

@contextmanager
def gui_lock(*, path=LOCK, timeout=300):
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Another native fixture holds ' + str(path))
                time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        yield
    finally:
        os.close(descriptor)
