# M2 metadata and operation recovery

Spookky stores workspace metadata in the development-specific SQLite database. Terminal bytes remain inside Ghostty and the private tmux runtime. Git commands have separate execution receipts.

## Version 2 migration

Before changing a version-1 snapshot, Spookky uses SQLite's backup API to create a consistent `workspace.sqlite.pre-v2-<UUID>.sqlite` file beside the database. The backup is private to the current user. Migration runs transactionally and retains project, directory, workspace, tab, and operation IDs; launch drafts; runtime bindings; selections; split layouts; and appearance preferences.

Version 2 adds common-repository identity, stable checkout records, project-creation and location drafts, immutable location requests, and phase receipts. A checkout record names its root. A selected subdirectory remains a separate start location. Reopening compatible metadata does not create an extra workspace or launch a command.

An incompatible or corrupt database is preserved. Do not replace it while another Spookky instance uses it. Keep the original and its backup when investigating a migration failure. Ordinary save failures retain current edits in memory and display an unsaved warning. A failed intent save prevents filesystem changes.

## Git command ownership

Filesystem-changing Git commands start suspended in a new process group. Spookky records the operation ID, command ID, PID, user identity, and process birth time before resuming Git. Execution records contain no terminal transcript or ordinary user input. Command output uses bounded pipes; each stream retains at most 1 MiB, and displayed Git errors retain at most 4 KiB.

On restart, Spookky checks those receipts before reconciling the directory. A live owned command remains in progress. Cancellation verifies process identity before signaling its owned group. Unknown startup or helper ownership remains uncertain. Spookky does not signal a PID merely because its number appears in a saved record.

The development app keeps Git execution records under its private runtime root's `git-operations` directory. These paths are separate from M0 and from the user's default tmux server. Tests use disposable roots and repositories.

## Completed and partial results

| Evidence | Recovery |
| --- | --- |
| No durable intent | No filesystem operation begins. |
| Intent saved, destination ownership unclear | Retain the path; require inspection or a fresh destination. |
| Known reserved empty worktree directory | Verify its device/inode and emptiness before retrying the frozen request. |
| Incomplete clone | Retain partial files and form values; choose a fresh destination. |
| Completed clone/create with saved or reconciled evidence | Finish registration without launching a terminal. |
| Worktree exists after an interrupted receipt write | Reconcile repository, path, branch, and commit; retain it without launching. Recovered evidence alone does not grant deletion ownership. |
| Worktree creation saved, CLI launch fails | Retain the checkout and agent draft; retry the launch phase. |
| Attachment fails after process creation | Reconnect to the existing process. |
| Prompt outcome uncertain | Reconcile; do not automatically resend. |
| Workspace folder changed or entry closed | Older operations may retain their results but cannot rebind that workspace. |
| Deletion interrupted | Check both Git registration and the actual directory before recording completion. |

Remote-source launches fetch the selected remote. A failure offers retry or an explicit cached commit. That cached commit is saved separately from a resolved creation commit. Selecting it freezes the displayed hash even if the tracking reference subsequently moves.

## Removal

Workspace closure keeps files and branches. Project removal unregisters it and keeps its workspaces and sessions. Worktree deletion is a separate action requiring the exact path.

Deletion requires a verified app-created checkout, matching repository identity, no active or uncertain Spookky-owned session using it, no dirty or untracked files, and no worktree lock. Spookky refreshes the relevant remotes, verifies the remote default branch, checks pushed and merged commits, saves the checked commit, and revalidates the checkout before unforced removal. Branches are retained.

These checks cover Spookky-owned sessions and Git evidence. External tools can change files or references concurrently. Git removal remains unforced and branches remain available.
