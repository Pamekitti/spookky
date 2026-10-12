#!/usr/bin/env python3
"""Inspect bytes in an explicitly opened test terminal; Ctrl+Q exits."""
import argparse
import json
import os
from pathlib import Path
import select
import sys
import termios
import tty


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    path = Path(args.output)
    previous = termios.tcgetattr(sys.stdin)
    records = []
    alternate = False
    extended = False
    try:
        tty.setraw(sys.stdin)
        sys.stdout.write("\x1b[?2004hINPUT CHECK READY: Ctrl+Q exits, Ctrl+A toggles alternate screen, Ctrl+E toggles extended keys, Ctrl+R reports size.\r\n")
        sys.stdout.flush()
        while len(records) < 256:
            chunk = os.read(sys.stdin.fileno(), 4096)
            while select.select([sys.stdin], [], [], 0.1)[0]:
                chunk += os.read(sys.stdin.fileno(), 4096)
                if len(chunk) >= 65536:
                    break
            exits = [position for sequence in (b"\x11", b"\x1b[113;5u", b"\x1b[27;5;113~")
                     if (position := chunk.find(sequence)) >= 0]
            exiting = bool(exits)
            if exiting:
                chunk = chunk[:min(exits)]
            if not chunk:
                break
            if chunk in (b"\x01", b"\x1b[97;5u", b"\x1b[27;5;97~"):
                alternate = not alternate
                sys.stdout.write("\x1b[?1049h" if alternate else "\x1b[?1049l")
            if chunk in (b"\x05", b"\x1b[101;5u", b"\x1b[27;5;101~"):
                extended = not extended
                sys.stdout.write("\x1b[>4;2m" if extended else "\x1b[>4;0m")
            size = os.get_terminal_size(sys.stdin.fileno())
            record = {"hex": chunk.hex(), "text": chunk.decode("utf-8", errors="replace"),
                      "columns": size.columns, "rows": size.lines, "alternate": alternate, "extended_keys": extended}
            records.append(record)
            path.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
            sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\r\n")
            sys.stdout.flush()
            if exiting:
                break
    finally:
        sys.stdout.write("\x1b[>4;0m\x1b[?2004l\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, previous)


if __name__ == "__main__":
    main()
