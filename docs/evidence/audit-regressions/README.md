# Session audit regressions

Project registration now preserves independent drafts. Provider recovery retains exact conversation identities and never replays an initial prompt. Native header and focus regressions cover narrow windows, late terminal attachment and accessibility activation.

## Interface evidence

| Previous header | Responsive header |
| --- | --- |
| ![Colliding controls at 650 points and 200 percent zoom](before-narrow-200.png) | ![Readable selected tab and compact overflow at the same dimensions](after-narrow-200.png) |

Both captures use disposable fixture data. At 650 points and 200 percent zoom, the requested sidebar width is temporarily clamped to leave 320 points for content. The selected supporting tab remains readable. Less frequent actions move into overflow. AppKit content captures can omit native window controls. These images establish layout, not terminal visual parity.

## Finding coverage

| Finding | Result and evidence boundary |
| --- | --- |
| F01, stable identity | Both real providers acquired their exact native ID. Native and hands-on resume checks retained that ID and the original folder. |
| F02, Changes responsiveness | The existing background watch-registration repair passed the delayed-registration fixture. Stale callbacks remain rejected. |
| F03, unavailable monitoring | Thread details retains the explanation and native hook-review action. Real Codex declined broad hook trust and correctly retained unknown activity. No permission defaults changed. |
| F04, Claude initial prompt | A real initial-prompt launch completed a checklist feature task without restart or prompt replay. Delayed startup now has per-conversation recovery actions. |
| F05, text clipping | Existing file-row geometry passed the rendered accented-text, Thai, code and line-number checks at 200 percent zoom. |
| F06, narrow layout | The narrow/wide light/dark matrix passed at 80, 100, 150 and 200 percent zoom. Selected tabs remain reachable. Split still falls back to Full below its pane limits. |
| F07, Claude titles | Bounded native AI-title metadata updated the existing row and primary heading. Explicit local aliases retain precedence. |
| F08, closed terminal view | Reopen terminal retains its backing process and unsent input. Closure and termination remain separate. |
| F09, Markdown reading width | Existing semantic previews retain an 80-character reading column and local code/table scrolling. Native rendering checks passed. |
| F10, later Git initialization | In a real disposable folder, Changes switched from its non-Git explanation to an untracked file after external Git initialization. No refresh or restart was needed. |
| F11, browser state | A live form survived switching, zoom and Full/Split. Website storage and selected-file descriptors survived UI restart. Unsent web forms do not survive restart; Quit warns and Cancel retains the live form. |
| F12, ended primary | Both real CLIs exited through their native flow and resumed the same saved ID. Three repeated clicks joined one launch. Resume arguments contained no initial prompt. Codex accepted new input. A fresh real Claude task resumed its exact ID and accepted unsent Unicode before and after UI restart. A further saved resume after Git initialization reached native trust and displayed saved output, then reproduced the file-access wait seen on the old server. Usable input after this transition remains open. |
| F13, project drafts | Real A/B/global draft isolation passed registration, removal, navigation and restart. Removing a project retained its draft and original folder. |

Hands-on provider tasks built and extended a local checklist with no external dependencies. Embedded-browser checks exercised add, completion, filters, search, exact deletion, clear-completed and local storage. They establish these disposable workflows, not general model quality or active-agent resource budgets.

## Additional repairs found during verification

- Activity monitoring retries a missing receiver on activation or reopen. It preserves a live receiver owner. A surviving real Claude process then delivered Working and Finished unread events without changing its PID or conversation ID.
- Sidebar rows expose native accessibility Press through the same stable-identity activation path as pointer input. Section rows remain inert.
- An open sidebar menu retains its anchor while history refresh coalesces into one pending snapshot.
- Terminal reattachment preserves focus in the file picker, sidebar search and other active editors. Explicit New chat, project draft and Open Terminal actions focus their own target.
- Native project discovery cancels an unstarted launch and clears departing-editor focus when its result selects a project draft. The shared completion also serves create/clone. A red native check reproduced both failures before the fix. Three new assertions pass, including preservation of the departing folder.
- Prepared native continuations now receive the existing activity integration after argument validation. Failure to prepare monitoring falls back to the same native command. Resume does not resolve the executable again, allocate a fresh provider ID or replay a starting prompt.
- A clean single-instance restart retained exact unsent Unicode terminal input, the process, the conversation and the selected file. Earlier mixed-build automation evidence was discarded after a stale driver binding reopened an older app copy.
- Browser downloads preserve the live form and offer an explicit external action. PDF and image previews retain native zoom behavior.

## Verification

[Native assertion results](checks.json) contain 2,670 passed assertions: 30 closure, 90 identity, 2,498 sidebar/display, 49 supporting-content and three cold-restore checks. These fixtures use synthetic provider metadata and owned real shells. They cover actual completed fullscreen transitions, tab hit areas, accessibility activation, bounded history views, live appearance recovery, selected content and input focus.

Swift reported 297 XCTest cases: 293 passed, four opt-in skips and zero failures. All 22 Swift Testing cases passed. The Python suite has 36 passed cases. Current installed CLI checks passed nine Codex cases and ten isolated Claude resume/ownership/attach cases, including unsent input through resume and attach. The Codex shared-server check used zero resume retries and retained its first-error field. The expanded Claude fixture found inherited wrapper input becoming a native prompt. Control commands now receive empty stdin; both input probes pass with one loopback model turn.

First failures remain in private local evidence. Fullscreen fixtures now wait for completed AppKit notifications. The selection fixture derives its origin from the terminal renderer. Those corrections do not turn timing retries into successful provider resumes.

## Measurements and continuity

[Matched measurements](measurements.json) used frozen baseline and candidate binaries. Resource cases ran serially in AB and BA order with five seconds of warm-up and 60 seconds of collection. Existing user agents and the real provider test sessions remained running. The foreground pairs also retained the fresh-runtime Claude session. Host load was uncontrolled.

| Measurement | Samples per build | Baseline | Candidate |
| --- | ---: | ---: | ---: |
| Empty readiness, median / p95 | 30 | 291.3 / 321.9 ms | 293.2 / 312.5 ms |
| Warm conversation selection, p95 | 35 | 26.0 ms | 24.4 ms |
| Recreated terminal selection, p95 | 105 | 60.3 ms | 60.2 ms |
| Five-shell foreground app RSS, two medians | 2 x 60 seconds | 102.8 / 128.9 MiB | 116.7 / 104.0 MiB |
| App plus owned runtime/shell RSS, same cases | 2 x 60 seconds | 112.6 / 140.6 MiB | 131.4 / 113.7 MiB |
| Foreground idle CPU, percent of one core | 2 x 60 seconds | 0.48 / 0.46% | 0.48 / 0.48% |

Both foreground pairs stayed visible and active at their CPU boundaries. Both process sets stayed stable. RSS differences changed direction across the two pairs. Separate vmmap physical-footprint observations were 89.1M / 88.7M for baseline and 128.3M / 88.7M for candidate. RSS includes shared pages and compression effects. These observations do not establish a causal memory change or performance improvement.

The separate 1/5/10-conversation matrix also completed two runs per build and count with stable process sets. Those windows were occluded and inactive at the boundaries. Their low CPU values are near collector resolution and do not replace foreground idle evidence. The JSON retains each case and its visibility boundary.

Empty readiness excludes provider discovery, the first rendered frame and CLI readiness. Selection ends at native attachment, layout and focus. It excludes first bytes and physical display latency. Both builds passed wrapped resize and crash restoration with unchanged process identities and viewport markers.

Source `5c4f716` completed all 20 matched cases, including four foreground observations. Its continuity attempt was interrupted after 12 minutes 51 seconds to repair startup acknowledgment during a native conversation switch. All 110 setup cycles passed their 13 resource checks. The preceding `67aa7fe` attempt was interrupted after 40 minutes 35 seconds to repair project-opening completion. Neither attempt is an eight-hour pass. The corrected executable will receive a new complete run.

## Remaining limits

Standalone Ghostty configuration was read, but the desktop tool denied access to its app. Visual provider-TUI parity remains unproven. Standalone Ghostty is 1.2.3; the embedded engine is 1.3.1. ANSI fixtures alone do not prove parity.

The user has no 1x display available, so physical 1x-to-2x transitions remain hardware blocked. Committed Unicode and emoji survived the real restart, but live IME composition and spoken VoiceOver remain unverified. Native accessibility and input replay are separate evidence.

The native project picker intermittently remained in a loading state during automation. Later registrations succeeded. A stock picker comparison worked. The cause is unconfirmed; a speculative deferral was reverted.

Claude resume displayed saved output but could stop accepting input on the surviving GUI-owned private server. The same native CLI also stalled there without a Spookky surface. Fresh independent private servers accepted input with the same environment and terminal settings. A later fresh GUI-owned runtime reproduced the wait after its disposable checkout gained Git metadata. Its native main thread waited inside `openat`. A plain file probe opened that checkout's Git config, the global Git config and Claude settings, then waited opening a public README in Documents. The OS cause remains unconfirmed. No privacy settings were changed and the server with a running Codex session was retained. A native SessionStart callback confirms monitoring integration; it does not prove input responsiveness.

The development bundle's existing Documents grant resolves to an earlier frozen app copy. That copy, the later resume owner and the final executable have different ad-hoc designated signature requirements. Stale signing/privacy state is a concrete hypothesis. No permission reset or new grant was performed.

Real Codex activity hooks remained gated by its native trust decision. Claude activity callbacks passed. Missing monitoring stays unknown. Native resume does not establish exclusive cross-application Claude ownership.

## Tested application source

Application source commit: `5c4f716a56bdeca8ee379b881e32bb0c4813d70a`.

Frozen Release executable SHA-256: `16f58176c27bb5c4a8a365cee8b699600dbed2c4e163025cad34f06f5da560f5`.

No new dependency or conversation database migration is introduced. The installed daily app is outside this verification build and has not been replaced.
