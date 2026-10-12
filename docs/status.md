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

See [acceptance](acceptance.md) for the full requirement matrix and [development](development.md) for reproducible commands. The source is MIT-licensed. A signed public installer is not available yet.
