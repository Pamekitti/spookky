# Development setup

The repository includes a Swift runtime package, native AppKit/Ghostty application, tests, and a simulated HTML prototype. [Current status](status.md) records verification boundaries and unresolved gates.

## Prerequisites

Native development requires an Apple Silicon Mac, full Xcode with its Metal toolchain, Swift 6 or newer, Python 3.12 or newer, Git, CMake, Make, and pkg-config. The pinned tmux runtime is built from source into `.cache/runtime`. Installed app users do not need these build tools. Node.js enables the prototype JavaScript syntax check. Codex and Claude Code are optional installed CLI providers.

The verified development host used macOS 26.6.2, Xcode 27, Swift 6.3.3, and tmux 3.6b. The deployment target is macOS 14; older-system compatibility remains unverified. The scripts select Xcode through `DEVELOPER_DIR` without changing the system selection.

## Build and test

After the one-time dependency setup, an ordinary native change uses these commands:

```sh
python3 scripts/check_repo.py
swift test
python3 scripts/dev.py run
```

Test the changed interaction in that checkout's development app. Run relevant checks once, then repeat only after relevant changes or failures. CI checks the Release build.

Documentation changes need the repository checker. Python script changes add `python3 -m unittest discover -s scripts -p 'test_*.py'`. Website changes use `npm test --prefix website` after website setup. Browser tests are headless and belong to website changes, not ordinary native development.

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

## Prototype layout verification

For the startup and primary/support layout reference, edit `prototype/spookky-workspace.html`, then regenerate before checking:

```sh
python3 scripts/render_prototype.py
python3 scripts/check_repo.py
python3 -m http.server 48766 --bind 127.0.0.1 --directory prototype
```

Inspect the main flow in the browser at desktop and narrow widths. Check the bottom composer and folder popover, aligned Split headers, joined Full tabs, primary selection with support tabs retained, and synthetic form retention. Do not execute terminal sample text. This simulated preview does not establish native focus, provider compatibility, process retention or performance. Repeat native acceptance against the changed development binary. Keep the installed app and existing sessions intact.

## State and ownership

Open `Spookky.xcodeproj`, select the **Spookky** scheme, and run when using the debugger. Normal launch opens the workspace interface. `--terminal-harness` opens the diagnostic terminal harness. The launcher gives each checkout a distinct macOS bundle identity; Xcode's default identity remains the shared development identifier.

Workspace metadata defaults to `~/Library/Application Support/Spookky/Development/<checkout-id>`. The normal runtime root is `/tmp/spookky-dev-<uid>-<checkout-id>`. The terminal harness uses `/tmp/spookky-m0-<uid>-<checkout-id>`. `python3 scripts/dev.py info` prints the exact locations. `SPOOKKY_M1_ROOT`, `SPOOKKY_M1_DATA`, and `SPOOKKY_M0_ROOT` override these locations for owned fixtures. The normal launcher sets its own roots rather than inheriting fixture overrides.

Older development bundles without an embedded checkout retain the historical shared development paths. Their data is preserved.

Installed releases use `dev.spookky.app`, `~/Library/Application Support/Spookky`, and `/tmp/spookky-app-<uid>`. They do not import development metadata. Debug and Release remain development configurations; Distribution creates the public identity.

Do not point benchmarks at normal development data or the user's repositories. Keep disposable Git repositories, metadata, and private tmux sockets separate. Only terminate processes created by the fixture. Never operate on another application's server or the user's default tmux server.

The CLI resolver checks inherited PATH, a bounded login-shell PATH query, local/Homebrew locations, and installed nvm Node directories. It preserves the selected executable's adjacent interpreter directory. Lookup does not install providers or alter authentication, trust, or permission controls.

## Agent activity checks

```sh
swift build --product spookky-launch
swift test --filter AgentActivityTests
python3 scripts/check_agent_hooks.py
```

The hook fixture executes both adapters through the actual launch helper with fake CLIs. It checks literal arguments, questions, child events, completion, failures, unsupported versions, disabled hooks, registration failure, and nested ownership. Malformed and oversized callbacks must exit successfully without output. The fixture uses private temporary files and a local socket. It sends no model requests.

To exercise one minimal turn with each installed provider and its existing authentication and configuration:

```sh
python3 scripts/check_agent_hooks.py --real
```

The real check sends provider requests and can run existing user hooks. It asks for a plain OK response without tools or file changes. It proves launch, prompt, and completion callbacks for the installed versions. It does not prove interactive permission or question dialogs. See [agent activity](agent-activity.md) for configuration and runtime limits.

## Session continuation checks

```sh
swift test --jobs 2 --filter ProviderContinuationTests
```

[Session continuation](session-continuation.md) describes the native instructions panel, provider ownership limits, and the exact-ID integration boundary. Exercise provider transfers only with disposable sessions. Do not use an active user conversation as a fixture.

For offline exact-ID ownership and native attach checks, run:

```sh
python3 scripts/check_provider_ownership.py --output .cache/codex-ownership.json
python3 scripts/check_claude_ownership.py --executable /path/to/claude --output .cache/claude-ownership.json
```

Use the installed native Claude executable rather than a Spookky shell wrapper. The Claude fixture uses a loopback response stub, isolated configuration, a disposable folder and its own tmux socket. It retains native onboarding and trust. It never sends a request to an external model service or stops an unrelated owner. Explicit background startup tests native attach; the app's ordinary resume policy remains unchanged.

## Public website and releases

PR CI always runs source/Python checks and the public audit. Native changes add one macOS 15 job with Swift tests, one Release build, and a bundle audit. Website changes add headless browser tests. Documentation changes skip both. Unknown paths and CI machinery changes select both areas. The source check and native check remain required; an intentionally skipped native job permits documentation PRs to merge.

After merge, main runs source checks only. It does not repeat native builds or browser tests. Dependency caches hold pinned tmux and Ghostty outputs, npm downloads, and Chromium. Keys include dependency recipes, architecture, and toolchain. Swift/Xcode build outputs and app state are not cached. Source jobs have a five-minute timeout; the native PR job has a 15-minute timeout. The actual warm native duration remains unmeasured.

PR-created caches are isolated by GitHub. To share native dependencies across PRs, run **Checks → Run workflow → main** once to warm the default-branch caches. This manual run builds dependencies only. Repeat when dependency or toolchain cache keys change; ordinary main pushes never trigger it.

The opt-in signed release workflow uses macOS 26 and prepares Distribution packaging. Extra build configurations and compatibility checks belong to release verification. Signed automatic delivery remains disabled while private local installers are in use.

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
python3 scripts/check_sidebar.py --output .cache/sidebar.json
python3 scripts/check_conversation_identity.py --output .cache/identity.json
swift scripts/check_prototype.swift --output .cache/prototype-webkit.json
python3 scripts/check_provider_continuity.py --output .cache/provider-interfaces.json
```

The prototype check uses an offscreen WebKit renderer with temporary website storage. It checks navigation, drafts, icon geometry, and narrow layouts without opening a browser window. It records focus-dependent CSS checks as skipped when the offscreen page has no active OS keyboard window.

Input replay uses native events, briefly selects already-enabled keyboard layouts, and restores the original selection. It needs at least two enabled layouts for its source-switch assertion. It does not establish human typing or IME composition. Provider-interface probes send no model prompts and do not prove provider responses. The [local project history checks](session-history.md#verification) cover metadata discovery and exact-ID continuation without a model service.

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
python3 scripts/benchmark_m1.py --conversations --mode resources --sessions 1 5 10 --output .cache/conversation-resources.json
python3 scripts/benchmark_m1.py --conversations --mode timing --output .cache/conversation-timing.json
python3 scripts/benchmark_m1.py --mode startup --output .cache/workspace-startup.json
python3 scripts/benchmark_activity.py --foreground --seconds 30 --output .cache/activity-benchmarks.json
python3 scripts/benchmark_m3.py --mode diff --output .cache/diff.json
python3 scripts/benchmark_m3.py --mode resources --panel open --output .cache/resources-open.json
python3 scripts/benchmark_m3.py --mode resources --panel closed --output .cache/resources-closed.json
python3 scripts/benchmark_m4.py --output .cache/continuity.json
python3 scripts/benchmark_m4.py --overnight --output .cache/overnight.json
```

The default M4 fixture runs ten warm-ups, 100 measured lifecycle cycles, a 30-minute workload, and a 60-second idle observation. The overnight mode is eight hours. Run measurements separately with no builds in progress. Neither mode prevents or initiates sleep. Add `--background` to keep the automated fixture behind user windows without keyboard focus or mouse input. This mode measures programmatic native attachment and excludes physical typing.

`benchmark_agents_m0.py` uses a separately prepared `/tmp/spookky-m0-agent-fixture` folder trusted through normal provider flows. It opens provider interfaces without model prompts. See [performance](performance.md) for resource boundaries and [recovery](m4-recovery.md) for hands-on sleep/reboot checks.

The activity measurement compares clean shells against simulated provider states at 1, 5, and 10 terminals. Both include the activity receiver. A separate idle fake CLI measures the packaged waiting helper. It excludes real provider memory, callback bursts, and WindowServer costs. Each case records visibility, activation, process stability, and the binary hash. Run it separately from builds and tests.

## Code layout

| Path | Purpose |
| --- | --- |
| `App/` | Native workspace, file/diff interface, and Ghostty host |
| `Sources/` | Core records, runtime, helpers, Git, files, syntax, workspaces, and persistence |
| `Tests/SpookkyRuntimeTests/` | Model, launch, Git, ownership, persistence, and recovery fixtures |
| `scripts/` | Build, prototype, test, and measurement tools |
| `Dependencies/` | Pinned vendored code, dependency provenance, and notices |

Terminal bytes stay inside the terminal stack. File scanning, Git, persistence, and bounded diagnostic writes run away from the main UI thread. See [architecture](architecture.md).

## Project association checks

See [project and checkout association](project-association.md) for metadata-only integration bounds, installed-provider fixtures, and remaining desktop verification.

## Conversation workspace foundation

```sh
swift test --jobs 2 --filter ConversationWorkspaceTests
python3 scripts/check_workspace_close.py --binary DerivedData/Build/Products/Debug/Spookky.app/Contents/MacOS/Spookky --output .cache/workspace-close.json
```

The close fixture uses disposable metadata and a private runtime socket. It checks the browser-target shortcut seam, real shell input, retained closure and reattachment. Browser rendering is outside this fixture. Acquire the shared GUI verification lock before running it when coordinating several worktrees. Development builds now bound Xcode and Swift compiler jobs to two.

## Display regression checks

Run `python3 scripts/check_sidebar.py --display --output .cache/display-checks.json` against the Release build for the light/dark zoom and hit-target matrix. Use disposable state and serialize native GUI fixtures. The matrix includes actual fullscreen transitions, Ghostty theme variants, recursive includes, invalid-config recovery and creation of a previously missing config directory. Live appearance changes must preserve the same surface, process and unsent input. It does not replace physical display-transition or provider visual-parity checks.

## Private-runtime focus regression

`python3 scripts/build_runtime.py` applies the documented tmux focus-event backport and runs its parser regression before accepting a new runtime build. To repeat the parser check against the configured local sources, run:

```sh
python3 scripts/check_tmux_focus.py --source .cache/runtime-build/tmux/tmux-3.6b
```

The probe uses disposable buffers and isolated server callbacks. It does not connect to a user socket or terminate a process. A dependency-cache hit retains the previously verified build fingerprint.
