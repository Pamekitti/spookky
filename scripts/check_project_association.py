#!/usr/bin/env python3
"""Compatibility adapter to the canonical native check runner."""
from test import legacy_native

if __name__ == '__main__':
    legacy_native('check_project_association.py')
