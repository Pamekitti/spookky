"""Identify executable code, including Xcode's separate Debug application dylib."""

import hashlib
from pathlib import Path
import os


def code_hashes(binary):
    binary = Path(binary).resolve()
    if not binary.is_file():
        raise ValueError("Missing application executable: " + str(binary))
    files = [
        path
        for path in binary.parent.iterdir()
        if path.is_file() and (os.access(path, os.X_OK) or path.suffix == ".dylib")
    ]
    return {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(files)
    }
