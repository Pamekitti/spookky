#!/usr/bin/env python3
"""Merge Zig archives through standalone objects to avoid Xcode archive alignment loss."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    arguments = sys.argv[1:]
    if arguments[:2] != ["-static", "-o"] or len(arguments) < 4:
        raise SystemExit("Expected libtool -static -o output input...")
    output = arguments[2]
    with tempfile.TemporaryDirectory(prefix="spookky-archive-") as directory:
        objects = []
        for source in arguments[3:]:
            data = Path(source).read_bytes()
            if data[:8] != b"!<arch>\n":
                raise SystemExit("Expected a regular archive: " + source)
            offset = 8
            while offset < len(data):
                header = data[offset:offset + 60]
                if len(header) != 60 or header[58:60] != b"`\n":
                    raise SystemExit("Invalid archive member: " + source)
                size = int(header[48:58])
                name = header[:16].decode().strip()
                member = data[offset + 60:offset + 60 + size]
                if name.startswith("#1/"):
                    length = int(name[3:])
                    name = member[:length].rstrip(b"\0").decode()
                    member = member[length:]
                if member[:4] in [b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"]:
                    target = Path(directory) / f"{len(objects):05d}.o"
                    target.write_bytes(member)
                    objects.append(str(target))
                elif not (name.startswith("__.SYMDEF") or name in ["/", "//"]):
                    raise SystemExit("Unsupported archive member: " + name)
                offset += 60 + size + size % 2
        subprocess.run(["/Library/Developer/CommandLineTools/usr/bin/libtool", "-static", "-o", output] + objects, check=True)


if __name__ == "__main__":
    main()
