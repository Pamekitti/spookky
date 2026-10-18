# Conversation workspaces

Each sidebar entry owns one primary provider conversation or a standalone shell. Its supporting panel contains files, Changes, browser previews, local artifacts and optional shells. Several conversations can share a checkout. Creating a worktree remains optional.

New session in the sidebar, project + and Cmd+N create independent conversation drafts. Open Terminal starts a plain shell. Cmd+T creates a browser tab. Cmd+W closes the focused supporting tab or hides the primary workspace view. Hiding a view keeps its terminal process and saved metadata. Stop primary terminal and End terminals and quit affect only owned terminal sessions. Provider work on a shared server may continue.

## History and identity

Local Codex and Claude Code history appears directly in the sidebar. Startup, app activation, project changes and explicit refresh reconcile metadata. Refreshes coalesce and use a 30-second cache. They do not launch saved conversations. The initial list creates at most 50 rows plus the selected workspace. Show more expands it. Search covers retained history, including entries outside that page.

Provider plus session ID identifies a conversation. Provider titles and icons follow the primary conversation. Local aliases take precedence. Supporting selection does not change the conversation's identity, title or activity. See [history](session-history.md), [titles](conversation-titles.md) and [project association](project-association.md).

A provider-native conversation switch can keep the same terminal process. When a hook reports a new identity, the live terminal and its binding move to that conversation. The previous entry retains its alias, draft, supporting state and history metadata. A compatible saved destination is reused. An unsent destination draft gets its own draft entry. Conflicting ownership or unresolved checkout state remains explicit. Background events do not move focus away from a supporting form.

## Layout and startup

Split view places the primary conversation header left and the supporting tab group right on the same 40-point row. Their boundary follows the divider. Full view joins the primary tab first and every supporting tab on one row. The selected content fills the area below. Selecting the primary in Full view keeps the supporting tabs visible. Returning to Split restores the primary TUI left and the last support right, with the same split width, cached views, drafts and processes.

Supporting + offers Browser, Files & Changes, Artifact and Terminal. Closing a supporting tab selects the nearest left support, then the next support, then primary. Closing the primary hides the session view and preserves history and owned processes.

The startup area is mostly empty above a bottom composer. Its maximum width is 800 points with 24-point outer padding. Provider and folder chips sit inside the composer beside the Start arrow. The prompt is optional. Enter adds a newline and Cmd+Return starts the selected agent. First use selects Codex. Later New session drafts remember the last agent independently of shells. Existing drafts stay unchanged. Local is the default folder mode. Worktree source and branch controls stay in the location popover.

Open Terminal below starts a plain shell and retains the agent draft. Once a process starts, its real terminal replaces the startup composer. Provider authentication, input, permissions and transcripts remain in the provider TUI.

## Supporting views

Files and Changes remain scoped to the workspace anchor. A shell's `cd` does not change that scope. Activated HTTP(S) terminal links open a browser under the terminal's owning workspace. Supported local artifact links open a preview. In-scope source files open in Files. Other locations retain external opening.

Each file tab retains its own preview and comparison context. A source file and a diff of the same path can remain separate tabs. Selecting one loads its content without changing another tab's selection or comparison base.

Browser and artifact views materialize on selection. Switching tabs or hiding a conversation retains their live view state. Closing a supporting shell hides its view and keeps its process available from the supporting menu. Browser and HTML form state survives live switching, but does not persist across an app or WebKit process restart. See [preview formats and limits](supporting-previews.md).

## Migration and continuation

Metadata version 6 migrates existing multi-agent workspaces into sibling conversation entries. It keeps terminal IDs, bindings, drafts and launch receipts. Migration makes a backup and commits the new metadata atomically. It does not start or stop a process.

Opening saved history first checks an owned binding. A surviving process reconnects without another launch or initial prompt. Exact-ID resume uses the saved provider cwd and provider-specific ownership checks. Claude's ordinary resume does not establish exclusive ownership, so uncertain cases require provider-native guidance. Continue elsewhere targets the primary even when a supporting view has focus. See [continuation](session-continuation.md) and [ownership evidence](provider-ownership.md).

Codex and Claude Code are implemented in this batch. OpenCode is deferred. Browser automation, cloud execution, scheduling and integrations are outside this workspace change. Real provider input, authentication, permissions and transcripts remain provider-owned.
