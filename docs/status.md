# Development status

Spookky is an early native macOS development preview. The terminal, workspace, project/worktree, file/diff, and metadata layers are implemented. Daily-use and distribution acceptance remain incomplete.

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
- Developer ID signing, notarization, actual installation/update behavior, and supported OS versions remain release work.

Unknown activity stays unknown. A running process does not prove an agent is working, a prompt was acknowledged, or a task succeeded.

## Workspace naming verification

On 14 October 2026, new workspaces received unique friendly names. The first composer starting prompt assigned a bounded title once, including from a later agent tab. Manual names remained fixed. Metadata version 4 replaced known generic automatic labels and preserved readable names, drafts, IDs, and bindings with a pre-migration backup.

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
