# User flows

Status: current product behavior. [Current status](status.md) records implementation and verification boundaries.

## Entry map

```text
Open Spookky
|
+-- First use ----------------------> Blank workspace
|
+-- Returning user -----------------> Restore workspace/tab metadata
|                                    +-- Live process -> Reattach
|                                    +-- Process gone -> Ended state
|
+-- Cmd+N --------------------------> Blank workspace, no process yet
                                     |
                                     +-- Cmd+T -> Terminal in Home
                                     |
                                     +-- Choose recent/project
                                     |   +-- Local (default)
                                     |   +-- Existing worktree
                                     |   +-- New worktree
                                     |
                                     +-- Add project
                                     |   +-- Open folder
                                     |   +-- Clone URL
                                     |   +-- Create folder [+ optional Git]
                                     |
                                     +-- Use folder once
                                     |
                                     +-- Choose launch tool
                                         +-- Terminal
                                         +-- Codex [+ optional prompt]
                                         +-- Claude Code [+ optional prompt]
```

First use defaults to Home and Terminal. Later starts remember the selected tool and display it explicitly. Choosing a tool, project, or reference alone does not launch a process. Blank tabs in an unbound workspace share its eventual anchor.

## Keyboard and mouse contract

| Action | Result |
| --- | --- |
| Cmd+N / New workspace | Create and select an unbound workspace immediately. |
| Project + | Create an unbound workspace with that project selected, Local by default. |
| Cmd+T while a running/ended tab is selected | Open a blank tab in the same workspace. |
| Cmd+T while a blank tab is selected | Open Terminal at the selected/inherited location immediately. |
| Cmd+T with an agent prompt draft | Preserve that draft in its tab and open Terminal in another tab. |
| Tab-strip + | Always add a blank tab. Do not label it Cmd+T when that shortcut currently means launch Terminal. |
| Cmd+Enter in launch composer | Launch selected tool with optional initial prompt. |
| Enter in initial prompt | Insert a newline. |
| Cmd+W / tab × | Close selected tab, confirming active agent/job termination. |
| Workspace × | Close workspace, confirming active sessions; keep files and branch. |
| Cmd+K | Find a workspace. |
| Right-click / Shift+F10 on a sidebar entry | Open secondary contextual actions. |
| Double-click selected terminal tab | Rename its UI label. |
| Right-sidebar toggle | Show/hide Files and Changes. Never start a process. |

Native shortcuts must be registered deliberately. Ordinary CLI keys and provider shortcuts pass through to the terminal. Escape closes the current menu/dialog and restores focus. Switching a tab preserves process state, draft, scroll, and pane selection.

## Project registration

```text
Open folder -> choose folder -> detect plain/Git/worktree -> register -> select
Clone URL   -> URL + destination -> authentication if needed -> clone -> select
Create      -> name + destination + optional Git -> create folder -> select
```

Project creation is local. It does not create or publish a GitHub repository. Preserve form values on cancellation and validation errors. Existing destinations must never be overwritten. Re-registering a known folder reuses the project.

Use folder once selects an anchor without project registration. Empty Git repositories support Local. Disable new-worktree creation until there is a commit, with an explanation. Do not run repository setup scripts during registration.

## Local and existing worktrees

Local uses the selected directory with its existing branch, edits, and files. Show the path and branch. Existing checkout choices appear when relevant; do not make users choose among redundant controls.

If the checkout already has a workspace, show its identity and offer **Switch and add tab** or Cancel. Do not represent the same files as two isolated workspaces. Discover worktrees made outside Spookky through Git metadata.

A selected repository subdirectory is a tab start directory, not a separate checkout identity. Reuse the checkout workspace and carry that start directory into the new tab. Label the repository scope of Changes explicitly. This native edge case still needs implementation beyond the fixture prototype.

## New worktree, including origin/dev

```text
Project -> New worktree
          |
          +-- Source: HEAD | local dev | origin/dev | other available ref
          +-- Working branch: Automatic | custom new name | existing branch
          +-- Tool: Terminal | Codex | Claude Code
          +-- Initial prompt: optional, agents only
          |
          v
Resolve source -> create checkout -> launch process -> deliver optional prompt
```

For a remote source, refresh the remote and resolve the named reference to a commit. Fetch does not pull, reset, or switch the original checkout. If offline, offer Retry or explicitly use a cached reference with its known commit. A missing source leaves the draft editable.

Default source is the repository's remote default branch when known, otherwise HEAD. Remember an explicit source choice per project. Never assume every project has main or dev.

New branch names can be generated. When continuing an existing branch, reuse its checkout if already checked out. Otherwise create a worktree using that branch. Respect Git's branch-in-use protection.

Creating a worktree and launching an agent are separate operations. An agent failure does not discard a successful worktree. Retry reuses that checkout and does not duplicate tabs or processes.

## Launch and initial prompt

The start page uses one composer with a tool picker. For agents, the prompt field is visible and optional. With no prompt the action opens the CLI; with text it starts the CLI with that instruction. Terminal mode has one direct launch action and a Cmd+T hint.

Changing tools preserves the agent prompt draft. Shell launches never execute that text. Auth and permission prompts remain inside the provider CLI. Missing executables lead to guidance plus a working Terminal fallback.

Prompt state must distinguish pending, delivered, and uncertain. Process launch success alone does not prove delivery. An uncertain outcome must not automatically resend. An explicit resume does not silently receive a pending new-session prompt.

## Terminal-first and parallel work

```text
Home shell -> cd project -> run codex/claude -> use provider's own commands
                           |
                           +-- Open current folder as workspace (explicit)

Same files, another session -> Cmd+T -> choose tool
Separate edits             -> Cmd+N -> project -> New worktree
Different project          -> Cmd+N -> choose project
```

New tabs inherit the workspace anchor. A foreground shell directory is separately observed when shell integration supports it. If directory detection is unavailable, avoid guessing it.

Splitting is explicit and launches another terminal. Multiple providers in one workspace do not share a conversation. Switching or collapsing UI never stops them. Provider-owned unsent input stays with the surviving process; a UI-owned launch draft is stored separately.

## Continue existing work

| Origin | Correct continuation |
| --- | --- |
| Live session owned by Spookky | Reattach the same process. |
| Saved local CLI conversation | Open the matching directory and provider resume picker. |
| Existing process in another terminal | Keep it there, or start another CLI and explicitly resume saved history. No automatic process transfer. |
| Provider-supported cloud handoff | Use the documented CLI flow in a compatible, clean, dedicated checkout. |
| Cloud code branch without handoff | Fetch branch, open checkout, start a new CLI conversation with supplied context. |
| Mobile/web controlling local CLI | Return to that same local process while its owner is alive. |
| Other desktop app | Locate its checkout; use supported handoff or start with its files and explicit context. |
| Ordinary web chat | Select/create a project and paste useful context into a new CLI. |

The prototype demonstrates Codex local resume and illustrative Claude handoff/remote-control commands. Provider commands must be verified against installed versions during implementation. See [architecture](architecture.md). There is no universal import screen or promise of cross-provider conversation conversion.

Do not run a handoff that switches a branch in a checkout used by another active agent. A copied branch does not include conversation history, ignored files, secrets, or environment setup.

## Files and Changes

Files lists complete workspace content, including unchanged files. Changes belongs to the checkout, not the selected agent.

- **Uncommitted:** separately show staged, unstaged, untracked, and conflicted paths. A path can have both staged and unstaged changes.
- **Against branch:** committed changes from the merge base of selected base and HEAD to HEAD. Label this comparison and the base. Outstanding working-tree edits remain in Uncommitted.
- Non-Git folders have Files and an explanatory Changes state.
- An unborn Git branch supports untracked/index changes; no committed comparison exists yet.
- Renames, deletions, binary content, symlinks, mode changes, submodules, conflicts, and large files need explicit representations.

Open a file/diff beside the terminal, maximize it, change layout, or close it. On narrow windows the preview uses available space and the overlaid file list dismisses after selection. A split-diff preference is retained while narrow views render unified content.

Commits, pushes, tests, and PRs happen through the user's preferred tools. Spookky never requires a review sequence.

## Close and return

| Event | Result |
| --- | --- |
| Switch tab/workspace | Preserve process and view state. |
| Close blank/ended tab or confirmed idle shell | Close immediately. Last tab returns to a blank tab in the same workspace. |
| Close active agent or shell with a job | Confirm termination or cancel. If shell-job state is unknown, use a conservative close confirmation. |
| Close workspace | Confirm active sessions, remove entry, keep checkout and branch. Closing an inactive entry preserves the active workspace. |
| Close window | Normal macOS app behavior; processes may continue. |
| Quit with live sessions | Cancel, end owned sessions and quit, or explicitly continue in background if the runtime supports it. |
| Reopen with live owner | Reattach without launching or sending again. |
| Restart computer/runtime lost | Restore metadata; mark processes ended; offer explicit restart/resume. |
| Remove project | Unregister it; move retained workspaces to No project; keep files and sessions. |
| Delete app-created worktree | Separate action; check running processes, dirty/untracked work, and unmerged/unpushed commits. Confirm exact folder. Keep branch by default. |

Process continuity is subject to M0 validation. A saved conversation is not a surviving process. Hidden sessions still consume resources; never kill them only because their views are hidden.

## Recovery

| Failure | Recovery contract |
| --- | --- |
| Missing CLI / authentication | Show the actual cause; retain launch draft; offer Terminal and explicit retry. |
| Clone error / destination exists | Keep values, show phase, correct or retry. Do not overwrite. |
| Offline fetch | Retry or knowingly use an available cached ref. |
| Duplicate branch / checkout | Reuse known checkout or choose another branch. |
| Worktree created, launch failed | Retain worktree; resume at launch step. |
| Canceled operation | Retain known completed steps; expose partial artifacts rather than deleting unknown files. |
| Prompt outcome unknown | Show uncertainty; explicit resend only. |
| Agent exit or crash | Keep available screen/exit state; restart or provider resume. |
| Folder moved | Locate directory or remove entry. |
| External branch/index changes | Refresh the checkout; discard stale diff results without changing user input. |
| Persisted metadata unavailable | Warn that current changes are unsaved; keep drafts in memory and allow retry. |

See [the acceptance matrix](acceptance.md) for the complete starting combinations and verification status.
