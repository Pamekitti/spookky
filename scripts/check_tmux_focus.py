#!/usr/bin/env python3
"""Exercise the pinned tmux key parser with focus events during detach."""
import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Configured, built pinned tmux source directory')
    args = parser.parse_args()
    source = args.source.resolve()
    if not (source / 'tmux.o').exists():
        raise SystemExit('Build the pinned runtime before running its focus regression.')
    with tempfile.TemporaryDirectory(prefix='spookky-focus-probe-', dir='/tmp') as temporary:
        folder = Path(temporary)
        probe = ROOT / 'Dependencies/patches/tmux-focus-probe.c'
        extra = folder / 'probe.mk'
        quote = shlex.quote
        flags = '$(DEFS) $(DEFAULT_INCLUDES) $(AM_CPPFLAGS) $(CPPFLAGS) $(AM_CFLAGS) $(CFLAGS)'
        extra.write_text('spookky-focus-probe:\n'
                         '\t$(CC) ' + flags + ' -Dmain=spookky_tmux_main -c tmux.c -o ' + quote(str(folder / 'main.o')) + '\n'
                         '\t$(CC) ' + flags + ' -c ' + quote(str(probe)) + ' -o ' + quote(str(folder / 'probe.o')) + '\n'
                         '\t$(CC) $(CFLAGS) $(LDFLAGS) -o ' + quote(str(folder / 'probe')) + ' ' + quote(str(folder / 'probe.o')) + ' ' + quote(str(folder / 'main.o')) + ' $(filter-out tmux.o tty-keys.o,$(tmux_OBJECTS)) $(tmux_LDADD) $(LIBS)\n')
        subprocess.run(['make', '-f', 'Makefile', '-f', str(extra), 'spookky-focus-probe'], cwd=source, check=True, stdout=subprocess.DEVNULL)
        result = subprocess.run([str(folder / 'probe')], capture_output=True, text=True)
        print(result.stdout, end='')
        if result.returncode:
            raise SystemExit('Pinned tmux focus regression failed with exit ' + str(result.returncode) + ': ' + result.stderr)


if __name__ == '__main__':
    main()
