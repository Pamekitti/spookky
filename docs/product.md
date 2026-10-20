# Product contract

Status: conversation-workspace direction accepted 17 October 2026; landing, paged history and tab workflow refined 18 October 2026. Product name: Spookky, adopted 12 October 2026.

## Purpose

Spookky aims to make parallel AI development fast to start, responsive to use, and economical with memory and CPU. It combines real CLI terminals with project organization, optional Git worktrees, and file/diff viewing.

The daily problem is keeping track of multiple sessions, their working directories, and the changes they produce. Users need that organization while keeping terminal input responsive and leaving resources for agents, builds, and other applications.

Spookky begins as a tool for daily personal use with a public development repository. Original Spookky code, documentation, and artwork are released under the MIT license. Its long-term identity is a compact, reliable workspace for this development loop. Feature selection must protect that identity as the project grows.

## Product commitments

| Commitment | What it requires |
| --- | --- |
| Speed is a requirement | Protect typing, switching, scrolling, startup, and diff responsiveness under realistic parallel workloads. Measure regressions. |
| Resource use is bounded | Limit rendering surfaces, retained buffers, caches, and background work. Count runtime helpers and total session costs honestly. |
| Starting is effortless | Preserve immediate shell access. Projects, worktrees, task names, and initial prompts remain optional. |
| Parallel work stays understandable | Show directory and checkout ownership. Distinguish shared files, isolated edits, live processes, and saved conversations. |
| Polish includes reliability | Preserve input and selection. Keep focus stable. Explain failures and retain completed work during recovery. |

Speed and low memory are requirements, not established results. Native implementation must provide the evidence described in [performance](performance.md).

### Feature decision rule

A proposed feature must address a concrete need in starting, organizing, doing, inspecting, or resuming CLI development. Describe the smallest useful interaction and the added background work, state, or dependencies. Verify the costs relevant to the change.

Defer features whose maintenance or resource cost undermines this daily loop. Do not expand scope merely to match another product's feature list. Performance improvements must preserve user work and session continuity.

Public positioning should explain these needs and outcomes without competitor comparisons. Name supported integrations in compatibility sections and dependencies in technical/provenance documentation. Preserve required attribution.

## Intended users

- A terminal user who wants immediate shell access plus project and worktree organization.
- A developer using multiple agent CLIs concurrently, either in shared files or separate checkouts.
- A user returning to saved CLI history or a provider-supported cloud/local continuation.
- A user who wants polished desktop navigation while keeping the CLI interface and its controls.

V1 is a local macOS desktop application for one OS user. Apple Silicon is the initial development target. The exact minimum macOS version remains a dependency/build decision. Windows, Linux, and a Spookky mobile client are outside the first release.

## Vocabulary and ownership

| Concept | Meaning |
| --- | --- |
| Project | A registered folder or repository. It can be non-Git. |
| Checkout | A concrete Git working directory, including the original checkout or a worktree. |
| Session | User-facing sidebar entry for one primary conversation or standalone shell, its anchor and supporting tabs. |
| Workspace | Internal record for an open or retained session. Several sessions may share a checkout. |
| History catalog | Provider metadata keyed by provider and session ID, independent of terminals and workspaces. |
| Landing | Retained global or project draft shown whenever no session view is selected. |
| Tab | A supporting file, Changes, browser, artifact, or optional shell view. Terminal backing records retain stable process IDs and drafts. |
| Split view | Primary TUI on the left and the last selected supporting view on the right, beneath aligned headers. |
| Full view | Primary tab first and supporting tabs on one row; selected content fills the area below. |
| Starting reference | A commit source such as HEAD, local dev, or origin/dev. |
| Working branch | The branch checked out in the selected or new worktree. |
| Initial prompt | Optional input for a fresh agent launch. Never a shell command. |
| Resume | Start a CLI with provider-owned saved conversation history. |
| Reattach | Connect a view to the same surviving process. |

Use New chat in the UI. Existing workspace type and persistence names remain internal implementation terms. Do not revert to a task model that requires a worktree, task title, or primary agent.

## Included in v1

| Area | Contract |
| --- | --- |
| Immediate start | With no open view, show the composer. Cmd+N selects the current project's draft, otherwise global; project + selects its project draft. Start promotes it into a session. Open Terminal retains the agent draft. Cmd+T opens a supporting browser. |
| Projects | Register an existing folder, clone a repository, or create a folder with optional Git initialization. |
| Locations | Home, one-off folder, Local checkout, existing worktree, or new worktree. |
| Worktrees | Explicit source and optional working branch name. Generated branch names are allowed. |
| Terminals | Real shell, Codex CLI, and Claude Code CLI; optional initial agent prompt. |
| Parallel work | Each UI-launched agent gets a sibling sidebar workspace. Supporting + opens Browser, Files, Changes, Artifact or Terminal. Split and Full view retain live views and drafts. |
| Agent attention | Provider-reported activity, unread completions, workspace rollups, and optional native notifications. See [agent activity](agent-activity.md). |
| Navigation | Single-line project history, five recent entries and repeated ten-entry expansion, one search field, contextual actions and a collapsible icon rail. |
| File inspection | Full file tree, file search, read-only preview, external-editor action. |
| Change inspection | Uncommitted groups and committed comparison against a selected branch; unified/split diff. |
| Recovery | Clear launch errors, retained successful worktree creation, reconnect, ended sessions, explicit resume. |
| Lifecycle | Safe close behavior, explicit background continuation, metadata restore after restart. |
| Polish | Stable keyboard focus, tooltips, native appearance, readable density, accessibility, and bounded resource use. |

First use selects Codex with Default model. New drafts inherit the viewed primary provider and recorded model, with last-used choices as fallback. A fresh project draft defaults to its registered Local checkout. Existing drafts keep their provider, model, location, text and images.

Both agent CLIs use their own credentials, configuration, permissions, model controls, and conversation histories. Spookky does not require its own account. A shell works without either agent installed.

## Excluded from v1

- Custom chat rendering, model APIs, prompt orchestration, or an agent SDK protocol.
- Automation, schedules, tasks, team accounts, plugins, or browser automation.
- Mandatory worktrees, mandatory starting prompts, or required workspace naming.
- A bottom shell opened by a layout button, or an extra global top bar.
- Inline review comments, viewed-file checklists, staging/commit forms, and PR creation UI.
- Automatic project setup scripts, dependency installation, or remote synchronization.
- A full editor, universal session import, cloud execution, or a Spookky mobile app.
- OpenCode integration in this batch. Codex and Claude Code are the supported agent choices.

Testing, staging, commits, pushes, and PRs remain available through the user's CLI, agent, or external tools. The app refreshes the resulting Git state.

## Non-negotiable behavior

1. Local keeps the current branch and existing edits untouched.
2. New worktree is an explicit choice. It does not copy dirty source files or merge itself back later.
3. Conversations that share a checkout share files. Worktrees isolate edits, not ports, credentials, databases, or services.
4. A shell's directory change does not repoint the workspace. An explicit action can open that directory as another workspace.
5. Conversation identity is provider plus session ID. Several conversation workspaces may share one checkout. Drafts and standalone shells have optional conversation identity.
6. Threads are persistent navigation destinations. Supporting views close independently. Cmd+W on the primary closes the window and retains thread metadata and processes. Stop primary terminal is separate and confirmed. Shared provider execution may continue. Worktree deletion is separate.
7. Switching views never starts an extra agent, drops a draft, or resends a prompt.
8. Capability-based continuation preserves exact IDs and original folders. Native resume does not establish exclusive Claude ownership. Remote control and cloud copies are described honestly.

## What success means

A user can open a shell immediately, create an isolated agent workspace when needed, switch among several sessions without losing input, and inspect changes without leaving the app. The native implementation must prove responsiveness and memory behavior on a 16 GB Mac.

The HTML prototype establishes appearance and interaction examples. It does not prove native performance or provider compatibility. See [performance](performance.md) and [acceptance](acceptance.md).

The current native thread and supporting-tool behavior is specified in [persistent threads](persistent-threads.md).
