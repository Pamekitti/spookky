# Provenance and external dependencies

Spookky's application interface and engineering documents were authored for this project. Adopted dependencies and distributed notices are recorded below.

## Present material

| Material | Source / treatment |
| --- | --- |
| Product and engineering documents | Authored for this project; current product, flow, architecture, and interface specifications |
| Prototype fragment and pre-polish baseline | Project HTML/CSS/JavaScript; anonymized sample projects and files |
| Visual references | Desktop interface screenshots informed design; screenshots are not redistributed in this repo |
| Standalone preview template | Generated visualization export wrapper, preserved from the existing prototype export; keep its embedded notices/runtime text intact |
| Prototype icons | Lucide, loaded from the existing pinned CDN URL in the preview template; no provider logos imported |

The native app links Ghostty 1.3.1. Its exact revision, MIT notice, resources, and build-only compatibility and source-path patches are documented in [Dependencies/README.md](Dependencies/README.md).

The native keyboard bridge adapts Ghostty's macOS `SurfaceView_AppKit.swift`, `NSEvent+Extension.swift`, `Ghostty.Input.swift`, and `KeyboardLayout.swift` at that same pinned revision. It retains modifier translation, native text, composition, input-source identity, and command redispatch behavior. The upstream MIT notice is included in `Dependencies/licenses/Ghostty.txt` and the app bundle.

Native interface geometry and component states are recorded in [the native control specification](docs/native-design-reference.md). Native symbols are supplied by macOS through SF Symbols.

## Before adopting a dependency

M1 links [GRDB.swift 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1), revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`, through Swift Package Manager. The upstream code is unmodified. Its MIT notice is retained in [Dependencies/licenses/GRDB.txt](Dependencies/licenses/GRDB.txt) and copied into the app bundle. SQLite is supplied by macOS. Both package resolution files pin the same GRDB revision.

Record the dependency name, upstream URL, exact version/commit, license text location, distributed artifacts, modifications, and required notices. Do this when adopting Ghostty, tmux, GRDB, an updater, or any native asset set. Pin versions for a reproducible build.

Original Spookky code, documentation, and artwork are released under the MIT license. Third-party components retain their own licenses and notices. The app bundles the pinned runtime notice inventory. Signed distribution and supported-OS verification remain release gates.

## Code syntax colors

Spookky vendors [HighlighterSwift](Dependencies/HighlighterSwift/UPSTREAM.md) 3.1.0 at `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`. A documented range adapter bypasses HTML conversion for bounded previews. It wraps Highlight.js 11.11.1 through JavaScriptCore and returns native attributed text. The combined [MIT and BSD notices](Dependencies/licenses/HighlighterSwift.txt) are bundled with the app. Spookky's adapter preserves source text, maps the library's pinned token palette to native light/dark roles, and supplies bounded source versions for diffs.

The initially approved grammar integration was replaced at the user's request to use the simplest existing library. No Tree-sitter grammar sources or queries are part of this implementation.

## Packaged runtime and updater

The [dependency manifest](Dependencies/manifest.json) records pinned runtime archives and checksums. Tmux 3.6b is built with static libevent 2.1.12, ncurses 6.6, and utf8proc 2.11.3. Their upstream notices are bundled. Libevent feature checks disable newer unavailable SDK symbols for the supported deployment target.

Sparkle 2.10.0 is pinned through Xcode at `eef1a539a373c1f1a320624b1130fc5de7b2e100`. Its binary package checksum is `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`. Its combined notices are retained in `Dependencies/licenses/Sparkle.txt`.

[Ghostty's notice inventory](Dependencies/notice-inventory.json) identifies pinned terminal dependency sources and retained licenses, including fonts and vendored SIMD code. The unmodified z2d 0.10.0 component uses MPL 2.0. Its source-availability notice and license are included in the app. FreeType uses the FreeType License. These licenses apply to their components; original Spookky files use MIT.

The Spookky ghost artwork is original project artwork under MIT. The Contributor Covenant 2.1 policy uses its 2021 CC BY 4.0 source and retains attribution. Its license is in `docs/licenses/ContributorCovenant-CC-BY-4.0.txt`. Test tools are development dependencies and are not packaged in the app or website.

The DMG layout build uses ds_store 1.3.3 and mac_alias 2.2.3 under MIT. Their package archives are hash-pinned in `scripts/release-requirements.txt`. They write Finder metadata during packaging and are not included in the application.

## Provider marks

The OpenAI mark used for Codex and the Claude mark come from [Simple Icons 13.21.0](https://github.com/simple-icons/simple-icons/tree/3fd92a7d0656c3d780bccdf7b5a3e9b9991dd6e5), commit `3fd92a7d0656c3d780bccdf7b5a3e9b9991dd6e5`. The SVG paths are unchanged. Asset catalogs render them as monochrome templates for native appearance and contrast. The project dedicates its icons under [CC0 1.0](Dependencies/licenses/SimpleIcons.txt). Brand marks remain the property of their respective owners. They identify the CLI provider and do not imply endorsement.

Source files: [OpenAI](https://github.com/simple-icons/simple-icons/blob/3fd92a7d0656c3d780bccdf7b5a3e9b9991dd6e5/icons/openai.svg) and [Claude](https://github.com/simple-icons/simple-icons/blob/3fd92a7d0656c3d780bccdf7b5a3e9b9991dd6e5/icons/claude.svg).
