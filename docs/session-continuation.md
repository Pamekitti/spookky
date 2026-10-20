# Desktop and remote continuation

**Continue elsewhere…** targets the workspace's primary conversation. Open it from the conversation row or primary terminal menu. Focusing a file, browser preview, artifact or supporting shell does not change the target.

The panel checks installed provider capabilities on demand. It never types into a CLI, starts or stops an agent, submits an unsent draft, enables remote access or claims a transfer succeeded.

## Supported routes

| Route | Action | Ownership |
| --- | --- | --- |
| Live Codex to Desktop | Enter `/app` at an empty primary Codex prompt | Opens the same saved chat. The TUI and shared server may remain alive. |
| Live Claude to Desktop Code | Enter `/desktop` at an empty primary Claude prompt | The provider saves the session and exits its CLI when transfer succeeds. |
| Saved Claude to Desktop Code | After releasing its owner, use `claude --desktop --resume <UUID>` from its original folder | Provider eligibility and refusal remain authoritative. The panel supplies instructions only. |
| Claude Remote Control | Enter `/remote-control` in its live primary session | Controls the original local process. Keep its host awake and process running. |
| Codex Remote Control | Configure `codex remote-control` using provider instructions | A shared-server route. The panel does not claim the selected conversation belongs to that server. |
| Return to a surviving primary | Reconnect primary | Inspects the captured binding and reattaches it. No agent launch or prompt delivery occurs. |
| Return to saved history | Use exact-ID native resume from the saved provider cwd when ownership permits | Reloads provider history. It does not recover unsent input from a lost process. |

Save unsent CLI input before entering a slash command. Provider-native authentication, trust, permissions, consent and account eligibility remain in the provider. Unsupported routes show guidance rather than an automatic action.

## Startup feedback

Runtime attachment does not prove that the provider initialized or accepted a starting prompt. New launches retain a separate startup observation. After 15 seconds without native confirmation, the conversation shows a quiet explanation with Focus terminal and Details. Details offers Copy starting prompt and Dismiss startup notice. Neither action submits text or starts another process. Declining activity hooks can leave startup unconfirmed even while the terminal is usable.

The explanation also points to macOS file access. A native CLI can wait while reading configuration or history outside its conversation folder. Spookky does not grant that access or restart the owning runtime automatically.

Initial prompts continue through ordinary native launch arguments. Spookky never converts a delayed launch into background execution, automatically retries an uncertain prompt, or removes provider locks. The retained prompt and native refusal output remain available for explicit recovery.

## Primary identity and supporting views

`ConversationContinuationCoordinator` captures the workspace ID, canonical `ConversationID`, primary terminal UUID, original provider cwd and optional owned binding. It ignores supporting selection when resolving this target. A saved entry without a binding can display exact-ID guidance. It does not offer Reconnect or silently start a CLI.

After each asynchronous probe and before reconnect, the coordinator revalidates the captured target. Changes to primary identity, terminal, binding, cwd or closed-view state cancel the stale action. Support-tab selection can change without retargeting the operation. Cancel preserves support selection and both terminal and launch drafts.

Reconnect returns focus to the primary. A full-width supporting panel becomes split so the primary can be shown. Supporting tab IDs, selection, content state and drafts remain. The existing `SupportingContentHost` retains browser/artifact views. This work does not add or validate those renderers.

Closing views or windows keeps owned terminal sessions running. **Stop primary terminal…** ends only Spookky’s owned terminal session. **End terminals and quit** applies that local action to the app’s terminals. Shared-server or background execution may continue.

To stop ongoing work, save unsent or queued input and use the provider’s displayed Stop or Interrupt control in the surface running that conversation. Codex CLI displays its interrupt key during an active turn. Claude’s interrupt keys depend on prompt and queue state, so Spookky does not inject them. For a Claude background session, select the exact session in the provider’s agent view and use its native controls.

Spookky has no verified per-conversation execution-stop integration. Codex documents `turn/interrupt`, but using it safely would require a verified connection to the owning server and active turn. This change adds no such client, second writer or shared-server shutdown. Process-exit checks verify terminal lifecycle only. They do not prove that an active provider turn stopped.

## History integration

`WorkspaceWindowController.continuationMetadata` reads canonical metadata for the opened conversation from its workspace. The separate paged history catalog supplies that record when the row is opened. The saved provider cwd remains independent of checkout grouping and supporting shell directories. No transcript store is introduced.

`ProviderContinuationCapabilities` detects each route from bounded installed-help probes. Version strings are diagnostic information, not minimum/exact-version gates. Help results are cached until the executable or version changes, with a 32-identity bound. It supplies exact-ID argument builders. `guide` has defaulted live-provider and owned-binding parameters for presentation. `resumeSpec` never supplies a prompt, newest-session selector, fork or permission override. `desktopSpec` describes Claude's native exact-ID launcher. Neither builder establishes ownership or launches anything.

Use [provider ownership](provider-ownership.md) when history evaluates saved resume. Codex delegates native resume admission to its CLI. Claude blocks a known interactive owner, attaches a supported background owner, and uses ordinary resume when ownership reporting is absent. That fallback does not establish exclusive cross-app ownership. A hidden window, stopped TUI, absent file descriptor or missing registry row never proves release. Never delete provider locks, freeze a CLI or resend an uncertain initial prompt.

## Verification boundaries

Earlier disposable checks used Codex CLI 0.162.1, Claude Code 2.1.296, ChatGPT Desktop 26.1013.40934 and Claude Desktop 2.42304.0. Codex `/app` reported success while its original TUI survived. GUI inspection of Codex is forbidden. A separate owned embedded-server shutdown followed by exact-ID resume loaded its saved reply without another turn.

Claude `/desktop` exited its disposable CLI with status 0. Desktop accessibility readback showed the same UUID, original folder and test exchange. Its return menu did not respond to native automation. Claude Desktop screen capture failed. Desktop return remains unverified, and no remote pairing was enabled. Later ownership checks cover Claude Code 2.1.302 and Codex's Desktop server build separately.

Current coordinator tests cover support-focus independence, saved entries, cancellation, changing primary identity/terminal/binding/cwd, closed views, failed probes, missing capabilities and inspection-only reconnect. The 18 October offline provider checks passed nine Codex cases on CLI 0.163.0 and seven Claude cases on Code 2.1.302. They verify saved native resume/attach without extra turns. They do not verify a Desktop round trip, remote pairing or the revised combined native interface.

Official references checked on 17 October 2026:

- [Codex Desktop command](https://learn.chatgpt.com/docs/developer-commands#continue-in-the-desktop-app-with-app)
- [Codex resume and remote-control commands](https://learn.chatgpt.com/docs/developer-commands)
- [Claude CLI to Desktop continuation](https://code.claude.com/docs/en/desktop#coming-from-the-cli)
- [Claude Remote Control](https://code.claude.com/docs/en/remote-control)

- [Codex app-server turn lifecycle](https://developers.openai.com/codex/app-server#lifecycle-overview)
- [Claude interactive controls](https://code.claude.com/docs/en/interactive-mode)
- [Claude agent view](https://code.claude.com/docs/en/agent-view)
