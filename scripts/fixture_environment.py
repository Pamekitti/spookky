"""Scope Git configuration isolation to disposable test processes."""

from contextlib import contextmanager
import os
import unittest

SETTINGS = dict(
    GIT_CONFIG_NOSYSTEM="1",
    GIT_CONFIG_SYSTEM="/dev/null",
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_COUNT="0",
    GIT_TERMINAL_PROMPT="0",
)


def git_environment(inherited):
    result = dict(inherited)
    result.pop("GIT_CONFIG_PARAMETERS", None)
    result.pop("GIT_CONFIG", None)
    result.update(SETTINGS)
    return result


@contextmanager
def isolated_git():
    keys = set(SETTINGS) | {"GIT_CONFIG_PARAMETERS", "GIT_CONFIG"}
    previous = {key: os.environ.get(key) for key in keys}
    for key in keys:
        os.environ.pop(key, None)
    os.environ.update(SETTINGS)
    try:
        yield
    finally:
        for key in keys:
            if previous[key] is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous[key]


class IsolatedGitSuite(unittest.TestSuite):
    def run(self, result, debug=False):
        with isolated_git():
            return super().run(result, debug)
