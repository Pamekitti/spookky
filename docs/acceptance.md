# Acceptance matrix

The native app must satisfy these requirements before release. [Current status](status.md) distinguishes targeted passing checks from unresolved gates. Prototype behavior does not establish native terminal, process, Git, or performance correctness.

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
| S12 | Existing bound workspace, Cmd+T | Browser supporting target opens; primary CLI remains unchanged |
| S13 | Saved local CLI conversation | Same provider's explicit resume in correct folder; no live-process claim |
| S14 | Other provider's session/files | New provider conversation with user-supplied context; shared files only |
| S15 | Compatible cloud coding session | Supported CLI handoff in clean dedicated checkout; copy/continuation labeled accurately |
| S16 | Cloud branch without conversation transfer | Code opens locally; new conversation, unsupported import explained |
| S17 | Mobile/web controlling local CLI | Same surviving local process, no duplicate launch |

For S01-S12, exercise Terminal, Codex without/with a prompt, and Claude Code without/with a prompt where repository state permits. An empty prompt is always valid. The agent choice never determines whether a folder needs Git isolation.

## Interaction checks

The 18 October layout/startup refinement passed 191 targeted native checks on its final local Release build. These use native fixtures and captures. Direct desktop automation could not bind the new development identity. Physical keyboard/IME and the native location-popover interaction remain separate checks.

- [x] Split headers share one 40-point row and align at the divider in wide/narrow windows and both appearances.
- [x] Full view joins primary first and all support tabs; selecting primary keeps those tabs visible.
- [x] The selected supporting tab remains visible after narrow-window layout. Overflow selection moves focus into that view; its close handler closes the support rather than the workspace.
- [x] Returning to Split restores the primary left, last support right and the same divider width.
- [x] Browser/artifact form state, terminal input and primary process identity survive layout and selection changes.
- [ ] Supporting + offers Browser, Files & Changes, Artifact and Terminal; new agents use New session/project +/Cmd+N.
- [x] Support closure chooses nearest left, then next, then primary. Primary closure hides the view and retains history/processes.
- [x] Startup has a bottom composer, maximum width 800 points, 24-point padding, optional prompt and provider/folder chips inside.
- [x] First use chooses Codex; new drafts remember the last agent independently of shells; existing drafts keep their provider and text.
- [ ] Local defaults in the folder popover; worktree/source/branch controls remain there.
- [ ] Enter adds a newline; Cmd+Return in the composer launches. Running CLI content replaces the composer.

- [ ] Cmd+N, Cmd+T, Cmd+W, Cmd+K, Cmd+Enter, and mouse equivalents follow the current contract.
- [ ] Cmd+N creates a draft; Cmd+T opens a browser target without launching a CLI. Direct shell access remains available.
- [x] Open Terminal below the startup composer starts a shell and retains the agent draft and last agent preference.
- [ ] Project + preselects its project. Workspace × targets the correct workspace.
- [ ] Closing an inactive workspace preserves current selection. Closing the final primary view retains metadata and processes and closes the window.
- [ ] Stop is separate from view closure. Stop confirmation preserves ownership verification. Cancel retains the primary and its input.

The following historical keyboard records predate the accepted 17 October conversation-workspace contract. They do not verify the current Cmd+T or close/Stop behavior.

Earlier targeted native check, 13 October 2026: final blank-tab and confirmed running-shell closure closed the window without a replacement tab. Cancel retained the shell and terminal focus. Closing a second tab retained the first shell and window. Cmd+N reopened a workspace after final-tab closure. The earlier installed local app also passed final blank-tab closure. Release build, 83 XCTest cases, 13 Swift Testing cases, and the repository checker passed. This record preceded the combined selection/closure installer. It does not establish the full acceptance suite.

Combined 0.1.3 build, 13 October 2026: Debug and Release pass. The native lifecycle fixture passes all 12 checks. These cover first launch, tab closure, Return/Escape, retained process/focus, Cmd+T, Cmd+N, reopening, and startup from saved empty state. The selection fixture passes all five checks, including retained highlighting and exact copied text. The full suite passes 83 XCTest cases and 15 Swift Testing cases.

The downloaded 0.1.3 DMG passed checksum verification. Build 103 is installed in Applications from source commit `42a892a12ac8a121a30dd6174e0acbc7514dae13`. Its ad hoc signature and bundled runtime pass verification. The update retained the existing macOS quarantine attribute and a backup of 0.1.2. The installed app reopened on the Home start screen.

The maintainer confirmed the physical keyboard checks on 13 October 2026. Cmd+T opens Terminal; Cmd+W then Escape cancels closure. Cmd+W then Enter closes the final tab and window without a replacement blank page. Cmd+T then reopens one terminal. Text selection, Cmd+C, and fullscreen continue to work. This confirms the targeted interaction checks on the maintainer's Mac. The broader input, accessibility, and continuity gates remain separate.

- [ ] Tabs can be selected, renamed, closed, and explicitly split; active tabs stay visible in overflow.
- [ ] Project clicks collapse/expand rows without creating workspaces or stopping processes; collapse survives restore. Project + and workspace search reveal the group.
- [ ] Sidebar add and workspace/tab close actions reveal on hover and keyboard focus, keep fixed title alignment, and retain close confirmations.
- [ ] Long workspace titles fade and reveal once; short titles remain still and Reduce Motion disables scrolling.
- [ ] GitHub origin-owner avatars load without blocking UI; offline, invalid-image, and non-GitHub cases retain cached images or monograms.
- [x] New workspace names are readable and unique. The first composer starting prompt names a workspace once, including after a shell launch. Manual names win; retries, additional prompts, and restart keep the title. Saved generic automatic labels upgrade without changing readable/manual names, paths, branches, drafts, or process identities. See [targeted naming verification](status.md#workspace-naming-verification).
- [ ] Project/workspace context menus support right-click and keyboard access.
- [ ] Tab/workspace switching preserves drafts, processes, output, scroll, and file selection.
- [ ] Root directory identity and start subdirectory remain distinct.
- [ ] Distinct conversations may share a checkout. Saved identity deduplication uses provider plus session ID.

## Git and preview checks

- [ ] A path with both staged and unstaged modifications appears in both correct groups.
- [ ] Untracked, renamed, deleted, conflicted, binary, large, symlink, mode-changed, and submodule entries are explicit.
- [ ] Unborn repositories, detached HEAD, paths with spaces/Unicode, and moved worktrees behave predictably.
- [ ] Committed comparisons use the chosen merge base and do not hide uncommitted work elsewhere.
- [ ] External branch/index edits invalidate stale reads without blocking input or moving selection.
- [ ] Unified/split diffs, old/new line numbers, context, maximize/restore, and mouse/keyboard resizing work.
- [ ] File previews do not execute content or follow unsafe symlinks outside the requested scope.

Targeted diff check, 15 October 2026: modified → untracked → modified preserved code and gutter widths in unified and split views. The Release fixture passed all 24 checks and 100 selection cycles. Preview p95 was 100.2 ms across 30 samples; syntax readiness p95 was 163.2 ms. Native visual checks covered M → A → M in dark appearance and narrow resizing in light appearance. These checks do not establish full v1 acceptance or installed delivery.

## Failure and lifecycle checks

Extended continuity remains blocked by an unsent-input preservation failure. The cause of the missing fixture panes is unresolved. See [current status](status.md).

- [ ] Missing agent, signed-out provider, failed private clone, and existing destination preserve drafts.
- [ ] Offline fetch labels cached state; missing source/branch names stay editable.
- [ ] Worktree creation succeeds but launch fails; retry reuses checkout and tab.
- [ ] Cancellation at each phase records retained artifacts and never removes unknown files.
- [ ] Uncertain initial prompt delivery requires explicit recovery without automatic resend.
- [ ] UI crash, window close, explicit background quit, sleep, owner failure, and reboot have distinct outcomes.
- [ ] Reattach preserves a live process; resume is an explicit new process using provider history.
- [ ] Closing views retains processes. Explicit terminal termination confirms ownership and explains that shared provider work may continue.
- [ ] Workspace/project removal keeps files and branches.
- [ ] Worktree deletion blocks active processes and unsafe dirty/unmerged/unpushed work; exact folder is confirmed.
- [ ] Save failure preserves in-memory drafts and produces a visible warning.
- [ ] Reload/startup restores compatible metadata without an extra blank workspace.

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
