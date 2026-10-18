# Development status

Spookky is an early native macOS development preview. The terminal, workspace, project/worktree, file/diff, and metadata layers are implemented. Daily-use and distribution acceptance remain incomplete.

## Session workflow revision, 18 October 2026

Metadata version 7 separates requested provider history from open workspaces. The sidebar uses five recent entries per project, ten-entry expansion, paged search and one-line virtualized rows. Global and project landing drafts retain their own provider, folder and prompt. Closing the final session view returns to the composer. Shared bounded tabs join in Full view and align to the divider in Split view. Changes and individual file tabs have separate responsibilities.

Continuation now detects installed capabilities rather than exact or minimum CLI versions. Known owned terminals reattach. Codex uses native exact-ID resume. Claude blocks a reported interactive owner, attaches a supported live background owner, and permits ordinary resume when reporting is absent. This fallback does not establish exclusive cross-app ownership. Errors belong to the selected conversation.

The full Swift run passed 281 cases, with three opt-in cases skipped: 261 of 264 XCTest cases passed, and all 20 Swift Testing cases passed. All 30 Python tests passed. The repository checker passed 20 required files, 157 local links, JavaScript syntax and prototype synchronization. Targeted persistence checks also cover global/project drafts across database restart, migration, alias updates, project removal and preservation of provider metadata.

The native workflow batch passed 193 assertions: 36 sidebar, 34 lazy history, 86 identity/layout/startup, 27 close/reopen and 10 project-grouping checks. They cover five-entry project pages, repeated ten-entry expansion, older search results, zero agent launches during discovery, bounded native rows, stationary-pointer scroll reconciliation, row action visibility after activation, keyboard access, cancellation before launch, retained drafts/processes and Split/Full tab geometry in both appearances.

Collapse resets only that project to five recent entries and cancels pending expansion results. Plain table geometry keeps project icons at 16 points with one further 16-point indent for conversations. Both sidebar containers reject horizontal scrolling and bounce. Native red/green pixel checks and six isolated installed-Claude checks verified color-capable terminal launches, exact saved resume and no extra model turn. Existing CLI processes keep their inherited environment until a later native launch or resume.

Browser/artifact verification passed another 36 checks and three cold-restore checks. The file/diff fixture passed 24 checks and 100 selection cycles. Across 30 observations, selected-diff readiness measured 115.9 ms p95 and syntax readiness measured 207.9 ms p95. The fixture retained its preview, metadata, surface and watcher bounds. These measurements exclude physical display latency. See [performance](performance.md) for workload and resource boundaries.

The before/after comparison measured empty readiness p95 at 514.4 ms versus 365.1 ms. Warm selection p95 was 18.9 ms versus 20.7 ms; recreated selection was 51.9 ms versus 51.2 ms. Both crash/restore checks preserved processes and viewport. Memory results were mixed, with lower RSS and higher physical footprint in short occluded observations. See [performance](performance.md) for surface counts and measurement limits.

Installed offline fixtures passed nine Codex CLI 0.163.0 checks and seven Claude Code 2.1.302 checks. Codex's first same-server resume succeeded after persisted/indexed readiness, with zero resume retries. Claude resumed provider-created saved history in a foreground TUI and attached its exact background registry ID. Resume and attach sent no extra model turn. The fixture response used an owned loopback stub, with no external model service or user-session changes.

These results cover automated native development fixtures. Installed delivery requires its own app-identity and preserved-data readback. Native pointer and keyboard events do not establish physical typing or IME behavior. Desktop return, remote pairing, spoken VoiceOver and extended sleep/reboot continuity remain unverified. OpenCode remains deferred. Earlier results below describe preceding revisions.

## Layout and startup refinement, 18 October 2026

The accepted interface now uses one 40-point row for the primary header and supporting tabs. Full view joins the primary first and every supporting tab. Selecting the primary keeps supporting tabs visible. Split restores the primary left and last support right with the retained divider width and live state.

New session opens a bottom composer with an optional prompt, provider/folder chips, Local by default and worktree controls inside the location popover. First use selects Codex. Shell launches retain the agent draft and do not replace the last agent preference. The running provider TUI replaces the composer.

The initial Release candidate passed 191 native checks: 77 identity/layout/startup, 24 closure, 17 history, 10 project grouping, 36 browser/artifact, three cold-preview restore and 24 large-diff checks. They cover both appearances, wide/narrow windows, selected-tab visibility, overflow focus, actual Open Terminal control activation, retained terminal geometry/input and process identity. The full Swift run passed 239 cases with three opt-in checks skipped. The affected state/switch cleanup passed another 18 targeted cases. All 30 Python tests and the repository checker passed.

An earlier layout candidate measured warm switching at p95 17.4 ms, recreated-terminal selection at 51.0 ms and empty readiness at 366.2 ms. See [performance](performance.md) for measurement boundaries. App crash/restore retained process identities and the visible history marker.

The prototype main flow was checked in the in-app browser at desktop and a requested 390-pixel viewport. Native captures covered 1120 and 680 points. Desktop automation verified the privately installed app, including newline entry, ASCII shell input, the native folder picker and retained drafts across Full/Split changes. The update preserved existing project, workspace, tab, draft and binding records through metadata version 5 to 6. The previous app and database were backed up before replacement.

Installed testing exposed a folder-discovery deadline that hid available conversation history. Refresh now retains every history row and reports partial folder association. Resume still checks the folder and current ownership. The warning has separate space below workspace content. Header geometry now follows current window bounds before descendant layout. These fixes passed all 240 Swift cases, with three opt-in checks skipped, and 105 affected native checks: 78 identity/layout/startup, 17 history and 10 project grouping.

Physical keyboard/IME, spoken VoiceOver and extended sleep/reboot continuity remain unverified. The private local installer does not establish signed public delivery.

## Conversation workspace integration, 17 October 2026

The local integration adds direct provider history, primary conversation titles and icons, checkout association, continuation guidance, and native browser/artifact tabs. Metadata version 6 splits older multi-agent workspaces while retaining terminal identities, bindings and drafts. Provider-native conversation switches now retain the previous entry and move the live terminal to the new conversation. See [conversation workspaces](conversation-workspaces.md).

The combined Release app passed 133 native fixture assertions: 24 for close/reopen, 43 for identity, conversation switching and independent file tabs, 10 for project association, 17 for the 600-conversation sidebar, and 39 for browser/artifact behavior and lazy restoration. The history fixture kept 51 native workspace rows for 600 saved entries. The final Swift run passed 206 XCTest cases and 17 Swift Testing cases, with three opt-in checks skipped. Thirty Python tests passed.

The large-diff fixture passed another 24 checks and 100 selection cycles through the supporting panel. Preview selection measured 113.5 ms p95 across 30 samples. Syntax readiness measured 179.2 ms p95. The checks covered file/comparison switching, visible geometry, selection and focus retention, external edits, bounded buffers and stopping the hidden watcher. File-tab context now persists independently, and native switching between two files loaded each file's actual content.

Native accessibility interaction confirmed browser form retention when switching to an interactive HTML artifact. Cancel preserved the workspace. Keep running and quit exited the app while preserving the exact shell PID. Reopening the same disposable state restored its unsent terminal input and all 17 supporting descriptors. End terminals and quit then ended only that owned terminal. The UI explains that shared provider execution may continue. These are disposable shell and metadata checks, not proof that a provider turn was interrupted.

Browser form state survives live view switching. An app or WebKit restart can lose unsent web input. Only supporting route, title, selection and layout metadata persist. Current provider ownership evidence and desktop/remote limitations are recorded in [continuation](session-continuation.md) and [provider ownership](provider-ownership.md). A complete Codex Desktop return and remote pairing remain unverified. Codex GUI inspection was unavailable to this task.

This is a local development result. It does not establish installed delivery, older macOS compatibility, physical keyboard/IME behavior, spoken VoiceOver or extended sleep/reboot continuity. OpenCode remains deferred.

## Verified development snapshot

On 13 October 2026, the local development snapshot passed:

- 81 XCTest cases and 13 Swift Testing cases.
- 14 Python tests, six website checks, and the repository checker.
- Native Debug, Release, and unsigned Distribution builds, helper packaging, and strict development signature verification.
- 100 private-runtime create/inspect/retry/attachment/cleanup cycles.
- Four native history assertions and seven app-crash/reopen assertions.
- All 11 native input-replay assertions in each of direct and persistent modes.
- Workspace switching, wrapped-history resizing, and crash restoration without extra tabs or workspaces.
- Fresh metadata creation, light/dark native layouts, and the simulated prototype's desktop and narrow flows.
- The prototype's Terminal launch fits on one line at 320px.
- Packaged runtime libraries, dependency notices, production metadata, stripped executable paths, and the branded Retina DMG layout.

These are targeted checks on one development host. They do not establish supported older macOS versions, physical keyboard-to-display latency, provider response quality, or production reliability. The original measurement records are retained locally outside this public snapshot.

## Remaining gates

The [public launch report](public-launch.md) records new packaging, website, updater integration, and targeted verification. Signed delivery and the remaining acceptance gates below are separate from that implementation work.

- An eight-hour continuity fixture failed unsent-input preservation after a last successful checkpoint at 6 hours 7 minutes 54 seconds. Two original fixture panes were absent afterward. The cause remains unresolved.
- Physical typing, composing input methods, spoken VoiceOver, and terminal-originated desktop link/file activation need hands-on verification.
- Provider responses and explicit history resume need complete compatibility coverage.
- Sleep/wake and reboot recovery remain pending user-controlled checks.
- Developer ID signing, notarization, signed installation/update behavior, and supported OS versions remain release work.

Unknown activity stays unknown. A running process does not prove an agent is working, a prompt was acknowledged, or a task succeeded.

## Workspace naming verification

On 14 October 2026, new workspaces received unique friendly names. The first composer starting prompt assigned a bounded title once, including from a later agent tab. Manual names remained fixed. Metadata version 5 replaced known generic automatic labels and preserved readable names, drafts, IDs, and bindings with a pre-migration backup.

The full Swift run passed 90 XCTest cases and 17 Swift Testing cases. Seven targeted naming tests then passed, including an additional future-snapshot rejection test. The 22 Python tests, repository checker, and native Debug build passed. Native GUI checks verified shell input, a later-tab prompt rename, manual rename precedence, and crash/reopen with the same four fixture process identities. Desktop and 320px prototype layouts were checked. Local provider fixtures received the full multiline prompts; this does not establish real-provider compatibility or extended continuity.

## Development lifecycle verification

On 13 October 2026, two development apps built from separate worktrees ran alongside the installed local daily app. Each had a distinct bundle identifier, metadata database, and private terminal socket. Automated native input opened a Home shell in each app and produced a separate runtime-side marker. The first app quit with sessions retained and reopened with the same shell process. The daily app and its runtime retained their original process identities. The launcher rejected rebuilding a running development instance. Both owned test apps were closed afterward, and the disposable worktree was removed.

The local change passed 83 XCTest cases, 17 Swift Testing cases, 22 Python tests, native Release builds for both checkouts, an unsigned Distribution build, bundle/signature audits, and the repository checker. A subsequent targeted run passed all five path-isolation tests. This check does not establish physical input, extended continuity, or an actual installed-app update.

The rebuild check exposed bundled tmux clients exiting with SIGKILL after helpers were copied over existing executable files. Signature verification still passed. The shell remained alive, but the rebuilt app could not reconnect. Helper packaging now copies into temporary files and renames them into place. Two corrected launcher rebuilds reopened the app with the same shell process and visibly retained unsent input. The second rebuild also confirmed a new helper inode. Owned test state was archived after cleanup. Running private runtimes keep their existing executable inodes.

The release workflow YAML was parsed locally. Its successful-main trigger, exact source checkout, opt-in variable, and protected release environment were inspected. The workflow was not run on GitHub. The active path remains private local installers. Signed automatic delivery is deferred. See the [development lifecycle](lifecycle.md).

See [acceptance](acceptance.md) for the full requirement matrix and [development](development.md) for reproducible commands. The source is MIT-licensed. A signed public installer is not available yet.

## Sidebar controls, 14 October 2026

Project rows expand and collapse without creating workspaces. Separate add controls create workspaces. Workspace and tab close controls reveal on hover or keyboard focus. Long workspace titles fade and reveal in one pass. GitHub origin-owner avatars use a bounded asynchronous cache with monogram fallbacks.

Targeted verification passed 89 XCTest cases, 17 Swift Testing cases, 30 Python tests after rebasing onto current main, the Release build, and the repository checker. The native sidebar fixture passed 27 checks. It covered hover hit-testing, focus retention, button accessibility roles, a 24-point tab close target, title animation, and preservation of a real shell process and unsent input. Collapsing a project releases its workspace views and retains its project control. The existing native close fixture passed all 12 checks. These results do not complete the full acceptance suite.

Native AppKit captures covered 1120 by 760 points in dark appearance and 650 by 450 in light appearance. Native UI automation confirmed project collapse, keyboard expansion, focus, and draft preservation. The offscreen WebKit check passed 20 checks at desktop, 390px, and 320px widths without opening a browser window. It caught and verified fixes for project focus loss and overridden icon sizing. Four focus-dependent CSS checks were skipped because the offscreen page has no active OS keyboard window. Human pointer checks and spoken VoiceOver remain unverified.

One disposable-shell sample measured 218.8 MiB app RSS and 19.4 MiB runtime/shell RSS, for a 238.1 MiB process RSS sum. App CPU averaged 2.40 percent during title reveal and avatar loading, then 0.42 percent after settling. The workload included native bitmap captures. This short sample is not a general performance result.

## Agent activity verification

On 15 October 2026, the activity change passed 102 XCTest cases, 17 Swift Testing cases, 30 Python tests, the repository checker, and a native Release build. Twelve hermetic launch-helper cases covered both providers. They exercised questions, child events, completion, failure, unsupported versions, disabled hooks, registration failure, and nested ownership. Literal arguments and silent malformed callbacks also passed.

Minimal real turns passed with Codex CLI 0.162.1 and Claude Code 2.1.296. Both emitted working and completion hooks. A separate Codex command typed into the native app's normal interactive zsh resolved the private wrapper and produced a real unread completion. Existing user startup files and provider configuration were retained.

Automated native interaction inspected a dark 1120×760 window and a light 680×480 window. It covered activity labels, workspace rollup, overflow, completion acknowledgment, Mark unread, provider controls, notification settings, child count, and the centered native Working spinner. Other activity states used synthetic provider events through the real callback and receiver.

After integrating the newer sidebar controls, all 27 native sidebar fixture checks passed. Foreground native interaction confirmed the combined activity labels, workspace rollup, and completion acknowledgment. The bundle runtime audit and strict development signature verification also passed.

Native notification delivery remains unverified. macOS returned "Notifications are not allowed for this application" for the isolated development build. Settings now displays that system error. Real interactive approval and question dialogs, notification click-through, app sounds, and spoken VoiceOver remain acceptance work. See [agent activity](agent-activity.md) for the implemented behavior and bounds.

### Activity resource observations

One local Release pass compared clean shells with no activity against simulated provider states before integration with the newer sidebar controls. Each case had a five-second warm-up and a 30-second observation. Pairs below mean no activity / reported activity. RSS is resident memory and includes shared pages. Total RSS sums the app, private runtime, and clean shells. These cases contain no real provider processes.

| Terminal tabs | App RSS, MiB | Total RSS, MiB | Owned CPU, percent of one core |
| --- | --- | --- | --- |
| 1 | 100.2 / 109.4 | 105.7 / 116.2 | 0.89 / 0.83 |
| 5 | 105.3 / 116.2 | 116.1 / 128.4 | 0.40 / 1.16 |
| 10 | 123.6 / 122.6 | 145.2 / 142.1 | 0.83 / 0.76 |

All six owned process sets stayed stable and the app binary stayed unchanged. The five-tab baseline lost visibility and activation before the final observation. Its CPU value is not comparable with the active case. Other cases were visible and active at both observation boundaries. This single pass does not establish a causal memory or CPU difference.

Each monitored CLI retains one waiting helper. The separate idle fake-CLI observation measured 9.6 MiB median RSS for the packaged helper. Its accumulated CPU increase was below the collector's resolution over 30 seconds. Callback bursts, real provider costs, and WindowServer costs were excluded. Shared RSS pages prevent interpreting that number as unique physical-memory overhead. The [measurement command](development.md#measurement-commands) retains local JSON evidence under ignored `.cache/` state.
