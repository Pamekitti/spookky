# Native dependencies

The native harness embeds Ghostty 1.3.1 at commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. Its required Zig compiler is 0.15.2. Downloads and outputs live in the ignored `.cache/dependencies` directory.

```sh
python3 scripts/build_runtime.py
python3 scripts/build_ghostty.py
sh scripts/build_native.sh
```

The Zig archive is checked against the SHA-256 published by its official download index: `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`.

## Local Xcode 27 compatibility

Xcode 27's macOS SDK no longer lists `arm64-macos` in the top-level libSystem stub. Zig 0.15.2 fails to link its build runner against that stub. On this host, the build uses the installed macOS 15.4 SDK for Zig, through a project-local xcrun shim. Xcode still supplies Metal and builds the Swift application with its own current SDK. No system developer-directory or SDK files are changed.

Xcode 27's archiver also drops unaligned members from Zig's archives. A build-only patch to upstream `src/build/LibtoolStep.zig` selects our archive merger. It extracts standalone Mach-O objects, then uses the Command Line Tools archiver to create an aligned combined archive. A build-only Highway compiler flag maps the builder's home path to a relative path in its assertion strings. Release packaging strips debugging symbols and rejects any remaining builder-home references. The checkout stays at the pinned revision with the documented patches applied. This patch and its purpose are part of the adopted dependency's provenance.

Set `SPOOKKY_ZIG_SDK` if a compatible SDK is installed elsewhere. The script stops if none is available. These workarounds need revisiting when upgrading Ghostty/Zig or the Apple toolchain.

## Distribution boundaries

Ghostty's MIT license is preserved in [licenses/Ghostty.txt](licenses/Ghostty.txt). The dependency contains transitive libraries and resources; transitive notices are collected in [the inventory](notice-inventory.json). Signing, notarization, and installation verification remain release gates.

The app packages tmux 3.6b, statically linked with libevent 2.1.12, ncurses 6.6, and utf8proc 2.11.3. Build it with `python3 scripts/build_runtime.py`. [The manifest](manifest.json) pins archives and checksums. The build disables unavailable SDK functions and atomically replaces its executable to avoid stale macOS code-signature caches. Agent executables are resolved from installed locations and retain provider-owned configuration and permissions. GRDB.swift 7.11.1 supplies SQLite metadata persistence through Swift Package Manager.

Spookky's native keyboard bridge adapts Ghostty's macOS input implementation at the pinned revision. See [provenance](../THIRD_PARTY.md) and the bundled MIT notice. Ghostty is also linked as the terminal dependency.

## Read-only appearance bridge

[appearance-export.zig](patches/appearance-export.zig) extends the pinned C API with passive configuration loading and a bounded appearance export. It uses Ghostty's default-path ordering, include handling, conditional theme replay and typed formatter. It does not load app command-line arguments, create a configuration template, or create a surface/process. Exported settings exclude commands, environment, keybindings and window behavior. Both theme variants retain explicit user overrides. The result owns its bytes and uses Ghostty's existing string-free API. The build includes pinned theme resources.
