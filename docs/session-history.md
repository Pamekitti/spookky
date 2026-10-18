# Saved conversation sidebar

Saved local Codex and Claude Code conversations appear directly under their projects. The sidebar initially renders 50 entries and includes the selected workspace when it falls outside that page. Show more adds 50 entries. Search matches every retained title, saved directory, and provider session ID, including entries outside the current page. Closed conversation views remain in this list. Search temporarily reveals matching rows in collapsed projects without changing their saved collapse state.

Startup, app activation, and project registration request a bounded refresh. Requests coalesce and reuse a 30-second metadata cache. View → Refresh conversations bypasses that cache. Ordinary native benchmark fixtures inject an empty catalog. The history fixture injects 600 synthetic conversations and a fake CLI. Neither reads real histories or starts real provider metadata servers.

Conversation identity is provider plus session ID. Several conversations may share one checkout. The provider project ID, registered Spookky project, saved cwd, terminal backing ID, and process binding remain separate. Grouping's batch resolver discovers registered roots and unique saved directories once per refresh. A resume performs fresh action-time resolution.

Refresh creates metadata-only closed-view workspaces through the non-selecting foundation API. It never launches a CLI or changes selection, collapsed projects, closed views, aliases, launch drafts, supporting targets, or existing process bindings. Reconciliation prepares value metadata off the UI thread. A changed state or refresh generation rejects the result. Three conflicting preparations defer refresh with a visible retry notice.

Provider title metadata updates the non-custom workspace fallback. A partial Claude head/tail scan cannot erase an earlier observed title. A newly observed rename supersedes it. The retained metadata cache carries that title across app restart. This cache contains no transcript or prompt body.

## Explicit continuation

Selecting a saved row first reconciles an exact known owned binding. A running primary reconnects to the same process. Repeated selection, closing a view, and reopening do not create another execution. An ended primary can explicitly resume with a fresh intent after ownership assessment. Its old launch draft remains stored. Resume arguments contain only the exact provider ID and saved cwd, with no new prompt or fork flag. Pending or uncertain delivery is not retried.

Handoff's ProviderOwnershipCheck supplies the execution decision. Codex native writer arbitration is enabled only for verified CLI 0.162.1. Other selected builds remain conservative. Claude Code 2.1.302 provides positive per-session ownership metadata, but ordinary resume did not prevent a second foreground writer in the sibling fixture. Missing ownership evidence therefore does not authorize automatic Claude resume. Existing Spookky-owned Claude processes can reconnect. External Claude conversations remain listed with an ownership explanation when automatic resume is unavailable.

Missing folders, unavailable history, ambiguous ownership, provider failures, and refresh limits are explicit. Failed or partial refreshes never remove retained conversations. A complete successful provider inventory can mark an absent record unavailable. It still retains its identity and metadata.

## Provider and resource bounds

Codex uses installed app-server thread/list with database-only reads. It lists indexed, nonarchived main local conversations, including externally created app-server/Desktop-style history. Unindexed legacy records, archived conversations, child agents, and cloud-only history are excluded. No thread resume or turn request is sent while listing. Provider-owned startup/log maintenance may occur. Spookky performs no direct provider database writes.

Claude's isolated local Code adapter reads UUID session metadata from bounded file heads and tails. Its version-dependent format has synthetic coverage. Claude Desktop Code and cloud-only history are not included.

The catalog has no polling timer, permanent helper, model SDK, or transcript store. Codex reads at most 5,000 rows in 100-row pages within 12 seconds. JSON-RPC responses have a 4 MiB buffer threshold and a 64 MiB aggregate threshold. Claude enumerates at most 5,000 top-level session files within four seconds. Changed files read at most 32 KiB from each end. Unchanged size/mtime records reuse metadata. A limit produces a visible partial-refresh notice. All retained entries remain searchable.

Project association uses the shared batch helper with a 10-second cooperative deadline, 256-project limit, 4096 unique-directory limit, and 16,384 input-row limit. At the deadline it cancels remaining Git reads and retains resolved display metadata. All provider history rows remain available; unresolved folders show a partial-refresh notice and require fresh action-time checks. Caller cancellation and invalid batch limits leave workspace data unchanged. Native row controls remain bounded by the revealed page rather than catalog size. First ingestion and refresh still have CPU and metadata-memory costs, even though preparation runs off the UI thread.

## Verification

```sh
swift test --jobs 2 --filter 'SessionCatalogTests|HistoryResumeTests|ConversationCatalogReconcilerTests'
python3 scripts/check_session_history.py --binary DerivedData/Build/Products/Debug/Spookky.app/Contents/MacOS/Spookky --output .cache/history-check.json
```

Add `--background` to the native fixture for programmatic checks behind user windows. It excludes physical input verification. Foreground checks require the shared GUI lock.

The installed metadata check uses a disposable provider root and unreachable loopback model endpoint. No model service is called. The separate inventory prints counts and elapsed time only:

```sh
SPOOKKY_HISTORY_CODEX="$(command -v codex)" swift test --jobs 2 --filter testInstalledCodexExternalMetadataLifecycleWhenRequested
SPOOKKY_HISTORY_INVENTORY="$(command -v codex)" swift test --jobs 2 --filter testRepresentativeMetadataInventoryWhenRequested
```

The native fixture checks 600 saved entries, bounded rows, Show more, and row reuse. Search covers entries outside the recent page and inside collapsed projects. Refresh preserves selection, aliases, drafts, closed views, and support metadata. Continuation checks exact ID/cwd, one live owned process, known-ended resume, and retained unsent terminal input. Its provider is fake. Browser/artifact rendering belongs to the separate supporting-content host and is not established by this fixture.

The initial read-only inventory found 428 Codex and 65 Claude Code conversations. Codex took 489 ms; Claude took 119 ms cold and 5 ms warm. Neither configured bound was reached. These are single local samples. They exclude terminal rendering, WebKit, provider runtime memory, and total user-session costs. Revised Debug value reconciliation for 600 records took about one second in a concurrent-build sample. Preparation runs off the main UI thread. This does not establish the combined switch, echo, idle CPU, or release performance targets.

Sources: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude local metadata reads](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser). The ignored handoff records exact current test logs and native evidence.
