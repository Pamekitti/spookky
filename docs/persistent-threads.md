# Persistent threads

A conversation is a saved thread that the user selects. Thread navigation does not expose an open or closed state. The primary conversation has no close button. Supporting views and provider execution have separate lifetimes.

## Navigation and landing

New chat and Cmd+N select the retained global composer. Project + selects that project's composer. Draft text, provider and folder survive navigation. An ended terminal status cannot replace the landing composer. A landing record that already owns execution becomes a retained thread; its draft is copied into a new landing record without relaunching the process.

Thread back and forward navigation retains up to 64 destinations in the current window. Selecting a saved conversation uses exact-ID continuation only when needed. A surviving owned process reattaches. Navigation never submits a draft or launches another thread as a side effect.

Pinned, Projects and Recents refer to shared thread identities. Their first page contains five entries; Show more adds ten. Project collapse resets that project's history page. Selection highlights the occurrence used for navigation. Unknown activity remains quiet.

Pinning, archiving and project assignment are local presentation preferences. Archive removes a thread from ordinary navigation and selects landing if necessary. It never deletes provider history or stops execution. View > Archived threads exposes Unarchive. Explicit local project assignments survive provider metadata refresh.

## Header and supporting tools

Split keeps the conversation heading over the TUI and supporting tabs over the right pane. Full puts the non-closable Conversation tab first on the shared row. Selected supporting content fills the workspace. Returning to Conversation restores the real TUI. No replacement floating input editor is introduced.

Supporting + and Cmd+T create a themed New tab page. It offers an address/search field, Changes, Files, Terminal and Open artifact. Submitted search text uses DuckDuckGo. File selection and URL navigation can replace the start page in the same supporting tab.

Cmd+P opens a searchable native workspace file picker. Folder navigation and bounded search run through the existing file service. Files outside the workspace and repository internals remain unavailable. Selecting an already-open file reuses its tab.

Changes has independent review state, Uncommitted and Against branch scopes, tracked-line totals and unified/split diffs. Its file tree sits on the right. No changes must clear stale file selection. Ordinary file tabs retain their own context. Last-turn comparison is not offered without reliable turn snapshots.

Markdown artifacts render as read-only headings, lists, tables, links and code using Foundation's Markdown parser. Rendered text is escaped. JavaScript and remote resources are disabled for Markdown. External links require the existing explicit external-open action.

Thread details contains the project folder, branch, provider, known activity and artifact links. Provider indexing notices appear once there rather than replacing every project's Show more row.

## Closing and execution

Closing an active supporting tab selects its nearest left neighbor, then the right neighbor, then Conversation. Closing an inactive tab preserves selection and focus. Closing the last support returns to the same conversation.

Cmd+W on the conversation closes the window. Thread selection, metadata and execution remain. Window reopening restores the selected thread. Stop primary terminal remains a separate ownership-checked action. Native quit retains its explicit running-terminal choices.

The hidden sidebar has no per-conversation icon rail. Its restore control remains available. Project avatars, provider marks, resizing, application zoom and terminal appearance following remain supported.

## Persistence

Version 8 adds optional local thread presentation metadata and repairs landing state. Migration makes a consistent pre-v8 database backup. Legacy hidden views become available threads, not archived conversations. Stable IDs, aliases, bindings, launch intents, drafts and supporting state are preserved.

Browser forms and scroll survive in-process view switching. Persisted browser URLs and website-managed storage restore after restart. Quit warns when browser tabs exist because unsent forms may be lost. Spookky does not collect or persist form fields.

## Recovery and responsive presentation

New tab lists Reopen terminal actions for retained terminal records whose views were closed. Reopening uses the same backing record and never launches a replacement shell. Stop remains separate.

Split temporarily uses Full when the workspace cannot fit two 320-point panes at the current app zoom. Widening restores the requested Split layout and selection. Native file rows fit the effective font metrics. Rendered Markdown uses an 80-character reading column.

Fresh Claude launches use an explicit UUID when installed help advertises `--session-id`. Codex's native completion notification supplies exact identity independently of activity hooks. Spookky forwards the user's existing notification command unchanged, stores at most eight candidate IDs per owned binding, and confirms CLI source and folder through read-only provider listing before association. No prompt or notification text is stored. Before the first native notification, identity may remain unknown. Failed metadata access does not guess an identity or weaken hook trust.
