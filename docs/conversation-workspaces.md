# Conversation workspaces

A retained thread owns one primary provider conversation or standalone shell. Supporting tabs contain Files, Changes, browser previews, artifacts and optional shells. Several sessions can share a checkout. Worktrees remain optional.

Provider history is a separate metadata catalog. Reading or expanding it creates no workspace terminal or agent. Selecting an entry creates or restores its workspace by provider plus session ID. See [history](session-history.md).

## Landing and navigation

With no selected thread, Spookky shows the centered composer immediately. It never leaves a blank page or a full-page New chat button. Cmd+N selects the viewed session's project draft, or the global draft without a project. Project + selects that project's draft. Each retains its provider, model, folder, text and images across navigation and restart. Inheritance seeds a new draft and never replaces a retained draft.

Starting an agent promotes its landing draft into a thread at accepted launch intent. Open Terminal starts a supporting shell and keeps the agent draft. Files and browser access require no agent. The landing tab has no close button; Cmd+W there closes the window normally.

The sidebar shows five history entries per project. Each thread keeps its position when selected or updated. New threads appear above older threads in their project. Dragging a thread within its project saves a new position. Show more requests ten more. Collapsing a project resets its history page to five for the next expansion. Other projects keep their page counts. Search starts with ten results and can request older uncached history. Search results use saved thread order. Rows use one 32-point title line, provider marks and actionable attention indicators. Paths and detailed status stay in tooltips and accessibility labels. Local aliases win over provider titles.

Closing a supporting tab selects its nearest left neighbor, then its next neighbor, then primary. The primary conversation has no close action. Cmd+W there closes the window and retains selection, drafts, supporting metadata and owned processes. Stop remains a separate action. Pin, archive and project assignment are local preferences. Pinned and Projects navigate the same identity. See [persistent threads](persistent-threads.md).

## Layout and supporting tools

Split places the primary header left and supporting tabs right on one 40-point row, aligned with the divider. Full view joins the primary first and every supporting tab into one scrollable row. Tabs have bounded widths. Selecting the primary keeps support tabs visible. Returning to Split restores the retained divider width and last support.

Supporting + and Cmd+T open a New tab page with address/search, Changes, Files, Terminal and Open artifact. Files opens a searchable native workspace file picker and reuses an existing file tab for the same path. Changes owns its change list and selected diff. Plain file tabs show file content without another Files/Changes mode switch. Tab controls own closure and layout.

Files and Changes use the workspace anchor. A shell's `cd` does not change that scope. Browser and artifact views materialize on selection. Live switching retains their views and form state. Unsent web input is not persisted across an app or WebKit restart. See [preview limits](supporting-previews.md).

## Identity and migration

Provider plus session ID identifies a conversation. Primary titles, icons and activity do not follow supporting focus. A provider-native conversation switch can move a live terminal to its new identity while retaining the previous entry's history, alias and supporting state. Conflicting ownership remains explicit. See [titles](conversation-titles.md).

Metadata version 7 stores requested history metadata separately from workspace snapshots. Migration extracts imported placeholders and preserves user-created sessions, terminal IDs, bindings, drafts, aliases, launch receipts and supporting views. The pre-migration database backup and transactional conversion do not run or stop a process. Version 8 adds local thread presentation preferences and repairs landing status with a consistent pre-v8 backup. Existing browser targets and supporting context remain intact. Version 6's earlier multi-agent split remains part of the upgrade path.

## Continuation

Selection first reconciles an exact known owned binding. A surviving terminal reattaches. Otherwise native capabilities and provider ownership determine exact-ID resume or background attach. No initial prompt is resent. Claude uses ordinary resume when reporting is absent, while a known interactive owner blocks and a supported background owner uses native attach. Native resume does not establish exclusive Claude ownership.

One preflight operation owns a conversation. Repeated clicks join it. Leaving during preflight cancels an unstarted launch. Errors stay with the affected conversation. Continue elsewhere always targets the primary. See [continuation](session-continuation.md) and [ownership](provider-ownership.md).

Codex and Claude Code are included. OpenCode is deferred. Provider authentication, permissions, input and transcripts remain in the real TUI. Verification and remaining runtime gates are recorded in [status](status.md).
