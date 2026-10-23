"""Validate behavior assertions independently from build identity and measurements."""
import json
from pathlib import Path


def validate_checks(checks, required):
    required = frozenset(required)
    if not required or not isinstance(checks, dict) or not checks:
        raise ValueError('A suite must declare and report behavioral assertions')
    missing = required - checks.keys()
    if missing:
        raise ValueError('Missing required assertions: ' + ', '.join(sorted(missing)))
    if any(type(value) is not bool for value in checks.values()):
        raise ValueError('Assertion results must be JSON booleans')
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise ValueError('Failed assertions: ' + ', '.join(failed))
    return checks


def read_checks(path, required):
    return validate_checks(json.loads(Path(path).read_text()), required)


def report(suite, checks, required, *, binary_sha256=None, evidence=None, resources=None):
    validate_checks(checks, required)
    return dict(suite=suite, passed=True, checks=checks, binary_sha256=binary_sha256,
                evidence=evidence or [], resources=resources or {},
                counts=dict(passed=len(checks), failed=0, skipped=0, excluded=0))
