# Development setup

The repository includes a Swift runtime package, native AppKit/Ghostty application, tests, and a simulated HTML prototype. [Current status](status.md) records verification boundaries and unresolved gates.

## Prerequisites

Native development requires an Apple Silicon Mac, full Xcode with its Metal toolchain, Swift 6 or newer, Python 3.12 or newer, Git, CMake, Make, and pkg-config. The pinned tmux runtime is built from source into `.cache/runtime`. Installed app users do not need these build tools. Node.js enables the prototype JavaScript syntax check. Codex and Claude Code are optional installed CLI providers.

The verified development host used macOS 26.6.2, Xcode 27, Swift 6.3.3, and tmux 3.6b. The deployment target is macOS 14; older-system compatibility remains unverified. The scripts select Xcode through `DEVELOPER_DIR` without changing the system selection.

## Build and test

Use the check planner for an ordinary change:

```sh
python3 scripts/check.py --plan
python3 scripts/check.py
```

The planner compares against `origin/main` and includes staged, unstaged, and untracked source. Documentation and agent instructions use repository and Python checks. Native changes add Swift tests and a Release build. Build/packaging changes also add Debug. Website changes add browser tests. CI machinery changes exercise both areas on GitHub without rebuilding the unchanged local app. Unknown paths or an unavailable base select full coverage.

One bounded receipt under ignored `.cache/checks/` reuses passed automated checks for matching source, selected commands, tools, and environment. Failed or interrupted checks are not reused. Public audits and GUI evidence remain separate. Use `--force` after an external change invalidates runtime evidence, or `--full` to select all local checks. This avoids repeated builds after commits and unchanged rebases.

The complete commands remain available for setup and explicit verification:

```sh
python3 scripts/build_runtime.py
swift build --product spookky-launch
swift build --product spookky-runtime-check
swift test
.build/debug/spookky-runtime-check
.build/debug/spookky-runtime-check --cycles
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/check_repo.py
python3 scripts/build_ghostty.py
sh scripts/build_native.sh
sh scripts/build_native.sh Release
```

Build the runtime and Swift helpers before running runtime tests. `SPOOKKY_TMUX` selects an explicit runtime for development fixtures. Build native Debug and Release sequentially. [Dependency setup](../Dependencies/README.md) records the pinned Ghostty build and Xcode compatibility workarounds. Ghostty downloads and build outputs remain under ignored `.cache/` directories.

Use the [daily development lifecycle](lifecycle.md) to keep the installed app and concurrent worktree builds separate. Build and open this checkout's development app:

```sh
python3 scripts/dev.py run
python3 scripts/dev.py run --configuration Release
```

## State and ownership

Open `Spookky.xcodeproj`, select the **Spookky** scheme, and run when using the debugger. Normal launch opens the workspace interface. `--terminal-harness` opens the diagnostic terminal harness. The launcher gives each checkout a distinct macOS bundle identity; Xcode's default identity remains the shared development identifier.

Workspace metadata defaults to `~/Library/Application Support/Spookky/Development/<checkout-id>`. The normal runtime root is `/tmp/spookky-dev-<uid>-<checkout-id>`. The terminal harness uses `/tmp/spookky-m0-<uid>-<checkout-id>`. `python3 scripts/dev.py info` prints the exact locations. `SPOOKKY_M1_ROOT`, `SPOOKKY_M1_DATA`, and `SPOOKKY_M0_ROOT` override these locations for owned fixtures. The normal launcher sets its own roots rather than inheriting fixture overrides.

Older development bundles without an embedded checkout retain the historical shared development paths. Their data is preserved.

Installed releases use `dev.spookky.app`, `~/Library/Application Support/Spookky`, and `/tmp/spookky-app-<uid>`. They do not import development metadata. Debug and Release remain development configurations; Distribution creates the public identity.

Do not point benchmarks at normal development data or the user's repositories. Keep disposable Git repositories, metadata, and private tmux sockets separate. Only terminate processes created by the fixture. Never operate on another application's server or the user's default tmux server.

The CLI resolver checks inherited PATH, a bounded login-shell PATH query, local/Homebrew locations, and installed nvm Node directories. It preserves the selected executable's adjacent interpreter directory. Lookup does not install providers or alter authentication, trust, or permission controls.

## Public website and releases

CI always runs source/Python checks and the public audit. It selects website tests and macOS jobs from changed paths. Required check names remain stable when native jobs are intentionally skipped for documentation. Native and unknown changes keep both macOS checks. Changed CI selection logic runs the native and website jobs.

Caches contain pinned runtime/terminal dependencies, Swift/Xcode build outputs, npm downloads, and Chromium. Keys include dependency recipes, architecture, OS/toolchain, and relevant source. Cache hits do not skip native tests or bundle audits. App state, session data, credentials, and signing material are excluded. Runner queue time and cold builds remain outside the warm-cache speed claim.

```sh
cd website
npm ci
npx playwright install chromium
npm test
cd ..
python3 scripts/serve_website.py
```

The website preview uses `/spookky/`, matching GitHub Pages. Only sanitized native screenshots belong in public assets. `python3 scripts/build_website.py` stages static files and excludes test dependencies and artwork sources. See [releasing](releasing.md) for signing credentials, draft preparation, and publication gates.

## Prototype

```sh
python3 scripts/render_prototype.py
python3 scripts/check_repo.py
python3 -m http.server 48766 --bind 127.0.0.1 --directory prototype
```

Open [localhost:48766](http://127.0.0.1:48766/). Use another free port if occupied. Stop only the server you started. The checker validates documentation links, prototype synchronization, and JavaScript syntax when Node.js is present. It does not prove native behavior.

## Native input and recovery checks

Build Release before these isolated checks:

```sh
python3 scripts/native_check.py self-test --output .cache/history.json
python3 scripts/check_m0_recovery.py --output .cache/recovery.json
python3 scripts/check_m0_input.py input --mode direct --replay --output .cache/input-direct.json
python3 scripts/check_m0_input.py input --mode persistent --replay --output .cache/input-persistent.json
python3 scripts/check_m0_input.py folders --output .cache/folders.json
python3 scripts/check_surface_races.py --output .cache/surface-races.json
python3 scripts/check_terminal_selection.py --output .cache/terminal-selection.json
python3 scripts/check_workspace_close.py --output .cache/workspace-close.json
python3 scripts/check_provider_continuity.py --output .cache/provider-interfaces.json
```

Input replay uses native events, briefly selects already-enabled keyboard layouts, and restores the original selection. It needs at least two enabled layouts for its source-switch assertion. It does not establish human typing or IME composition. Provider-interface probes send no model prompts and do not prove provider responses.

For hands-on input collection, omit `--replay`. The collector prints its private root and launches a disposable byte receiver. Create the printed root's `finish` file, or quit the owned fixture, to collect its report. Use test text only. With `--interactive-checks`, the harness provides clipboard fixtures and a Restore original clipboard action. Restore before finishing; a crash cannot guarantee clipboard restoration.

The standalone byte fixture can also run inside a dedicated test terminal:

```sh
python3 scripts/terminal_input_fixture.py --output /tmp/spookky-input-check.json
```

## Measurement commands

```sh
python3 scripts/benchmark_m0.py --mode timing --output .cache/terminal-timing.json
python3 scripts/benchmark_render_m0.py --output .cache/rendered-input.json
python3 scripts/benchmark_m1.py --mode timing --resize --output .cache/workspace-timing.json
python3 scripts/benchmark_m3.py --mode diff --output .cache/diff.json
python3 scripts/benchmark_m3.py --mode resources --panel open --output .cache/resources-open.json
python3 scripts/benchmark_m3.py --mode resources --panel closed --output .cache/resources-closed.json
python3 scripts/benchmark_m4.py --output .cache/continuity.json
python3 scripts/benchmark_m4.py --overnight --output .cache/overnight.json
```

The default M4 fixture runs ten warm-ups, 100 measured lifecycle cycles, a 30-minute workload, and a 60-second idle observation. The overnight mode is eight hours. Run measurements separately with no builds in progress. Neither mode prevents or initiates sleep. Add `--background` to keep the automated fixture behind user windows without keyboard focus or mouse input. This mode measures programmatic native attachment and excludes physical typing.

`benchmark_agents_m0.py` uses a separately prepared `/tmp/spookky-m0-agent-fixture` folder trusted through normal provider flows. It opens provider interfaces without model prompts. See [performance](performance.md) for resource boundaries and [recovery](m4-recovery.md) for hands-on sleep/reboot checks.

## Code layout

| Path | Purpose |
| --- | --- |
| `App/` | Native workspace, file/diff interface, and Ghostty host |
| `Sources/` | Core records, runtime, helpers, Git, files, syntax, workspaces, and persistence |
| `Tests/SpookkyRuntimeTests/` | Model, launch, Git, ownership, persistence, and recovery fixtures |
| `scripts/` | Build, prototype, test, and measurement tools |
| `Dependencies/` | Pinned vendored code, dependency provenance, and notices |

Terminal bytes stay inside the terminal stack. File scanning, Git, persistence, and bounded diagnostic writes run away from the main UI thread. See [architecture](architecture.md).
