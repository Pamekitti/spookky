# Primary conversation names and provider marks

Each sidebar row owns one primary conversation. Its title and provider stay the same while supporting file, Changes, browser, artifact, and shell views change. Another agent belongs in a sibling row. Conversations may share a checkout. Display naming never renames folders or branches.

An explicit workspace alias wins. A migrated primary terminal alias wins when the workspace has no explicit alias. Otherwise the current provider title supplies the row and primary header name. Missing titles reveal the saved fallback. Supporting tabs use content-type icons and content titles. They do not supply the row's identity or activity. Supporting shell aliases stay literal, including names such as Codex or New tab.

`Workspace.conversationID` identifies the provider conversation. `primaryTerminalID` identifies its terminal backing record. The optional primary-terminal title cache stores display metadata. It does not create a catalog, inspect transcripts, infer ownership, or launch a process. Existing snapshots without that cache still decode. Foundation's versioned migration preserves aliases, terminal IDs, drafts, launch intent, and bindings.

History can use the existing `setProviderTitle(_:conversationID:)` setter. It delegates to `updateConversationTitle(provider:sessionID:title:)`. Matching requires the canonical conversation ID and its primary terminal. Codex and Claude title updates require valid UUID session IDs. Observed session changes discard stale cached titles. An update for another provider or conversation cannot rename a row. Failed or truncated catalog refreshes should leave omitted rows intact.

`associateConversation(provider:sessionID:title:workspaceID:)` associates an unbound workspace and caches the selected title without launching or fabricating activity. Existing canonical associations cannot be reassigned through that helper. Foundation's observed-identity and migration operations retain their authority.

Codex uses the OpenAI mark. Claude Code uses the Claude mark. Native template tinting preserves contrast in both themes. Plain shells retain the terminal glyph. Activity appears in labeled metadata and separate status indicators. Collapsed rows keep a status badge beside the provider mark. See [attribution](../THIRD_PARTY.md).

The native fixture uses two disposable shells and synthetic provider metadata. It checks primary input, process identity, focus, header refresh, supporting-view selection, retained receipts, aliases, and both themes at desktop and narrow widths. Browser selection uses the supporting content-host fallback. It does not prove browser rendering, form persistence, live provider discovery, spoken VoiceOver, or physical keyboard use.

```sh
swift test --jobs 2 --filter 'ConversationTitleTests|ConversationWorkspaceTests|AgentActivityTests'
python3 scripts/check_conversation_identity.py --background --binary DerivedData/Build/Products/Debug/Spookky.app/Contents/MacOS/Spookky --output .cache/identity-revised.json
```
