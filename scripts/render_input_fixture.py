#!/usr/bin/env python3
"""Echo r/g input as a fixed rendered color marker beside bounded output load."""
import argparse
import os
import select
import signal
import sys
import termios
import time
import tty


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lines-per-second", type=int, default=0)
    args = parser.parse_args()
    previous = termios.tcgetattr(sys.stdin)
    line = 0
    next_output = time.monotonic()
    resized = True
    current_color = ord("r")

    def resize(*_):
        nonlocal resized
        resized = True

    def color(value):
        rgb = "255;0;0" if value == ord("r") else "0;255;0"
        sys.stdout.write("\x1b7\x1b[3;5H\x1b[48;2;" + rgb + "m" + " " * 16 + "\x1b[0m\x1b8")

    try:
        tty.setraw(sys.stdin)
        signal.signal(signal.SIGWINCH, resize)
        sys.stdout.write("\x1b[?1049h\x1b[?25l")
        sys.stdout.flush()
        while True:
            if resized:
                resized = False
                size = os.get_terminal_size(sys.stdin.fileno())
                sys.stdout.write(f"\x1b[r\x1b[2J\x1b[1;1HSPOOKKY_RENDER_READY\x1b[6;{size.lines}r\x1b[{size.lines};1H")
                color(current_color)
                sys.stdout.flush()
            if select.select([sys.stdin], [], [], 0.001)[0]:
                received = os.read(sys.stdin.fileno(), 4096)
                if not received or b"\x11" in received:
                    break
                for value in received:
                    if value in (ord("r"), ord("g")):
                        current_color = value
                        color(value)
                sys.stdout.flush()
            now = time.monotonic()
            if args.lines_per_second and now >= next_output:
                for _ in range(5):
                    sys.stdout.write(f"Spookky controlled output {line:08d}\r\n")
                    line += 1
                sys.stdout.flush()
                next_output = now + 5 / args.lines_per_second
    finally:
        sys.stdout.write("\x1b[r\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, previous)


if __name__ == "__main__":
    main()
