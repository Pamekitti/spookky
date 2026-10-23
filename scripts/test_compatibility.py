"""Compatibility entry point for the original unittest discovery command."""
from pathlib import Path
import sys

def load_tests(loader, tests, pattern):
    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root / "scripts"))
    return loader.discover(str(root / "Tests/Python"), pattern="test_*.py", top_level_dir=str(root / "Tests/Python"))
