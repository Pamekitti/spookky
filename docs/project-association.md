# Project and checkout association

Spookky groups sibling Git worktrees by their canonical Git common directory. Each terminal keeps its selected checkout and subdirectory as its execution directory. Display names and remote URLs do not establish repository identity.

A registered Spookky project, an actual checkout, and a Codex project have separate IDs. History can use `WorkspaceLocation.projectAssociationKey` to match discovered root and worktree locations. `ProjectAssociationResolver` refreshes filesystem identities before choosing a registered project. A selected project ID takes precedence only when its current repository matches. Duplicate matches require a choice. Missing paths remain unavailable. Repaired or moved worktrees need fresh discovery. Plain folders use their canonical folder path, with symlink aliases resolving to the same folder.

## Codex integration

For a fresh Codex launch, an authenticated root activity event supplies the provider conversation ID. A metadata-only app-server connection lists existing provider projects, checks the conversation ID and exact execution directory, and assigns the matching provider project. An exact registered project root takes precedence over a unique repository match. An existing conflicting provider assignment is preserved.

Before recording a result, the coordinator rechecks workspace, primary terminal, provider/session, invocation, launch, and local project IDs. It also rechecks ownership immediately before a provider metadata write. Closing a view preserves the receipt owner and does not reopen that view.

The adapter uses `initialize` with `experimentalApi`, `project/list`, `thread/read` without turns, and `thread/metadata/update.projectId`. It does not start or resume a thread, send a model turn, create registrations, or write provider databases or global configuration. Provider credentials, hooks, permission controls, and terminal rendering remain provider-owned.

The launched CLI executable and its environment determine the provider backend. The installed version must be 0.162.1 or later. Experimental methods are then detected through their RPC responses. Missing methods produce an unsupported result. Missing registrations, ambiguous roots, unavailable directories, and failed verification retain the correct launch directory. The result appears in the primary conversation sidebar row tooltip and accessibility label. Supporting focus does not select the association owner. The optional receipt stays on the stable primary terminal backing record. Migration carries that receipt with the terminal into its conversation workspace. The workspace exposes it only when the provider/session identity matches and ownership is unambiguous.

Association runs after launch and never gates shell access. One metadata connection runs at a time, with at most 16 queued launches. Each connection has a 15-second deadline and a 512 KiB response budget. Project listing allows at most four pages of 64 projects and 256 root discoveries. Git reads use the shared scheduler with two concurrent commands. Integration reads have a two-second command timeout and a 32 KiB output limit. No recursive file scan or persistent background provider server is added.

Empty Codex threads may not have persisted metadata yet. A failed association can retry on a later completed-turn event. Resume, fork, remote, worktree-managed CLI launches, shell-launched nested CLIs, and child activity do not trigger automatic reassignment. Disabled or unsupported activity hooks cannot supply an authenticated conversation ID, so automatic association is unavailable.

## Verification

The Swift fixtures cover root and sibling worktrees, selected subdirectories, symlinks, moved and missing paths, and duplicate registrations. They also cover unrelated repositories with the same name and remote, plain folders, wrong-checkout rejection, conflicting provider assignments, and unsupported methods.

The installed-provider fixture uses disposable HOME and CODEX_HOME directories. It creates a project and three conversations at a root, a sibling checkout, and a second worktree subdirectory. A shell builtin materializes each fixture history without a model request. A new app-server connection verifies the stored project ID and unchanged cwd.

```sh
swift test --jobs 2 --filter ProjectAssociationTests
python3 scripts/check_codex_project_association.py --output .cache/provider-project-association.json
```

To exercise the Swift RPC adapter against an installed CLI with disposable state:

```sh
SPOOKKY_CODEX_PROJECT_FIXTURE_EXECUTABLE="$(command -v codex)" swift test --jobs 2 --filter ProjectAssociationTests
```

The provider fixture passed with Codex CLI 0.162.1 and the desktop-bundled 0.163.0-alpha.10.2 on 17 October 2026. The installed desktop was ChatGPT 26.1013.40934, build 20770. Read-only inspection confirmed that its eight local projects are visible through the CLI project API. These results prove backend registration and persisted association. They do not prove the desktop sidebar refresh after an external update or the combined history/resume interface.

One disposable sample measured the metadata connection before any thread start. CLI 0.162.1 used 111.1 MiB total resident memory across three observed processes; 0.163.0-alpha.10.2 used 71.7 MiB across four. Initialization took 0.140 and 0.147 seconds respectively. These are transient provider-process snapshots. They exclude Spookky, its private terminal runtime, the running agent, and WindowServer. Summed resident memory includes shared pages. The sample does not establish peak memory or end-to-end launch latency.

The earlier tab-based implementation passed its own checks. Those results do not establish revised conversation-workspace behavior. Revised verification covers distinct primary conversations at one checkout, supporting-focus independence, hidden views, migrated receipts, and late-result rejection. Native association metadata is synthetic. Backend verification uses separate disposable provider state.

The official [app-server documentation](https://developers.openai.com/codex/app-server) describes initialization, experimental capability opt-in, and version-specific schema generation. The installed binaries' generated schema and disposable RPC results establish the project fields used here. Project APIs remain experimental.


For the primary-conversation native fixture after a development build:

```sh
python3 scripts/check_project_association.py --output .cache/project-association-ui.json
```

The fixture uses real disposable shells and synthetic project-association events. It checks the primary sidebar row, supporting focus, same-checkout entries, hidden-view updates, retained processes, and unsent primary/support input. Browser and artifact rendering use the separate supporting-content host and are not verified by this fixture.


On 17 October 2026, the revised grouping work passed 147 Swift tests, 30 Python tests, the repository checker, and a Debug development build. The installed-provider Swift fixture ran against disposable Codex state. All ten primary-conversation native assertions passed at 1120 by 760 in dark mode and 650 by 450 in light mode. Native bitmap captures can omit compositor-backed header fills, so they do not establish pixel-level rendering acceptance. Combined history, identity, browser/artifact, and handoff verification remains separate.
