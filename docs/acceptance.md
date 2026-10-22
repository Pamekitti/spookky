# Acceptance matrix

The native app must satisfy these requirements before release. [Current status](status.md) distinguishes targeted passing checks from unresolved gates. Prototype behavior does not establish native terminal, process, Git, or performance correctness.

## Contextual new-session checks

- [x] Cmd+N and New chat select the viewed primary conversation's project draft, otherwise the global draft. A fresh project draft uses Local.
- [x] Existing drafts take precedence over inherited context. Text, images and provider-specific model choices survive switching and metadata round trips.
- [x] Model and supported effort choices appear at the bottom right and reach fresh provider launches as literal arguments. Default adds no override.
- [x] Project, No project, Local, existing checkout and new-worktree reference choices remain explicit. Discovery launches no agent.
- [x] Native popup selection restores composer shortcut focus. Real multiline input and disposable shell input/output pass.
- [x] Centered layout fits desktop and narrow windows in both appearances. Native image paste, removal and retained preview checks pass.

The 19 October batch passed 23 composer, 12 image and 87 conversation/lifecycle assertions. Installed CLI catalog discovery also passed without a model turn. These targeted results do not complete the broader acceptance matrix below. See [current status](status.md).

## Seventeen starting scenarios

| ID | Start | Expected outcome |
| --- | --- | --- |
| S01 | No project, Home or one-off folder | Terminal or either agent, no mandatory registration or prompt |
| S02 | Existing non-Git project | Local files and terminals; explanatory Changes state |
| S03 | Newly created ordinary folder | Folder created at chosen destination, registered, ready to launch |
| S04 | Empty Git repository | Local works; first-commit development; worktree choice explains limitation |
| S05 | Existing Git repository, Local | Current branch, index, and dirty files remain unchanged |
| S06 | Fresh clone | Chosen destination, cloned default branch, no automatic setup script |
| S07 | Existing worktree | Same checkout reused, no duplicate worktree |
| S08 | New worktree from HEAD | Separate checkout from resolved committed state; generated/custom branch |
| S09 | New worktree from local branch | Source local ref distinguished from remote tracking ref |
| S10 | New worktree from origin/dev | Fetch or explicit cached choice; new working branch; optional prompt |
| S11 | Existing feature branch | Reuse its checkout or create one without bypassing branch protection |
| S12 | Existing bound workspace, Cmd+T | New tab supporting page opens; primary CLI remains unchanged |
| S13 | Saved local CLI conversation | Same provider's explicit resume in correct folder; no live-process claim |
| S14 | Other provider's session/files | New provider conversation with user-supplied context; shared files only |
| S15 | Compatible cloud coding session | Supported CLI handoff in clean dedicated checkout; copy/continuation labeled accurately |
| S16 | Cloud branch without conversation transfer | Code opens locally; new conversation, unsupported import explained |
| S17 | Mobile/web controlling local CLI | Same surviving local process, no duplicate launch |

For S01-S12, exercise Terminal, Codex without/with a prompt, and Claude Code without/with a prompt where repository state permits. An empty prompt is always valid. The agent choice never determines whether a folder needs Git isolation.

## Version 8 persistent thread checks

The current Release passed 1,899 native assertions across workflow, browser/artifact, cold restore and file/diff fixtures. Nine hands-on accessibility checks covered picker typing, file-tab reuse, app zoom and the retained draft. The Swift run passed 294 of 297 cases, with three opt-in cases skipped. All 30 Python tests passed. See [current evidence](evidence/persistent-threads/README.md) for screenshots, binary identifiers and measurement boundaries.

- [x] Primary has no close target or close-thread menu action. Cmd+W closes its window and preserves execution.
- [x] Supporting closure selects the correct neighbor or the same primary. Inactive closure preserves focus.
- [x] New tab, native file search and independent Changes preserve the primary draft and process.
- [x] Pinned, Projects, Recents and Archived use shared identities. Project assignments survive refresh.
- [x] Version 7 to 8 migration backs up and preserves aliases, drafts, launches, bindings and supporting descriptors.
- [x] Five initial project rows, ten-row expansion and collapse reset remain lazy and bounded.
- [x] Tabs receive pointer events across their full bounds in Split/Full and both appearances at 80%, 100%, 150% and 200%.

The following version 7 results are historical. Their primary-view closure contract is superseded by persistent threads.

## Version 7 workflow checks

The version 7 production code passed 199 automated native workflow assertions, 39 browser/artifact and cold-restore assertions, and 24 file/diff assertions. The full Swift run passed 281 cases with three opt-in cases skipped. All 30 Python tests and the repository checker passed. Native fixtures use programmatic pointer and keyboard events; they do not establish physical typing, IME composition or spoken VoiceOver.

- [x] First use and final-view closure show the landing composer without an intermediate button or blank window.
- [x] Cmd+N and project + select independent drafts. Persistence tests retain both through database restart.
- [x] Five recent entries and repeated ten-entry expansion work independently per project. Search includes older uncached history.
- [x] Startup, project expansion, pagination and search start zero conversation agents.
- [x] Native scroll checks reconcile a stationary pointer, one hover and one selected row, with static titles and preserved keyboard focus.
- [x] Project clicks toggle without selecting the header. App-owned controls suppress focus rings, and keyboard feedback preserves control geometry.
- [x] Shared tabs remain bounded, aligned and selectable in Split/Full layouts at narrow and wide sizes in both themes.
- [x] File and Changes tabs preserve independent preview/diff context without duplicated mode or close controls.
- [x] Last support/session closure selects the correct neighbor or landing and preserves processes and drafts.
- [x] Migration preserves user-created sessions, aliases, drafts, supporting tabs, launch receipts and bindings.
- [x] Current startup, switching and resource costs are measured without stopping hidden agents. See [performance](performance.md) for workload and visibility limits.

## Interaction checks

Earlier evidence: the initial 18 October layout/startup candidate passed 191 targeted native checks. The installed-app fixes then passed 105 affected checks, including narrow-window tab visibility and warning/content separation. Desktop automation verified newline entry, ASCII shell input, the native folder picker and retained drafts across Full/Split changes in the privately installed app. Physical keyboard/IME, spoken VoiceOver and extended continuity remain separate checks.

- [x] Split headers share one 40-point row and align at the divider in wide/narrow windows and both appearances.
- [x] Full view joins primary first and all support tabs; selecting primary keeps those tabs visible.
- [x] The selected supporting tab remains visible after narrow-window layout. Overflow selection moves focus into that view; its close handler closes the support rather than the workspace.
- [x] Returning to Split restores the primary left, last support right and the same divider width.
- [x] Browser/artifact form state, terminal input and primary process identity survive layout and selection changes.
- [x] Supporting + opens New tab with address/search, Files, Changes, Open artifact and Terminal; new agents use New chat/project +/Cmd+N.
- [x] Support closure chooses nearest left, then next, then primary. Primary has no close action; Cmd+W closes the window and retains history/processes.
- [x] Startup has a centered composer, maximum width 620 points, 24-point outer padding, optional prompt and provider/model controls inside.
- [x] First use chooses Codex; new drafts remember the last agent independently of shells; existing drafts keep their provider and text.
- [ ] Local defaults in the checkout picker; the location popover’s New worktree switch reveals source and branch options.
- [ ] Enter or Cmd+Return in the composer launches, including an empty draft; Shift+Return adds a newline. Marked text and held-key repeats do not launch. Running CLI content replaces the composer.

- [ ] Cmd+N, Cmd+T, Cmd+W, Cmd+K, Cmd+Enter, and mouse equivalents follow the current contract.
- [x] Cmd+N selects the retained global landing draft; Cmd+T opens New tab without launching a CLI. Direct shell access remains available.
- [x] Open Terminal below the startup composer starts a shell and retains the agent draft and last agent preference.
- [x] Project + selects its retained draft. Conversation contextual actions target the correct view.
- [x] Closing an inactive supporting tab preserves selection and focus. Closing the last support selects the same conversation. Primary and landing Cmd+W close the window.
- [x] Stop is separate from view closure. Stop confirmation preserves ownership verification. Cancel retains the primary and its input.

The following historical keyboard records predate the current landing contract. They do not verify the current Cmd+T or close/Stop behavior.

Earlier targeted native check, 13 October 2026: final blank-tab and confirmed running-shell closure closed the window without a replacement tab. Cancel retained the shell and terminal focus. Closing a second tab retained the first shell and window. Cmd+N reopened a workspace after final-tab closure. The earlier installed local app also passed final blank-tab closure. Release build, 83 XCTest cases, 13 Swift Testing cases, and the repository checker passed. This record preceded the combined selection/closure installer. It does not establish the full acceptance suite.

Combined 0.1.3 build, 13 October 2026: Debug and Release pass. The native lifecycle fixture passes all 12 checks. These cover first launch, tab closure, Return/Escape, retained process/focus, Cmd+T, Cmd+N, reopening, and startup from saved empty state. The selection fixture passes all five checks, including retained highlighting and exact copied text. The full suite passes 83 XCTest cases and 15 Swift Testing cases.

The downloaded 0.1.3 DMG passed checksum verification. Build 103 is installed in Applications from source commit `42a892a12ac8a121a30dd6174e0acbc7514dae13`. Its ad hoc signature and bundled runtime pass verification. The update retained the existing macOS quarantine attribute and a backup of 0.1.2. The installed app reopened on the Home start screen.

The maintainer confirmed the physical keyboard checks on 13 October 2026. Cmd+T opens Terminal; Cmd+W then Escape cancels closure. Cmd+W then Enter closes the final tab and window without a replacement blank page. Cmd+T then reopens one terminal. Text selection, Cmd+C, and fullscreen continue to work. This confirms the targeted interaction checks on the maintainer's Mac. The broader input, accessibility, and continuity gates remain separate.

- [ ] Tabs can be selected, renamed, closed, and explicitly split; active tabs stay visible in overflow.
- [ ] Project clicks collapse/expand rows without creating workspaces or stopping processes; collapse survives restore. Project + and workspace search reveal the group.
- [x] Project add and conversation menus reveal on hover/focus with fixed title alignment. Tab close controls use a shared 24-point target.
- [x] Long conversation titles truncate without animation and retain complete tooltips and accessibility names.
- [ ] GitHub origin-owner avatars load without blocking UI; offline, invalid-image, and non-GitHub cases retain cached images or monograms.
- [ ] New workspace names are readable and unique. The first composer starting prompt names a workspace once, including after a shell launch. Manual names win; retries, additional prompts, and restart keep the title. Saved generic automatic labels upgrade without changing readable/manual names, paths, branches, drafts, or process identities. See [targeted naming verification](status.md#workspace-naming-verification).
- [ ] Project/workspace context menus support right-click and keyboard access.
- [x] Tab/workspace switching preserves drafts, processes, output, scroll, and file selection.
- [ ] `$sim` and `/sim` show installed skill matches in an agent launch draft. Enter inserts a provider reference, Escape keeps the draft, and ordinary Enter still launches.
- [x] Root directory identity and start subdirectory remain distinct.
- [x] Distinct conversations may share a checkout. Saved identity deduplication uses provider plus session ID.

## Git and preview checks

- [ ] A path with both staged and unstaged modifications appears in both correct groups.
- [ ] Untracked, renamed, deleted, conflicted, binary, large, symlink, mode-changed, and submodule entries are explicit.
- [ ] Unborn repositories, detached HEAD, paths with spaces/Unicode, and moved worktrees behave predictably.
- [ ] Committed comparisons use the chosen merge base and do not hide uncommitted work elsewhere.
- [ ] External branch/index edits invalidate stale reads without blocking input or moving selection.
- [ ] Unified/split diffs, old/new line numbers, context, maximize/restore, and mouse/keyboard resizing work.
- [ ] File previews do not execute content or follow unsafe symlinks outside the requested scope.

Targeted diff check, 15 October 2026: modified → untracked → modified preserved code and gutter widths in unified and split views. The Release fixture passed all 24 checks and 100 selection cycles. Preview p95 was 100.2 ms across 30 samples; syntax readiness p95 was 163.2 ms. Native visual checks covered M → A → M in dark appearance and narrow resizing in light appearance. These checks do not establish full v1 acceptance or installed delivery.

Current file/diff verification passed all 24 assertions and 100 selection cycles. Selected-diff readiness measured 107.3 ms p95 across 30 observations; syntax readiness measured 172.5 ms p95. Preview, metadata, surface and watcher bounds passed. These checks preserve file/Changes context, terminal drafts, selected rows and focus during continuous edits. They do not complete the broader Git scenarios above.

## Failure and lifecycle checks

Extended continuity remains blocked by an unsent-input preservation failure. The cause of the missing fixture panes is unresolved. See [current status](status.md).

- [ ] Missing agent, signed-out provider, failed private clone, and existing destination preserve drafts.
- [ ] Offline fetch labels cached state; missing source/branch names stay editable.
- [ ] Worktree creation succeeds but launch fails; retry reuses checkout and tab.
- [ ] Cancellation at each phase records retained artifacts and never removes unknown files.
- [ ] Uncertain initial prompt delivery requires explicit recovery without automatic resend.
- [ ] UI crash, window close, explicit background quit, sleep, owner failure, and reboot have distinct outcomes.
- [x] Reattach preserves a live process; resume is an explicit new process using provider history.
- [x] Closing views retains processes. Explicit terminal termination confirms ownership and explains that shared provider work may continue.
- [ ] Workspace/project removal keeps files and branches.
- [ ] Worktree deletion blocks active processes and unsafe dirty/unmerged/unpushed work; exact folder is confirmed.
- [ ] Save failure preserves in-memory drafts and produces a visible warning.
- [x] Reload/startup restores compatible metadata without an extra blank workspace.

## Terminal and UI checks

- [ ] Native TUI drawing, alternate screen, resize, Unicode/IME, selection, bracketed paste, Ctrl+C, and provider approvals work.
- [ ] Dragging terminal text selects it without moving the window, in normal and fullscreen layouts.
- [ ] Selection remains highlighted after release and Cmd+C copies it. CLI mouse input and wheel scrolling remain usable.
- [ ] Fullscreen drag keeps the window present. Exiting restores normal geometry and header dragging.
- [ ] File/image path input never appends Enter automatically; supported image clipboard behavior is verified per CLI version.
- [ ] CLI model/auth/permission controls remain provider-owned.
- [ ] No hidden process is stopped merely to lower resource use.
- [ ] Both themes, long names, empty states, keyboard-only use, native VoiceOver, and supported window sizes are checked.
- [ ] Performance report follows [the measurement protocol](performance.md).

Use temporary repositories and app-specific runtime directories for destructive fixtures. Never use the user's working repositories as test data. Mark evidence with exact app/dependency/CLI versions and whether each check is automated or manual.

## Agent activity checks

- [x] Activity is separate from terminal lifecycle. Process presence alone stays Unknown.
- [x] Binding, invocation, provider, and secret validation reject foreign registrations. Child events do not finish the parent.
- [x] Stale and duplicate events, late completion after process exit, unread acknowledgment, monitoring suspension, preview privacy, and metadata migration have targeted tests.
- [x] Both adapters preserve literal prompt arguments and avoid model permission bypasses. Hook fixtures exercise questions, child events, successful completion, and failure.
- [x] Minimal real turns with Codex CLI 0.162.1 and Claude Code 2.1.296 produce working and completion hooks. Manual Codex launch through the native app's normal interactive zsh also produces unread completion.
- [x] Native dark/light layouts, 1120×760 and 680×480 windows, overflow labels, completion acknowledgment, Mark unread, Settings controls, child count, and centered Working spinner were inspected through automated native interaction.
- [ ] Real interactive approval and question dialogs are exercised for each supported CLI version.
- [ ] Authorized native banners, app sounds, quiet-mode suppression, and exact notification click-through pass end to end.
- [ ] Spoken VoiceOver and physical keyboard use of the new controls are checked.

On 15 October 2026, macOS returned "Notifications are not allowed for this application" for the isolated development build. Settings displayed that error. Native banner and notification click-through acceptance remains open. Simulated hook payloads do not establish real provider permission-dialog compatibility. See [agent activity](agent-activity.md) and [current status](status.md).
