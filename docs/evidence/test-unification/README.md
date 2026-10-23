# Test unification verification

All 360 pre-migration Swift scenarios remain discoverable. Swift cases now use XCTest in unit, integration, provider and performance targets. Native UI assertions run in the separate SpookkyHarness application and its hosted XCTest bundle.

This verification ran on 23 October 2026. The baseline is `bb99ae9`. The production UI sources tested here were committed in `d8bb0fb`; subsequent commits adjust test synchronization, runners, CI and documentation. [Machine-readable results](verification.json) retain binary identities and check counts.

## Coverage and isolation

| Check | Observed result |
| --- | --- |
| Swift Debug unit | 80 passed |
| Swift Debug integration | 276 passed |
| Swift Release integration | 276 passed |
| Explicit Release file-scale case | 1 passed, 50,000 files, cancellation and 1,000-result cap |
| Python tooling | 62 passed, zero skips |
| Release hosted native matrix | 14 passed, zero skips or infrastructure failures |
| Debug hosted smoke | 1 passed, plus 9 workspace-recovery assertions |
| Website Playwright | 8 passed |
| Normal application | Debug and Release builds passed; Release bundle audit passed |
| Distribution | Production source membership audit passed |

The default command excludes six installed-provider cases and one file-scale performance case. The pre-migration baseline passed 354 Swift cases with six opt-in skips, plus 36 Python cases with two skips. [The scenario inventory](../../../Tests/Inventory/swift-cases.json) preserves the original case names. The native inventory preserves 408 original assertion templates. Each native report declares required assertion IDs; dynamic display rows also produce detailed per-control results.

The Release matrix exercised both appearances, wide and narrow windows, 80%, 100%, 150% and 200% zoom, fullscreen transitions, composer/model menus, prompt images, project association, history paging/search, terminal selection, surface races and closure. Its Display case recorded 2,487 passing assertions. The same canonical run completed browser/artifact interaction and cold restore, sidebar restart, terminal scrollback, folder probes, direct and persistent input replay, legacy crash recovery and nine workspace-recovery assertions.

Recovery checks retained the same shell process, one private session and one attached client. They retained terminal input, composer drafts, workspaces and selection. Reopening did not replay the draft. A separate normal Debug app check used desktop keyboard and accessibility interaction for startup, composer typing, Cmd+T, shell input/output, Cmd+N, sidebar switching and quit choices. The owned app exited and its private state was removed.

Debug and Release normal binaries rejected diagnostic flags with exit status 64. Fixture runners rejected those same binaries with harness migration instructions. Packaging regressions reject harness identities and XCTest artifacts. Source-membership tests cover Debug, Release and Distribution.

Regression coverage rejects empty, hash-only, incomplete, malformed, non-boolean and false fixture reports. It also covers zero-test selection, native exit failures, Debug dylib identity, configuration selection for Swift and Python helpers, cleanup isolation, crashed-host evidence retention, lock contention and release after owner exit. The operating-system GUI lock is shared across worktrees. Cleanup uses fixture-owned roots, sockets, processes and pasteboards.

## Application organization

History discovery, paging, search and cancellation belong to `WorkspaceHistoryController`. Sidebar rows, enrichment, avatars and Git/PR requests belong to `WorkspaceSidebarCoordinator`. Conversation opening, continuation preflight, launches and startup deadlines belong to `WorkspaceLaunchController`. Each owns its tasks, generation tokens and caches. The window controller composes views, coordinates rendering and forwards actions.

Production sources are grouped under application, chrome, composer, files, sidebar, terminal and workspace features. Generic controls, prompt input and model menus have separate files. Normal and harness applications use `ApplicationBootstrap` for persistence, interrupted-draft recovery and window creation. Synthetic providers, benchmarks, fault injection and scenario drivers are outside normal application membership.

## Resources

[Matched resource results](measurements.json) retain all observations, including three switching passes. Both frozen executables use standalone Release builds with testability disabled. The same collector alternates before and after across zero, one, five and ten independent clean-shell workspaces. Each resource observation has five seconds of warm-up and 60 seconds of sampling. Startup uses 30 launches per build. Switching includes warm and recreated surfaces plus a real crash/restore.

The historical baseline ran through a local wrapper that permitted only its pinned executable and helper hashes. The shipped fixture runner continues to reject normal-app binaries.

RSS is resident memory and includes shared pages. Total RSS sums distinct owned app, runtime and shell processes. CPU is cumulative owned-process and reaped-child time divided by elapsed time; 100% is one core. These measurements exclude WindowServer, provider work, the collector and physical display latency. One local pass does not establish a causal improvement or an overnight memory plateau.

Pairs below mean before / after. Startup is process creation through empty-workspace readiness. It excludes fixture setup, code hashing, the first rendered frame and the first interactive CLI. Filesystem caches may be warm.

| Timing | Before / after, ms |
| --- | --- |
| Empty readiness median, 30 launches | 346.0 / 329.8 |
| Empty readiness p95 | 390.7 / 358.8 |
| Warm switching p95, first pass | 24.7 / 25.2 |
| Recreated-surface switching p95, first pass | 65.0 / 74.2 |
| Warm switching p95 range, three passes | 24.7–27.3 / 25.2–29.8 |
| Recreated-surface switching p95 range, three passes | 65.0–82.8 / 72.1–77.3 |

Each switching pass measured 35 warm and 105 recreated selections per build. The repeated p95 ranges overlap for recreated surfaces. Every pass retained the same private processes and viewport through crash/restore. All passed the existing 100 ms warm and 250 ms reattachment budgets. These observations do not establish a general speed improvement.

| Independent shell workspaces | App RSS, MiB | Total RSS, MiB | Idle CPU, percent of one core |
| --- | --- | --- | --- |
| 0 | 29.0 / 27.0 | 29.0 / 27.0 | 0.05 / 0.03 |
| 1 | 28.2 / 28.3 | 30.6 / 31.4 | 0.02 / 0.02 |
| 5 | 34.5 / 27.0 | 44.3 / 33.5 | 0.03 / 0.03 |
| 10 | 27.3 / 25.0 | 39.9 / 37.6 | 0.02 / 0.03 |

All eight process sets stayed stable. Windows remained visible and inactive at the CPU observation boundaries. RSS reflects memory compression and shared pages, so the lower observations at larger workspace counts are not capacity estimates.

Both lifecycle builds completed ten warm-ups, 100 measured open/close cycles, a 60-second workload and a 60-second idle observation. Every closed process disappeared and ten baseline sessions remained. Observed maxima were three surfaces, ten composers, one watcher, one file-task handle and zero settled launch operations. Resize, reconciliation and render handles stayed within their declared bounds. Both passed preview and metadata caps and the defined RSS growth rule.

The five measured RSS block medians were 153.9, 115.0, 108.0, 106.0 and 102.9 MiB before; 98.8, 93.6, 93.7, 94.3 and 94.4 MiB after. Post-workload idle CPU measured 0.02% before and below the collector's resolution after. The rule checks sustained block growth; it does not establish an overnight plateau.

The selected-diff workload passed 24 checks and 100 selection cycles. Across 30 observations, diff readiness measured 108.2 ms p95 and syntax readiness measured 170.6 ms p95. Those results passed the 150 ms and 300 ms budgets.

## Reproduction and limits

Use the [canonical commands](../../development.md#test-organization). Native evidence remains under ignored `.cache/tests`, `.cache/fixture-failures` and `.cache/assessment` directories. CI uploads native result bundles and failure evidence. Historical evidence elsewhere in this repository remains unchanged.

Paid provider requests, overnight workloads, physical typing/IME composition, spoken VoiceOver and installed-app replacement were excluded. The normal application and harness were verified separately. Tests do not establish installed delivery. Pinned Ghostty umbrella-header and signed dependency stripping warnings remain; warnings in the moved test sources were resolved.
