# Provider ownership before saved resume

Continuation uses the installed provider's advertised capabilities. Version strings are diagnostic information. A CLI update does not fail an exact-version allowlist.

`ProviderOwnershipCheck.assess` evaluates the exact provider session ID. It never infers ownership from process names, deletes locks, stops an external owner or starts a turn. Available provider metadata remains a snapshot, with a race before launch.

## Native decisions

| Evidence | Decision |
| --- | --- |
| Known surviving Spookky binding | Reattach that terminal without another launch. |
| Codex advertises exact-ID resume | Use ordinary native resume. Codex reports conflicting writers in its terminal. |
| Claude reports the exact UUID in an interactive owner | Block saved resume and direct the user to that terminal. Reported PIDs are diagnostic, never external Stop targets. |
| Claude reports a live background owner with one valid registry ID and native attach support | Run `claude attach <registry-id>` for that existing session. |
| Claude reports no owner, or ownership reporting is unavailable | Use ordinary `claude --resume <UUID>` without another confirmation. This does not establish exclusive cross-app ownership. |
| Exact-ID resume or a known owner's required attach capability is unavailable | Keep the entry and show a specific recovery explanation. |

A background registry ID differs from the conversation UUID. Only an exact session match can supply that attach ID. Ambiguous or invalid IDs remain unavailable. Spookky never converts resume into `--background`, which can create a copy when a session is already running.

## Capability and launch boundaries

Bounded help probes detect exact-ID resume, optional Desktop/Remote controls, ownership reporting and background attach independently. Basic Codex resume does not require `--remote`. Its argument builder uses the advertised `--cd` or `-C` option when present; otherwise the launch directory still supplies the original folder.

Help results are cached for at most 32 executable/version/environment identities. The version and executable identity are checked for changes. Native launch argument arrays contain no new prompt, newest-session selector, fork or permission override. Native Claude attach receives no injected settings that would change its route.

History calls `ConversationExecutionCheck.prepare` with a plain executable resolver. The returned decision contains the ownership assessment and exact launch specification. LaunchCoordinator validates and preserves that prepared specification. Known owned bindings take priority. Repeated selections share one operation. Cancellation before durable intent prevents an unstarted launch; receipt recording completes after creation begins.

Assessment permits an attempt. A terminal starting does not establish successful provider continuation. Authentication, trust, eligibility and refusal remain provider-owned.

## Verification

```sh
swift test --jobs 2 --filter 'ProviderOwnershipTests|ProviderContinuationTests|CoordinatorTests'
python3 scripts/check_provider_ownership.py --output .cache/ownership-check.json
python3 scripts/check_claude_ownership.py --executable /path/to/claude --output .cache/claude-ownership.json
```

On 18 October 2026, the installed Codex CLI 0.163.0 passed nine offline checks. Independent writers were refused, unrelated conversations remained usable, owner exit permitted resume, and a native TUI joined the same saved conversation through an owned server. The fixture waits for persisted user input and indexed metadata before its single resume attempt. It records the first response and performs zero resume retries.

On 19 October 2026, the reproducible Claude Code 2.1.303 fixture passed eight checks. Provider-created history resumed in a foreground TUI. Its exact UUID appeared in interactive ownership metadata. After that fixture released its terminal, explicit background startup retained the UUID and native registry-ID attach rendered the saved reply. Resume and attach sent no additional model turn. One initial response came from an owned loopback stub, with no external model service or user credentials. Normal onboarding and folder trust were retained. Cleanup targets only the fixture's exact session and folder. The report retains the first failure without retrying resume.

Unit tests cover unknown versions with supported interfaces, missing capabilities, failed ownership reporting, multiple interactive owners, ambiguous background IDs and unchanged prepared arguments. These checks do not prove every provider release, a Desktop round trip or remote pairing.

References: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude JSON agent list](https://code.claude.com/docs/en/agent-view#list-sessions-as-json), [Claude background resume](https://code.claude.com/docs/en/sessions#resume-a-running-background-session).
