# Agent activity

Prepared native resumes receive the same optional activity context as fresh launches. The coordinator validates the original resume or attach arguments before integration, preserves the executable choice and operation ID, and does not resolve the provider again. Activity setup failure falls back to the native command. It never assigns a fresh conversation ID or resends a starting prompt.

Spookky shows which terminal needs attention through provider lifecycle hooks. The terminal remains the place to read responses, answer questions, and approve tools.

## Status and attention

| Label | Evidence |
| --- | --- |
| Working | A prompt or tool event from the attached provider |
| Needs input | A provider permission, question, plan-exit, or elicitation event |
| Finished, unread | The provider ended a turn that has not been viewed |
| Idle | An attached session with no active turn, or an acknowledged completion |
| Agent failed | A terminal provider failure or a nonzero CLI exit |
| Interrupted | An explicit interruption or signal exit |
| Activity unknown | Tracking is unavailable, reset, disabled, or restored without a fresh event |

Finished means the provider ended a turn. It does not establish that the requested work succeeded. A failed tool call alone leaves the agent Working because the agent can recover.

The sidebar follows the primary conversation terminal. Its activity indicator takes precedence over PR state: Needs input, Agent failed, Working, then Finished unread. Unknown and Interrupted remain available in details. Unread completions survive later invocations and app restarts. Reported child agents appear as a bounded count in the terminal header and tooltips. Child events cannot finish their parent.

```text
provider hook --> private helper --> local activity socket --> matching terminal
                                                              |
                                      +-----------------------+------------------+
                                      |                       |                  |
                                  tab status           workspace status     notification

Working --> Needs input --> Working --> Finished, unread --> viewed --> Idle
    |
    +--> Agent failed / Interrupted / Activity unknown
```

Viewing a terminal in the active, visible window acknowledges completion only after its scrollback is confirmed at the bottom. Both visible split panes count. The check combines Ghostty viewport metrics with the owned tmux viewport. Empty, unavailable or failed observations retain unread attention. After the asynchronous check, the invocation and completion IDs must still match. A newer completion receives its own check. Provider-internal scrolling is outside this viewport guarantee.

Right-click a tab or workspace for Mark unread, Mark read, or Reset activity status. Mark read explicitly clears unread completion attention. Viewing or marking a completion read preserves a live Needs input or failure status.

The sidebar uses a blue unread dot, a blue Needs input pill, and a thin gray Working ring. The ring animates only while visible and respects Reduce Motion. Hover and keyboard focus reveal direct Pin/Archive actions. The tab overflow menu retains activity labels. Terminal dimensions follow the existing layout controls.

## Read-only checkout and PR indicators

A gray worktree glyph requires Git to report a linked checkout. PR state comes from the installed GitHub CLI and its existing authentication. Draft PRs are gray, open PRs green, closed PRs red, and merged PRs purple. A verified PR can be opened from the details card. Spookky does not merge PRs.

New associations require a live thread binding and an observed repository/branch. A unique matching open PR is preferred. A closed or merged PR must match the observed head commit. Fork collisions and ambiguous matches stay unknown. Imported history without a saved association does not inherit the current folder's PR. Optional verified associations survive metadata restart; older snapshots require no migration.

Only visible rows request refreshes. Requests share the two-process Git read scheduler, deduplicate by repository/branch or known PR, and use 10-second process and 128 KiB output limits. The transient cache holds at most 128 entries for one minute. Hidden or inactive windows cancel refresh work. Missing GitHub CLI, authentication, unsupported remotes or network errors leave PR state unavailable without a login prompt. GitHub.com is the initial supported host.

## Notifications

Settings has separate banner and app-sound controls for input requests, completed turns, and failures. Both providers and the three banner types are enabled by default. App sounds are off by default. Existing CLI sound hooks remain active.

The Dock badge counts workspaces with input requests, failures, or unread completions. A notification opens its exact workspace and terminal. Pending alerts are replaced per terminal and rechecked after a 250 ms debounce. The default setting suppresses alerts while that terminal is visible in the active window. macOS notification authorization and Focus settings also govern delivery.

Test notification reports whether macOS accepted the request. If authorization or delivery fails, Settings shows the system error. Later alerts recheck authorization after a previous refusal.

Message previews are limited to 180 characters. Disabling previews clears saved previews and discards new preview text. No conversation transcript is stored. Disabling a provider stops activity updates immediately and preserves unread completions. Re-enabling hook injection takes effect on the next CLI launch.

## CLI integration

The tested minimum versions are Codex CLI 0.162.1 and Claude Code 2.1.296. Older or unrecognized executables run without injected hooks and show unknown activity. Capability checks are cached until the executable changes. They have bounded time and output limits.

Direct agent launches use invocation-only configuration. Codex keeps its normal hook trust checks. Spookky does not add hook trust, model approval, or sandbox bypass flags. Hooks require provider approval before activity can be reported. The callback command stays stable across invocations so trust does not depend on a generated invocation filename. Claude receives additive `--settings` hook configuration. Global provider files are unchanged. Existing hooks, authentication, prompt editing, shortcuts, and history remain provider-owned.

New terminals prepend private `codex` and `claude` wrappers to PATH. For interactive zsh, private startup files source the user's original files in order and restore the wrapper path after startup and before prompts. The user's ZDOTDIR is restored afterward. No user startup file is changed. `zsh -f` keeps its requested startup behavior. Other shells retain their normal configuration; a configuration that replaces PATH may bypass manual monitoring. Aliases, functions, and absolute executable paths can also bypass a PATH wrapper.

Nested agent commands inherit ownership from the outer CLI. They do not replace its status. Provider-reported child events use child IDs. Explicit hook-disable flags and unsupported versions leave the underlying CLI available without Spookky hook injection.

Only the latest top-level CLI invocation in a terminal owns its activity. Use separate tabs for parallel agents. Older background commands continue running, but their events cannot replace the newer invocation's status.

## State and runtime cost

SQLite metadata version 5 adds one bounded activity record per tab and completion acknowledgment IDs. Migration creates a private pre-v5 backup. Child presence is transient and capped at 64 records per terminal. Restored activity becomes Unknown until a fresh event arrives. Restoring does not launch agents, resend prompts, or replay notifications.

The app owns one private local datagram socket. Each monitored CLI has one waiting launch helper. Each provider event briefly starts a callback helper. There is no transcript scan or periodic status poll. Callback input is capped at 1 MiB; socket messages are capped at 8 KiB. Socket errors and malformed callbacks produce no output and exit successfully. A monitoring registration failure starts the original CLI without injected hooks.

If the activity receiver could not start, activating the app or reopening its window retries it. An active receiver owned by another instance remains protected. Activity stays Unknown until a fresh provider event arrives; recovery does not restart agents or replay prompts.

Records, wrappers, and the socket stay under the app's existing private runtime root. A secret and the active invocation ID correlate events to the current terminal. Closed bindings lose their registration. Provider IDs and previews have explicit size limits.

See [development checks](development.md#agent-activity-checks) for reproducible fixtures and [current status](status.md) for verified behavior and remaining limits.
