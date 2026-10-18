# User flows

Status: current product behavior. [Current status](status.md) records implementation and verification boundaries.

## Entry map

```text
Open Spookky
  Returning user -> restore the last open view
  Nothing open   -> retained landing composer, input focused
  Cmd+N          -> global landing draft
  Project +      -> project landing draft
                       |
                       +-- Optional prompt
                       +-- Provider chip: Codex or Claude Code
                       +-- Folder chip: Home, project or one-off folder
                       |      +-- Local by default
                       |      +-- Existing/new worktree, when chosen
                       +-- Start arrow / Cmd+Return -> real provider TUI
                       +-- Open Terminal -> plain shell, agent draft retained
```

The bottom composer is at most 800 points wide with 24-point outer padding. Provider and folder choices sit inside it. Selecting a provider, folder or source does not launch a process. Worktree controls stay in the folder/location popover. An empty prompt is valid. Enter inserts a newline.

First use selects Codex. New sessions then remember the last agent choice independently of shell launches. Restored drafts retain their saved provider and text. Once running, the provider's real TUI replaces the composer and owns subsequent input.

The global landing and each project landing retain separate drafts. Showing one creates no agent or history entry. Starting an agent promotes its draft into a session. Restoring state never launches every saved conversation. A plain Home shell requires no project or provider account.

## Keyboard and mouse contract

| Action | Result |
| --- | --- |
| Cmd+N / New session | Select the retained global landing draft and focus its composer. |
| Project row | Toggle its workspace rows without changing the selected workspace or stopping processes. |
| Project + | Select that project's retained landing draft, Local by default, and expand its group. |
| Cmd+T | Open and select a persisted browser supporting tab. Keep the primary CLI and draft. |
| Supporting + | Choose Browser, Files, Changes, Artifact or Terminal. |
| Cmd+Enter in launch composer | Launch selected tool with optional initial prompt. |
| Enter in initial prompt | Insert a newline. |
| Cmd+W | Close the focused supporting tab or session view. The last session returns to landing. On landing, close the window. |
| Close view | Contextual session action. Keep history, processes, files and branch. |
| Cmd+K | Focus the single history search field, including older uncached conversations. |
| Right-click / Shift+F10 on a sidebar entry | Open secondary contextual actions. |
| Double-click selected terminal tab | Rename its UI label. |
| Full view | Join the primary tab first and supporting tabs on one row. Selected content fills the area below. |
| Primary tab in Full view | Show the primary TUI full width. Keep supporting tabs visible. |
| Split view | Show the primary left and last selected support right. Retain split width and live state. |
| Panel toggle | Collapse/restore supporting content. Never start a process. |

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

Several conversations may use the same checkout. Each gets its own sidebar entry. Show the actual shared checkout scope. Discover worktrees made outside Spookky through Git metadata.

A selected repository subdirectory remains the conversation start directory. Checkout identity determines Files and Changes scope. It does not determine conversation identity.

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

Landing drafts are titled New session and stay outside ordinary session history. Agent launch promotes the draft to a named session. Existing friendly names and explicit aliases remain intact. Standalone shells keep a terminal label.

The first starting prompt supplied through Spookky's composer names the workspace once. Agent launches use a primary conversation workspace. Use the first nonempty line, collapse whitespace, and keep up to six words and 48 Unicode characters. The title is saved with accepted launch intent before process creation. Failures, retries, reconnects, and later prompts keep it. A manual rename always wins. Naming does not indicate prompt acknowledgment. Input typed directly in a CLI is not inspected.

Metadata upgrade replaces automatic New workspace and workspace-xxxxxxxx labels, where the suffix is eight hexadecimal characters. Other saved names and every manual name remain intact. Folder and branch names are independent of the visible workspace title.

The primary conversation supplies the row and primary header title unless an explicit local alias takes precedence. Supporting views retain content-type titles and icons. See [conversation names](conversation-titles.md).

The start page uses one bottom composer with provider and folder chips. The prompt is optional. With no prompt the Start arrow opens the selected CLI. With text it supplies that initial instruction. Cmd+Return launches from the composer. Open Terminal below starts a shell and preserves the agent draft.

Changing agents preserves the prompt draft. Opening a shell does not change the last agent choice. Shell launches never execute that text. Auth and permission prompts remain inside the provider CLI. Missing executables lead to guidance plus a working Terminal fallback.

Prompt state must distinguish pending, delivered, and uncertain. Process launch success alone does not prove delivery. An uncertain outcome must not automatically resend. An explicit resume does not silently receive a pending new-session prompt.

## Terminal-first and parallel work

```text
Home shell -> cd project -> run codex/claude -> use provider's own commands
                           |
                           +-- Open current folder as workspace (explicit)

Same files, another agent   -> Cmd+N -> same location -> choose tool
Separate edits             -> Cmd+N -> project -> New worktree
Different project          -> Cmd+N -> choose project
```

Supporting tabs inherit the session anchor. A foreground shell directory is separately observed when shell integration supports it. If directory detection is unavailable, avoid guessing it.

A supporting shell is explicit. Another UI-launched agent becomes a sibling workspace. Switching or collapsing UI never stops them. Provider-owned unsent input stays with the surviving process; a UI-owned launch draft is stored separately.

## Continue existing work

| Origin | Correct continuation |
| --- | --- |
| Live session owned by Spookky | Reattach the same process. |
| Saved local CLI conversation | Select it to resume its exact provider ID in the saved original folder. |
| Existing process in another terminal | Use supported native attach when available. A known Claude foreground owner blocks resume here. Unknown reporting allows ordinary native resume without claiming exclusive ownership. |
| Provider-supported cloud handoff | Use the documented CLI flow in a compatible, clean, dedicated checkout. |
| Cloud code branch without handoff | Fetch branch, open checkout, start a new CLI conversation with supplied context. |
| Mobile/web controlling local CLI | Return to that same local process while its owner is alive. |
| Other desktop app | Locate its checkout; use supported handoff or start with its files and explicit context. |
| Ordinary web chat | Select/create a project and paste useful context into a new CLI. |

Installed help determines resume, attach and optional handoff capabilities. Exact version numbers are not admission gates for continuation. See [ownership](provider-ownership.md) for the execution decision. Cross-provider conversion and universal imports remain unsupported.

Do not run a handoff that switches a branch in a checkout used by another active agent. A copied branch does not include conversation history, ignored files, secrets, or environment setup.

## Files and Changes

Files opens a searchable native picker within the workspace and reuses individual file tabs by path. Changes owns its change list and selected diff. Both use the checkout anchor.

- **Uncommitted:** separately show staged, unstaged, untracked, and conflicted paths. A path can have both staged and unstaged changes.
- **Against branch:** committed changes from the merge base of selected base and HEAD to HEAD. Label this comparison and the base. Outstanding working-tree edits remain in Uncommitted.
- Non-Git folders have Files and an explanatory Changes state.
- An unborn Git branch supports untracked/index changes; no committed comparison exists yet.
- Renames, deletions, binary content, symlinks, mode changes, submodules, conflicts, and large files need explicit representations.

Open a file or Changes beside the terminal, switch Full/Split layout, or close its tab. On narrow windows the preview uses available space and the overlaid file list dismisses after selection. A split-diff preference is retained while narrow views render unified content.

Commits, pushes, tests, and PRs happen through the user's preferred tools. Spookky never requires a review sequence.

## Close and return

| Event | Result |
| --- | --- |
| Switch tab/workspace | Preserve process and view state. |
| Close supporting tab | Select the nearest left support, otherwise the next support, otherwise primary. Retain any terminal backing record and process. |
| Close primary/workspace view | Retain history, primary terminal, drafts and support metadata. Select the most recently used already-open view, otherwise the landing composer. |
| Cmd+W on landing | Close the window. The landing tab itself has no close button. |
| Stop primary terminal | Confirm, verify runtime ownership, then terminate only that primary terminal. Retain history and supporting tabs. |
| Close window | Retain UI restore records and processes. |
| Quit with live sessions | Keep running and quit by default, Cancel, or explicitly End terminals and quit. The last choice ends all owned terminal sessions. Shared provider execution may continue. |
| Reopen with live owner | Reattach without launching or sending again. |
| Restart computer/runtime lost | Restore metadata; mark processes ended; offer explicit restart/resume. |
| Remove project | Unregister it; move retained workspaces to No project; keep files and sessions. |
| Delete app-created worktree | Separate action; check running processes, dirty/untracked work, and unmerged/unpushed commits. Confirm exact folder. Keep branch by default. |

Process continuity is subject to M0 validation. A saved conversation is not a surviving process. Hidden sessions still consume resources; never kill them only because their views are hidden.

View closure needs no termination confirmation. Stop uses a separate confirmation with Stop and Cancel. Reopening a retained entry reattaches its terminal without resending a prompt. First use shows the focused landing composer with direct shell access.

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
