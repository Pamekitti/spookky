# Provider ownership before saved resume

A running provider process does not identify which conversation it owns. `ProviderOwnershipCheck.assess` evaluates the selected provider and exact session ID. It never scans process names, tests for absent file descriptors, deletes locks, stops another owner or starts a turn.

## Codex CLI and Desktop server compatibility

Codex CLI 0.162.1 refused an independent app-server trying to resume a conversation with an active writer. The error was `already has an active writer`. An unrelated conversation remained usable. After the owned server exited, the second server resumed the same ID.

A second client of the same server resumed the same ID. A native TUI using `codex resume <ID> --remote unix://<owned-socket> --cd <original-folder>` rendered that conversation. Normal folder trust remained in the provider. The server still reported one loaded conversation, and the provider history contained one started turn.

The backend currently returns `providerArbitrated` for `codex-cli 0.162.1` and its expected resume interface. History may invoke native exact-ID resume without blocking on unrelated Codex processes. The provider must arbitrate again at launch. This result does not assert that an existing owner has exited. A competing owner can still cause a native refusal.

The installed Desktop bundle contains 0.163.0-alpha.10.2. Disposable cross-version checks passed in both directions, including writer refusal and native TUI attachment. The selected CLI capability remains restricted to the explicitly supported build. Unknown builds remain conservative until verified. A fresh thread occasionally returned a transient metadata hydration error before its initial records settled. The fixture retries only that read failure and reports the retry count. It never retries an active-writer refusal. No custom app-server execution client is added to the app. The app-server protocol is used only by the disposable fixture.

The installed schema for `ThreadResumeParams` describes rejoining a running thread on the same server. The [official app-server documentation](https://learn.chatgpt.com/docs/app-server) describes resume, loaded-thread queries and transports. Installed CLI help documents the native `--remote` route.

## Claude Code 2.1.302

`claude agents --json` reported the exact UUID and PID of an owned interactive session. It also distinguished an unrelated UUID. This is supported positive ownership evidence. The backend ignores display names and transcript contents.

Ordinary `claude --resume <UUID>` opened a second foreground TUI for that same UUID while the first was busy. Both appeared in the provider's registry. This offline fixture does not prove that simultaneous turns can write safely. It disproves using startup admission as an exclusive ownership gate.

A matching interactive record returns `interactiveOwner`, including every reported PID. Those PIDs are diagnostic and must not become external Stop targets. A matching live or logically working/blocked background session returns `backgroundOwner`. Background attach stays guided. No matching record, unsupported output or a failed check returns `unknown`. Absence from a snapshot never establishes release or removes the race before launch.

The [provider's agent-view reference](https://code.claude.com/docs/en/agent-view#list-sessions-as-json) documents JSON ownership metadata. Its [session guide](https://code.claude.com/docs/en/sessions#resume-a-running-background-session) describes native background attachment. Flags such as per-invocation `--settings` can prevent that attach route. No automatic background attach or Spookky hook change is included here.

## History integration

Call `assess` with a plain `CLIResolver` spec for the saved provider cwd and the exact provider session ID. Wrapped helper executables are rejected. Only `canInvokeNativeResume == true` permits replacing the blanket process block. Known Spookky bindings take priority and reconnect without a new launch. Preserve durable launch intent, existing busy-operation guards and prompt-free exact-ID arguments. Do not apply the old process-name or loaded-thread block after a provider-arbitrated result. Do not infer success from the assessment or a terminal process starting.

For positive ownership or unknown results, show `explanation` and keep the original entry available. Foundation owns reattachment of known Spookky bindings. This backend does not mutate workspace state, choose the focused supporting tab, add a history store or change foundation APIs.

## Verification

```sh
swift test --jobs 2 --filter ProviderOwnershipTests
python3 scripts/check_provider_ownership.py --output .cache/ownership-check.json
```

The Codex fixture uses isolated provider data, a loopback offline endpoint, private tmux and owned server process groups. It sends no real model-service request or remote pairing. It checks competing writers, unrelated conversations, owner exit and native same-server continuation. Unit fixtures cover Claude exact-ID matching, multiple clients, logical background ownership, malformed records and unproven release. These checks do not establish Desktop round trips or support for other provider builds.
