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
| S12 | Existing bound workspace, Cmd+T | Blank tab inherits anchor; subsequent Cmd+T opens shell |
| S13 | Saved local CLI conversation | Same provider's explicit resume in correct folder; no live-process claim |
| S14 | Other provider's session/files | New provider conversation with user-supplied context; shared files only |
| S15 | Compatible cloud coding session | Supported CLI handoff in clean dedicated checkout; copy/continuation labeled accurately |
| S16 | Cloud branch without conversation transfer | Code opens locally; new conversation, unsupported import explained |
| S17 | Mobile/web controlling local CLI | Same surviving local process, no duplicate launch |

For S01-S12, exercise Terminal, Codex without/with a prompt, and Claude Code without/with a prompt where repository state permits. An empty prompt is always valid. The agent choice never determines whether a folder needs Git isolation.

## Interaction checks

- [ ] Cmd+N, Cmd+T, Cmd+W, Cmd+K, Cmd+Enter, and mouse equivalents follow the current contract.
- [ ] Cmd+N then Cmd+T works without pointer input, including focus routing immediately after render.
- [ ] Quick Terminal retains a typed agent draft in another tab.
- [ ] Project + preselects its project. Workspace × targets the correct workspace.
- [ ] Closing an inactive workspace preserves current selection; closing the last tab returns to a blank view.
- [ ] Tabs can be selected, renamed, closed, and explicitly split; active tabs stay visible in overflow.
- [ ] Project/workspace context menus support right-click and keyboard access.
- [ ] Tab/workspace switching preserves drafts, processes, output, scroll, and file selection.
- [ ] Root directory identity and start subdirectory remain distinct.
- [ ] Duplicate Git checkout offers Switch and add tab; independent Home/non-Git workspaces remain possible.

## Git and preview checks

- [ ] A path with both staged and unstaged modifications appears in both correct groups.
- [ ] Untracked, renamed, deleted, conflicted, binary, large, symlink, mode-changed, and submodule entries are explicit.
- [ ] Unborn repositories, detached HEAD, paths with spaces/Unicode, and moved worktrees behave predictably.
- [ ] Committed comparisons use the chosen merge base and do not hide uncommitted work elsewhere.
- [ ] External branch/index edits invalidate stale reads without blocking input or moving selection.
- [ ] Unified/split diffs, old/new line numbers, context, maximize/restore, and mouse/keyboard resizing work.
- [ ] File previews do not execute content or follow unsafe symlinks outside the requested scope.

## Failure and lifecycle checks

Extended continuity remains blocked by an unsent-input preservation failure. The cause of the missing fixture panes is unresolved. See [current status](status.md).

- [ ] Missing agent, signed-out provider, failed private clone, and existing destination preserve drafts.
- [ ] Offline fetch labels cached state; missing source/branch names stay editable.
- [ ] Worktree creation succeeds but launch fails; retry reuses checkout and tab.
- [ ] Cancellation at each phase records retained artifacts and never removes unknown files.
- [ ] Uncertain initial prompt delivery requires explicit recovery without automatic resend.
- [ ] UI crash, window close, explicit background quit, sleep, owner failure, and reboot have distinct outcomes.
- [ ] Reattach preserves a live process; resume is an explicit new process using provider history.
- [ ] Closing active agents/jobs confirms termination; unknown job state does not silently lose work.
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
