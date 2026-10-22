# Saved conversation sidebar

Spookky shows five Codex and Claude Code conversations per project in saved order. New conversations enter above older ones. Provider updates and visits leave existing rows in place. Dragging within a project changes and saves that order. Show more requests ten more, repeatedly. Search starts with ten results and can request further pages, including history not previously cached. The selected conversation and open local sessions remain available without duplicate rows.

Each row has one title line, a provider mark and an indicator when attention is needed. Saved paths, full titles and detailed status remain in tooltips and accessibility labels. Titles stay still. A contextual menu supplies secondary actions.

## Metadata and workspace lifetimes

Provider plus session ID identifies a conversation. The persisted catalog stores its title, original folder, update time, project association and optional local alias. It contains no transcript, terminal surface or running agent. A catalog row creates or restores a workspace only when selected.

Startup displays cached recent metadata, then requests bounded provider pages. Project expansion, Show more and search read metadata without launching a conversation. Activation and debounced filesystem events request refreshes. Metadata pages reuse a 30-second cache. View → Refresh conversations bypasses it and also recovers changes missed by filesystem observation.

`HistoryQuery` carries project/folder filters, search text, page size and a continuation cursor. `HistoryPage` returns matching metadata, the next cursor and any partial-result notice. Codex and Claude pages merge by update time and stable provider/session identity. The query cache retains at most 64 pages.

`ConversationHistoryCatalog` persists requested metadata separately from workspace snapshots. Refresh preserves aliases, selected workspace, expanded page counts, project collapse, drafts, supporting targets and process bindings. Provider title changes update the same identity. Failed or partial reads retain cached entries. Worktree folders group under their registered project without replacing the saved start directory.

Metadata version 7 moves imported history placeholders into the catalog. User-created sessions, live bindings, aliases, drafts, supporting views and launch receipts remain workspace records. The database is backed up before migration. Catalog insertion and workspace conversion share one transaction.

## Continuation on selection

```text
Select conversation
  Known owned terminal alive -> reattach that process
  Saved conversation         -> check native capabilities and ownership
                                 -> exact-ID resume or native attach
                                 -> specific inline error when unavailable
```

Codex resume follows its advertised exact-ID interface. It does not require Remote Control. Claude uses ordinary exact-ID resume when no owner is reported or ownership reporting is unavailable. A positive interactive owner blocks that launch. A supported live background owner uses its exact registry attach ID. See [provider ownership](provider-ownership.md).

One pending operation owns each conversation. Repeated clicks join it. Leaving during preflight cancels an unstarted launch. Once durable launch intent is accepted, the coordinator finishes recording the owned result. Resume never supplies a new prompt, fork flag or permission override. Pending or uncertain initial prompt delivery is not retried.

Errors belong to the affected conversation. Missing folders, unavailable history and provider failures keep the original entry and its recovery action available. A provider refusal remains visible in its native terminal.

## Provider and resource bounds

Codex uses short-lived app-server connections and database-only `thread/list`. This may start a metadata helper, but never a conversation, turn or TUI. Listing supports indexed, nonarchived main local conversations, including externally created Desktop/app-server history. Unindexed legacy records, child agents and cloud-only history are outside this reader. Spookky never writes provider databases.

Codex uses provider cursors and available folder/title filters. Unsupported optional filters fall back to bounded local filtering. A page scans at most 200 provider rows within the connection's 12-second deadline. Responses retain the existing 4 MiB buffer and 64 MiB aggregate limits. Partial scans return a cursor for further requests.

Claude indexes file metadata for at most 20,000 top-level session files within four seconds. A page inspects at most 256 files within two seconds. Changed files read at most 32 KiB from each end; unchanged size/mtime records reuse metadata. This is a local Code format adapter, not Claude Desktop or cloud history support. No full transcript store is added.

Claude title records use native custom titles before AI titles and summaries. Explicit Spookky aliases remain authoritative. A fresh starting prompt supplies a bounded fallback title until native metadata arrives. Title refresh never changes the conversation ID or original folder.

Some Codex launches cannot report an exact saved identity before their first native completion. Their existing terminal remains usable. Spookky links history only after exact native identity evidence and never merges conversations by title or directory alone.

Project grouping resolves requested directories off the UI thread. Its cooperative 10-second deadline preserves resolved display metadata and reports partial association. Resume uses the provider's saved original folder. Native list views are virtualized; retained UI rows do not grow with the full catalog.

## Verification

```sh
swift test --jobs 2 --filter 'SessionCatalogTests|HistoryResumeTests|ConversationCatalogReconcilerTests|ProviderOwnershipTests'
python3 scripts/check_session_history.py --binary DerivedData/Build/Products/Release/Spookky.app/Contents/MacOS/Spookky --output .cache/history-check.json
```

The native history fixture uses synthetic metadata and a fake CLI. It must verify page expansion, older search results, selection preservation, bounded rows and zero conversation launches during discovery. Passing older fixtures does not establish the version 7 interface. Current results and remaining gates are recorded in [status](status.md).

Sources: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude local metadata reads](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser).
