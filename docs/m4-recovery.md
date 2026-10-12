# Continuity and recovery checks

A reopened terminal view can attach to the same surviving process. A resumed provider conversation starts a new process using provider-owned history. Neither operation guarantees that an unsent terminal draft survives process loss.

## Automated runs

[Current status](status.md) records the unresolved extended-continuity gate. The hands-on checks below cover input, accessibility, sleep, and reboot.

Build Release before starting a measurement. Do not rebuild that binary during a run.

```sh
python3 scripts/benchmark_m4.py --output .cache/m4-continuity.json
python3 scripts/benchmark_m4.py --overnight --output .cache/m4-overnight.json
```

Use `--binary /absolute/path/to/an/isolated/executable` to keep a long run on a frozen app copy. The same executable is used for crash restoration. The smoke-only `--output-delay 1.5` verifies delayed producer startup. First-output readiness has a separate ten-second boundary outside the timed workload.

The default timed workload lasts 30 minutes after ten warm-ups and 100 measured lifecycle cycles. Eight-hour mode uses the same checks and bounded sampling. Both modes then collect 60 seconds of idle CPU from the same ten surviving shells. The report retains checkpoints if interrupted. Fixture cleanup ends only its own app and private runtime. Normal Spookky sessions remain separate.

The report identifies its disposable fixture root. Do not treat that root as a user project. Do not interrupt the fixture to test an unrelated process. The automated runner cleans its root when it exits, so use a separate native development workspace for the manual steps below.

## Sleep and wake

1. Open a disposable folder in Spookky. Launch Terminal and record its PID with `echo $$`.
2. Type an unsent marker at the prompt. Keep a second terminal and an optional agent composer draft open.
3. Open Files/Changes and select a known file. Record the selected file and split arrangement.
4. Put the Mac to sleep through the normal system interface. Wake it after at least five minutes.
5. Check the original PID, unsent marker, composer draft, file selection, and terminal focus.
6. Check that output resumes and no extra session appeared. If a provider connection ended, record its message separately from the terminal process outcome.

Sleep is user-controlled. The automated runner never invokes system sleep or changes power settings.

## Reboot

1. Use a disposable workspace. Save a multiline composer draft and record the workspace/tab count.
2. Choose **Keep sessions running and quit**. Confirm that reopening Spookky before reboot reattaches to the original PID.
3. Quit with background continuation again. Reboot through the normal system interface.
4. Reopen Spookky. Metadata should restore without extra workspaces or tabs. Vanished processes should be **Ended**.
5. Confirm that no agent or shell starts automatically. The composer draft should remain. An unsent terminal draft may have ended with its process.
6. Explicitly start a new terminal or use the provider's resume command. Record that it is a new process.

## Provider history and remote capabilities

Run resume commands inside a disposable checkout. Select a conversation created for this test. Do not use `--last` against unrelated user history.

For installed Codex, `codex resume --all -C /absolute/disposable/checkout` opens the provider picker. A specific session ID pins the chosen history. Codex Cloud exposes `diff` and `apply`; applying code is distinct from transferring a conversation.

For installed Claude Code, `claude --resume` opens its picker. `--fork-session` can create a new session identity when resuming. `--teleport` exposes provider cloud continuation. Availability depends on the provider account and organization policy. Remote Control is provider-owned; Spookky adds no mobile client or account.

Record successful responses, authentication blocks, spending-limit blocks, and unsupported paths separately. Opening a picker does not prove a saved conversation resumed. Provider trust and authentication decisions stay with the user.

## User-assisted input and accessibility pass

- Type ASCII, punctuation, shifted keys, and repeated keys into Terminal. Check both visible text and the shell result.
- Use a composing input method. Check candidate position, cancellation, and committed text. Unicode paste does not replace this check.
- Paste multiline text without submission. Paste an image in each provider's supported interface. Check that Enter is never inserted automatically.
- Turn on VoiceOver through the normal system interface. Navigate projects, workspaces, tabs, composer, Files/Changes, and recovery controls. Check names, selected states, reading order, and errors.
- Complete one Claude response in a disposable checkout, then explicitly resume that conversation in a new process. The automated Codex response/resume check has passed.
- Cmd-click a rendered web link and a file link in the terminal. Verify the browser/editor opens the exact target. The native control API cannot synthesize this modified mouse click.

Record the app build hash, CLI versions, observed result, and exact blocker for each check. Daily-use readiness requires these checks and the applicable continuity gates.
