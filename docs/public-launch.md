# Public launch preparation

Spookky's public launch foundation is implemented. A signed installer is not published yet.

## Implemented

- MIT licensing for original code, documentation, and artwork. Contribution, conduct, security, issue, and PR guidance are included.
- A static GitHub Pages website with original ghost artwork, real native screenshots, privacy information, and release-aware downloads.
- Source-built tmux with static non-system dependencies, packaged helpers and terminfo, and dependency notices.
- Distribution identity `dev.spookky.app`, separate production storage, native Settings/About/licenses, and Sparkle 2.10.0 integration.
- Standard update consent, no system profile, HTTPS, signed feeds and archives, and restart preparation that keeps sessions running.
- Branded DMG preparation, Developer ID signing, notarization, draft-release tooling, and protected signing jobs.

Private vulnerability reporting and immutable releases are enabled. Main requires a PR and passing source/native checks. The signing environment requires maintainer approval. Signing secrets are not in the repository.

## Verification on the development host

The host is an Apple Silicon Mac with 16 GiB RAM and macOS 26.6.2. Native Debug, Release, and unsigned Distribution configuration builds pass. The Distribution metadata and packaged executable/resource checks pass. Stripped executables contain no builder-home paths. This does not establish Developer ID signing or notarization.

The full Swift suite passes 94 tests. Python passes 14 tests. The website passes six Playwright checks, including 1440px, 390px, 320px, release availability, invalid metadata, and keyboard access. The repository checker, public file/ref audit, and secret scan pass.

The packaged runtime passes 100 ownership/lifecycle cycles. Native history checks pass four assertions. Crash/reopen checks pass seven assertions. Input replay passes 11 assertions in each of direct and persistent modes. Real shell input, the native Settings shortcut, both themes, and the 650×450 layout were inspected. These are targeted checks, not full human acceptance.

The regenerated prototype's Terminal launch fits on one line at 320px. Its behavior remains simulated.

A temporary local QA build under the production identity created only Spookky metadata and its separate runtime. Real shell input worked. The historical database's bytes remained unchanged. The temporary app and synthetic state were archived privately. This namespace check used ad hoc signing and does not establish signed installation or update delivery.

Build-runner checks found two compiler compatibility errors and an output/history race. Explicit types resolve the compiler errors. Viewport capture now reads tmux's frozen copy-mode grid. A deterministic streaming regression fails on the previous code and passes on the fix. The full Swift suite and 20 repeated streaming regressions pass locally.

The updated native timing fixture passes wrapped resizing and crash restoration. Warm selection p95 is 4.13 ms across 36 observations. Surface recreation p95 is 41.35 ms across 106 observations. These stop at an attached, laid-out, focused view and exclude physical display latency. The fixture ran behind user windows.

## Continuity boundary

A new smoke fixture passes two lifecycle cycles and a one-second continuity workload. The fixture uses a short controlled shell prompt. It checks both the native text projection and the owner's joined lines so line wrapping is not mistaken for lost input.

The full eight-hour replay uses a frozen app bundle and an isolated runtime behind user windows. A superseded run was stopped after the viewport fix; its partial evidence is retained privately. The replacement run's result is pending. Fixture-only termination records are bounded and retained privately for diagnosis. The earlier failed overnight record had missing original panes; its cause remains unresolved.

## Release blockers

No valid Apple signing identity is currently available on the development host. The maintainer must configure Apple membership, Developer ID signing, and notarization authentication. The actual two-build Sparkle installation test and clean-Mac installation have not run.

macOS 14 compatibility, physical typing and IME, spoken VoiceOver, terminal link/file activation, provider responses/resume, sleep/wake, reboot, and final performance acceptance remain gates. See [current status](status.md), [acceptance](acceptance.md), and [the release procedure](releasing.md).
