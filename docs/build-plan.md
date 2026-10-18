# Build plan

Spookky has a native terminal, workspace navigation, project and worktree operations, file and diff inspection, and metadata persistence. It is a development preview. [Current status](status.md) separates verification from remaining release gates.

## Implementation areas

| Area | Current state |
| --- | --- |
| Terminal foundation | Full native Ghostty surface and a private tmux runtime implemented; compatibility acceptance remains incomplete |
| Workspace shell | Retained global/project landing drafts, supporting tabs, Split/Full layout and restore implemented |
| Conversation workspaces | Paged metadata catalog, lazy workspace creation and version 7 migration implemented; revised combined native verification pending |
| Locations and worktrees | Local, existing folders, create/clone, source selection, and explicit worktree operations implemented |
| Files and changes | File tree, bounded previews, syntax colors, Git comparison scopes, and native diffs implemented |
| Continuity | Short crash/reopen and reattachment checks pass; extended continuity remains blocked |
| Distribution | Private local installation and signed release/update preparation implemented; signed delivery remains unverified |

## Next gates

1. Diagnose the failed overnight unsent-input preservation check and validate the correction with the full continuity workload.
2. Complete hands-on typing, IME composition, spoken VoiceOver, and terminal link/file activation checks.
3. Complete combined native workflow acceptance. Installed offline resume/attach checks pass for Codex CLI 0.163.0 and Claude Code 2.1.302; broader capability and provider-response coverage remains pending.
4. Exercise sleep, wake, reboot, and private-runtime failure with disposable sessions and recorded process identities.
5. Confirm supported macOS versions and reproducible installation. Package the runtime and required dependency notices before distributing an app.
6. Verify the signed release and update process in [the development lifecycle](lifecycle.md). Add CI only for commands that work on the chosen runner.

## Change acceptance

Use [acceptance](acceptance.md) and [performance](performance.md) to choose checks for each change. Verify native behavior with real terminals and disposable Git fixtures. The HTML prototype supplies a visual reference.

Preserve immediate shell access, drafts, process ownership, and workspace scope. Keep UI, scanning, Git operations, and persistence within the [architecture boundaries](architecture.md).

Publication of source is separate from release readiness. Original code, documentation, and artwork use the MIT license. Third-party attribution and licenses remain intact.
