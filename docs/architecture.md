# Native architecture

Status: implemented development stack, with compatibility and release gates pending. Product behavior is settled in [product](product.md) and [flows](flows.md). [Current status](status.md) records the pinned terminal build and current evidence. Production persistence, supported OS versions, and runtime adoption remain gated.

Projects, worktrees, and starting prompts remain optional. Delivery operations stay in the CLI or external tools.

## Technology direction

| Part | Direction | Evidence still needed |
| --- | --- | --- |
| UI | Swift with AppKit; small SwiftUI forms where useful | Native focus, layout, accessibility, supported OS target |
| Terminal | Reuse the full native Ghostty surface at a pinned revision | Build, input, rendering, clipboard, embedding API, distribution |
| Live session owner | Bundled tmux on a private socket | Both real CLIs, scrollback, reattach, job detection, runtime packaging |
| Metadata | SQLite with pinned GRDB 7.11.1 | Validate persistence and recovery across supported OS versions |
| Git | Installed Git, launched with argument arrays | Repo discovery, cancellable reads, worktree writes, fixtures |
| File/diff views | Virtualized AppKit views with bounded content | Large-file memory, syntax/diff rendering, accessibility |
| Distribution | Signed/notarized direct-download macOS app | Signing, runtime packaging, Sparkle update integration and signed delivery |

Rust is optional, not a product requirement. Do not introduce a second language without a measured or integration-driven reason. The HTML is a design prototype and is not the selected production frontend.

Ghostty documents a Swift/AppKit/SwiftUI macOS UI that consumes its shared terminal core. Full embedding must be tested at an exact revision; a terminal-state library alone does not supply a finished native view. [Ghostty architecture](https://ghostty.org/docs/about), [upstream source](https://github.com/ghostty-org/ghostty).

Tmux can own sessions independently of attached clients. Spookky packages it on a private socket. Compatibility, resource, and extended input checks remain release gates. [tmux session and attachment model](https://github.com/tmux/tmux/wiki/Getting-Started).

## Module boundaries

```text
Native UI: sidebar | tabs | start form | files/diff | settings
   |                  |                     |
   v                  v                     v
Workspace store   Terminal surface       File/Diff controller
   |                  |                     |
   |              Terminal engine           +--> Git read queue
   |                  |                     +--> File watcher
   v                  v                     +--> Bounded preview cache
Launch coordinator -> Session owner
   |                  |
   +--> Git writer    +--> inner PTY -> shell / Codex / Claude Code
   |
   +--> SQLite metadata and operation receipts
```

Terminal bytes stay within the terminal stack. The UI state receives tab IDs, process presence, exit status, and optional activity hints. Do not convert terminal output into message objects or publish every byte through the app's observable model.

The launch coordinator, Git services, and persistence are app modules. A separate custom workspace server is not justified at this stage. If tmux fails the technical gate, document an alternative process owner before building on it.

## Records

| Record | Key fields |
| --- | --- |
| Project | Stable ID, name, registered directory ID, preferred source reference, last-used time |
| Directory/Checkout | Stable ID, canonical path, selected path, Git common-dir identity, worktree identity, current branch, kind, ownership, availability |
| Workspace | Stable ID, nullable anchor ID, conversation ID, primary terminal ID, alias, landing context, supporting panel and closed-view state |
| ConversationCatalogRecord | Provider/session key, metadata, project association, local alias and optional retained workspace/terminal IDs |
| SupportingTab | Stable ID, content target, title, optional file/comparison view state |
| LaunchDraft | Workspace/tab ID, selected project/location/mode/ref, branch mode/name, tool, optional prompt |
| TerminalTab | Stable ID, workspace ID, tool, title, launch ID, process-binding ID, last observed cwd, optional provider-session ID, status |
| ProcessBinding | Owner identity, session/window/pane IDs, creation token, process identity, attachment state |
| LaunchOperation | Stable operation ID, target directory, phases, completed receipts, failure, prompt-delivery state |
| ViewState | Sidebars, selected tab/file, diff mode, comparison base, split layout, scroll anchors |
| DiffSnapshot | Checkout ID, generation, source commits, index/worktree fingerprints, file metadata, bounded selected content |

Model plain folders, unborn repositories, regular checkouts, existing worktrees, and remote refs explicitly. A remote ref is a source for a checkout, never itself a workspace directory.

Use stable IDs for relationships. Names, array indices, PIDs, and paths alone are insufficient identity. Store directory identity so a symlink alias or repo subdirectory does not accidentally create a second isolated-looking workspace for the same checkout.

Metadata version 7 separates paged provider history from open workspace records. Its earlier version 6 layer separates conversation ownership from supporting content. File tabs retain their own selected path and comparison context. Selecting a tab updates the existing native file controller's data without changing checkout scope or terminal ownership. Older descriptors without this optional context use the workspace's retained file state. Migration backs up the database and preserves terminal bindings and drafts. See [conversation workspaces](conversation-workspaces.md).

Metadata version 5 adds optional automatic-title provenance (friendly, prompt, or legacy) beside the manual-title flag. New workspace names use a fixed local word collection. A bounded scan of the composer prompt derives a title during the accepted launch-intent transition, without a model request or terminal inspection. Binding a folder does not overwrite the title. The first prompt title freezes automatic naming; manual names take precedence.

The version 4 migration backs up older metadata before updating it. It replaces only automatic generic titles and preserves readable legacy names, manual names, stable IDs, drafts, and runtime bindings. It does not infer old task titles from saved provider history or start processes.

## Launch transaction

```text
Draft
  -> Validate location/tool intent
  -> Resolve or register target
  -> [Fetch source] -> [Create worktree]
  -> Bind workspace to checkout
  -> Start process under session owner
  -> Attach terminal surface
  -> [Deliver optional initial prompt]
  -> Running

Failure at any step -> retain draft + completed receipts -> retry failed step
```

1. Capture an immutable launch request with an operation ID. Persist intent before external side effects.
2. Resolve canonical checkout scope. Conversation workspace identity remains separate. Several conversations may share this scope.
3. For a new worktree, reserve path/name and resolve the source to a commit. Serialize app-owned Git writes by common repository.
4. After each step, record observed results. A canceled fetch differs from a completed checkout followed by a launch failure.
5. Start the exact executable with arguments as data, in the chosen directory. Provider login remains in its terminal.
6. Record the process owner binding and revalidate it before attachment or retry. Reconcile an uncertain start before creating another process.
7. Supply the optional prompt through a version-tested supported CLI launch mechanism. Persist pending/delivered/uncertain state. Never infer acknowledgment from a successful write alone.

Retries preserve successful worktree creation. Partial cancellation does not delete arbitrary files. A confirmed process exists independently of the current view.

## Session ownership and lifecycle

If adopted, each terminal tab gets a dedicated private tmux session with one window/pane. This avoids multiple attached clients accidentally sharing current-window selection. The native split UI combines independent terminal surfaces.

Use an app-specific socket/configuration and a user-only runtime directory. Never operate on the user's default tmux server. Separate development, testing, and release labels/data roots. Store owner session IDs and creation tokens; do not kill by title or unverified recycled PID.

| Owner | Responsibility |
| --- | --- |
| Terminal engine | Parsing, drawing, native input, selection, fonts, frontend buffer |
| Session owner | Inner PTY, live process, screen/history sufficient for reattachment |
| Agent provider | Conversation history, credentials, permission prompts, tool execution |
| Spookky metadata | Projects, workspaces, launch drafts, bindings, UI layout, operation receipts |
| Git and filesystem | Actual files, refs, index, checkouts |

Closing a window or releasing a hidden view must not implicitly terminate the inner process. Supporting-tab and workspace-view closure retain terminal backing records. Stop is a separate ownership-checked operation. Reboot or session-owner failure ends live execution. Restore metadata and offer explicit restart/resume.

Do not silently terminate hidden agents to meet memory targets. Release rendering surfaces and derived caches instead. A reconnect never replays the starting command or prompt.

## Git and file service

- Discover roots, common Git directories, and worktrees with Git queries. Preserve subdirectory start intent separately.
- Read file metadata first. Load selected content on demand, off the main thread.
- Use porcelain/NUL-delimited output and argument arrays. Handle spaces, Unicode, unusual names, symlinks, deletions, and nested repositories deliberately.
- Uncommitted comparisons treat HEAD-to-index, index-to-worktree, and untracked content separately. An unborn repository uses the empty-tree concept where applicable.
- Against branch is a committed merge-base-to-HEAD comparison. Resolve and label the base; never silently combine it with working-tree edits.
- Coalesce filesystem invalidations. Tag reads with generations, cancel superseded work, and ignore stale results.
- A shared app lock cannot prevent changes from an agent or external Git process. Revalidate relevant refs/index/worktree fingerprints before accepting results or performing app writes.
- Keep worktree creation/deletion separate from file preview. No stage/commit/push service is required in v1.

Large and binary files use bounded previews and an explicit external-editor action. Detect conflicts and unsupported content without trying to resolve it automatically. A diff refresh must not steal focus or reset selection.

## Provider boundary

Adapters cover executable detection, launching, supported resume arguments, and optional lifecycle hints. Keep integration capability/version checks small. They do not own model requests or parse a provider's conversation into custom UI.

Native CLI resume, supported cloud handoff, and remote control can be used inside the terminal. Historical provider references are preserved in the archived flow document. Verify them against installed CLI versions before shipping convenience controls.

Do not mutate global agent configuration or overwrite user hooks. Activity hooks use per-invocation configuration and preserve existing hooks. Codex monitoring preserves the provider hook trust checks. Model approval and sandbox settings remain provider-owned. Unsupported activity detection shows unknown state. Standard CLI permissions remain usable with app hints disabled. See [agent activity](agent-activity.md).

## Persistence and recovery

M1 implements these boundaries in SpookkyCore, SpookkyWorkspace, SpookkyPersistence, and the AppKit presentation layer. Its v1 SQLite schema stores a validated metadata snapshot per transaction through pinned GRDB. WorkspaceStore shares one in-flight write across concurrent flush callers, then saves newer revisions in order. Launch intent is durable before SessionRuntime.create is called.

The AppKit surface manager retains at most three terminal surfaces: two visible plus one warm hidden, or up to two hidden when a full-width tool covers both terminal panes. Hidden panes keep their last geometry until shown. Stable selection generations reject late attachments. Terminal sizing is updated on native frame/backing-scale changes, with unchanged geometry skipped. Owner-backed scroll metadata and normal window geometry support restoration without storing transcripts. See [current status](status.md) for evidence and unresolved checks.

Use schema-versioned SQLite transactions, one serial writer, and a documented migration path. Back up metadata before destructive schema migration. A write failure produces a visible unsaved-state warning while retaining current drafts in memory.

Store launch drafts with full content rather than arbitrary 600-character truncation. Bound logs and derived caches separately. The prototype's 15,500-byte snapshot envelope is a host limitation, not the native storage design.

Store metadata and runtime references under Application Support. Keep actual worktrees in a user-visible directory. Do not duplicate provider credentials, full conversations, or all terminal transcripts. Native terminal input drafts belong to the running terminal and are not guaranteed recoverable after process loss.

On app startup, load metadata, reconcile process bindings and directory availability, then attach the selected view. Do not create a new workspace if a compatible saved state already exists. Show ended/unavailable states instead of guessing that a process or directory survived.

## Technical gates

| Risk | Required evidence |
| --- | --- |
| Full Ghostty embedding | Reproducible app build with real input and rendering on a pinned revision |
| tmux compatibility | Both CLIs, mouse/scrollback, selection, IME, resizing, alternate screen, paste and reconnect |
| Prompt delivery | Version-specific launch semantics; uncertain retry never silently resends |
| Background ownership | UI crash, quit, sleep, runtime failure, and reboot produce documented states |
| Git correctness | Temporary-repo fixtures for dirty/index/unborn/branch/worktree edge cases |
| Resource use | Measured app plus runtime costs at 1, 5, and 10 sessions |
| Accessibility | Native focus and VoiceOver behavior for chrome, files, diffs, and terminal |

The workspace and Git layers depend on the terminal integration. Complete its compatibility gates before calling the app ready for daily use. See [the build plan](build-plan.md).

## M2 implementation

SpookkyGit is now the discovery and cancellable Git boundary. LocationCoordinator prepares a checkout before LaunchCoordinator starts a terminal. Their receipts are separate. Metadata version 2 stores stable checkout identities, location drafts, immutable requests, and completed phases. Session observations include the current directory for deletion safety; terminal bytes remain outside metadata. See [M2 recovery](m2-recovery.md) for restart behavior and [current status](status.md) for evidence and remaining gates.

## M3 implementation

SpookkyFiles provides directory enumeration and bounded previews. SpookkyGit provides status snapshots and selected diffs through the existing read scheduler. FileWorkspaceController owns the active native file UI and its event watcher. WorkspaceWindowController composes it beside existing terminal surfaces. SQLite version 3 persists view metadata only. See [current status](status.md) for limits, migration, and verification.

## Agent activity implementation

AgentActivityResolver wraps executable resolution without changing LaunchCoordinator's process ownership. Private PATH wrappers also support manually entered CLI commands. Interactive zsh uses private startup delegates so user configuration can complete before the wrapper path is restored. AgentIntegration provides bounded capability detection and invocation configuration. The launch helper forwards bounded normalized hook events through AgentActivityReceiver's private datagram socket.

The receiver validates the binding, invocation, provider, and secret against private active registration. WorkspaceState applies events separately from terminal lifecycle and preserves completion acknowledgments. SQLite version 4 migrates the optional per-tab activity record with a pre-migration backup. AppKit renders the existing status slots and UserNotifications handles alerts. No terminal bytes enter this model. See [agent activity](agent-activity.md) for limits and recovery semantics.

## Session metadata and paged history, version 7

`ConversationCatalogRecord` stores requested provider metadata in a separate SQLite table keyed by provider plus session ID. Catalog rows contain no terminal, agent or transcript. Indexed page queries retrieve recent entries without decoding every workspace. Opening a row creates or restores its workspace by stable identity.

`HistoryQuery` carries project/folder filters, search text, a limit and a provider continuation cursor. `HistoryPage` returns metadata, another cursor and partial-result notices. `SessionCatalog` merges provider pages off the UI thread. `ConversationHistoryCatalog` resolves only the requested folders and persists those records. Filesystem observation requests debounced refreshes; activation and manual refresh recover missed events. See [history limits](session-history.md).

`landingContext` distinguishes one global draft and one per project. Landing drafts stay outside ordinary session rows. Starting an agent promotes the selected draft at launch intent. Supporting shells retain it. Closing the final session view selects landing; Cmd+W on landing closes the window. `lastViewedAt` selects among already-open views without resuming saved history.

Workspaces retain primary terminal UUIDs, optional conversation IDs, anchors, drafts, aliases and supporting state. Supporting targets identify Changes, individual files, browsers, artifacts or shell backing records. Full view selection remains distinct from the last selected support. The shared 40-point header reparents retained views when layout changes and never launches a process.

Version 7 migration extracts imported history placeholders into the catalog and preserves user-created records, bindings, launch receipts, drafts, aliases and supporting views. The database backup precedes migration. Catalog insertion and workspace conversion commit together. Earlier version 6 migration still splits legacy multi-agent workspaces while preserving terminal identity and location-operation ownership. No migration invokes the runtime.

`WorkspaceState.lastAgentTool` remains separate from shell preferences. Provider titles update stable identities while explicit local aliases take precedence. A provider-native identity change can move a live terminal to another conversation without losing the previous entry. Ambiguous ownership retains every terminal.

`ConversationExecutionCheck.prepare` returns a capability-based ownership assessment and exact native launch specification. LaunchCoordinator preserves and validates that specification. One operation owns each terminal through preflight and creation. Cancellation before durable intent restores the draft. After creation begins, receipt recording completes independently of view-task cancellation. Resume supplies no initial prompt or permission override.

`SupportingContentHost` caches views by supporting-tab ID, including hidden retained sessions. Changes owns its list and diff context. Plain file tabs show independent content without enumerating a file tree. Browser and artifact forms survive live switching, but unsent web input is not persisted across renderer or app restart.
