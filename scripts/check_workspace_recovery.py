#!/usr/bin/env python3
"""Compatibility entry point for the canonical native runner."""
from test import legacy_native
if __name__ == '__main__': legacy_native('check_workspace_recovery.py')
