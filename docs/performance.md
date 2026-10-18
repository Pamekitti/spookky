# Performance protocol

Spookky's responsiveness and memory use must be measured in the native app. Remaining gates are recorded in [current status](status.md). The HTML prototype does not establish these claims.

## Workload matrix

Use a named 16 GB Apple Silicon Mac and record hardware, macOS, power mode, display scale, build type, dependencies, CLI versions, terminal dimensions, and history limits. Run without stopping unrelated user sessions; record background load as a limitation.

| Fixture | Purpose |
| --- | --- |
| Empty app | Baseline startup and settled footprint |
| 1, 5, and 10 shell sessions | Separate app/runtime overhead from provider memory |
| 1, 5, and 10 agent sessions | Real CLI compatibility, responsiveness, and total cost |
| Eight sessions, 5,000 lines each, 120 columns, two visible surfaces | Reproduce the original planning baseline |
| Continuous output with active typing | Input latency under load |
| 1 MiB / 5,000-line text diff | Normal preview cost |
| Large repository and oversized file | Bounded scanning and preview behavior |
| 100 create/close cycles | Detect retained views, buffers, processes, and observers |
| Overnight session, sleep, and reopen | Stability and recovery |

Use deterministic output fixtures for comparable engine load. Separately run actual CLIs; model/network time is not UI latency. Never publish a comparison from unequal session counts, scrollback, visible panes, or repository workloads.

## Provisional targets

These planning targets were carried forward from the architecture discussion. M0 must assess them and record any proposed revision before treating them as release gates.

| Metric | Initial target |
| --- | --- |
| Settled empty app | At most 150 MiB application-owned footprint |
| Eight-session shell fixture | At most 400 MiB app, terminal surfaces, owner, clients, and helpers combined |
| Warm workspace switch | p95 below 100 ms |
| Detached view reattachment | p95 below 250 ms, no duplicate agent |
| Input-to-visible local echo under controlled load | p95 below 50 ms |
| Typical selected text diff | p95 below 150 ms for the named fixture |
| Syntax-ready preview | Provisional p95 below 300 ms after five warm-ups; report cold cost separately |
| Settled idle CPU | Below 1% of one core, averaged across 60 seconds |
| Create/close cycles | Memory reaches a plateau after warm-up; no monotonically retained surfaces |
| Application overhead | Measure app/runtime separately from agent costs and track regressions |

Report process-tree totals as well as application-owned overhead. Count tmux server/clients, rendering surfaces, and bundled helpers in overhead. List agents and their tool/dev-server descendants separately. Retaining agents preserves state and also preserves their memory cost.

Use an explicit collector and state whether the memory number is RSS, physical footprint, or another metric. Do not sum incompatible metrics or present a single sample as a stable average. Gather enough timed samples for the percentile reported; document warm-up and repeated runs.

## Initial engineering limits

- M1 defaults to one visible terminal surface. Its explicit split supports two visible surfaces and one extra warm hidden surface. Full-width tools can retain both previously visible terminal surfaces while hiding them. The overall bound remains three.
- Detach/release hidden surfaces through supported APIs. Do not suspend reads on an attached PTY and block its producer.
- Start with 5,000 history lines per terminal and measure both owner and frontend buffers. Scrollback and selection must still work.
- Cap decoded diff cache near 64 MiB initially. Load selected content on demand. Files over 2 MiB or 20,000 lines begin with a bounded preview.
- Coalesce file events around 250 ms, with a maximum 1-second wait during continuous edits.
- Start with two concurrent Git readers globally and one app-owned writer per common repository. Cancel stale reads.
- Use bounded logs and batched session-presence queries. Do not scan the full process table per terminal.

These are starting constraints for implementation, not tested configurations. Record measured adjustments in an ADR. Performance improvements must not discard unsent input, stop hidden agents, hide missing changes, or misrepresent session continuity.

## Result template

For each measurement record: commit, machine, dependencies, fixture, warm-up, sample count, duration, median/p95 where relevant, app overhead, provider memory, total memory, idle CPU, failure observations, and collector limitations. Store reproducible scripts with the implementation and sanitized reports under `docs/benchmarks/` when results exist.

## M0 input and timing collection

`python3 scripts/benchmark_m0.py` runs resource and timing fixtures against the Release app. Use `--mode resources` or `--mode timing` for a targeted rerun. Resource cases use 0, 1, 5, and 10 shell sessions, a five-second warm-up, and a 60-second observation window. Hidden surfaces are released. This is one run per workload, not a confidence interval.

Idle CPU is the difference between cumulative process CPU times at the observation boundaries, divided by monotonic elapsed seconds. A value of 100% represents one core. The collector includes the app and its private runtime descendants. A changing process set invalidates the CPU result. The `ps` collector has centisecond CPU resolution; its own cost is excluded and remains background load. Historical lifetime-average CPU samples are not idle measurements.

Startup uses 30 fresh processes with empty private roots. The measured boundary runs from before spawning the app to observing its ready receipt with 5 ms polling. This measures empty-app readiness, not first rendered frame or time to an interactive shell. Repeated runs benefit from warm OS and filesystem caches.

Reattachment uses 100 releases and recreations of one persistent terminal view. Each observation ends when the unsent draft appears in terminal state. Process identity and attached-client count are checked separately. Terminal-state echo uses 100 native text insertions into an unloaded `cat` fixture with 2 ms polling. Neither metric proves physical key-to-display latency. Percentiles use the nearest-rank method and retain raw observations and failure counts.

Resource reports include RSS and separate physical-footprint observations. Do not compare or sum those different metrics. The binary SHA-256 identifies the measured build. Existing user workloads remain running throughout collection.

## Rendered output and agent frontend follow-up

`scripts/benchmark_render_m0.py` measures native key delivery to completed rendered pixels. It reads the fixture's red/green indicator from Ghostty's own IOSurface-backed layer. Ten observations warm the path before 100 timed observations per case. Direct/persistent and idle/target-500-lines-per-second cases are separate. The 2 ms polling interval, sampled color region, and producer workload are part of this measurement. It establishes rendered-pixel readiness, not exact physical key-to-screen latency.

`scripts/benchmark_agents_m0.py` records app/runtime overhead separately from owned idle CLI descendants. Cases are one Codex, one Claude, five mixed, and ten mixed frontends. Warm-up is 15 seconds, followed by at least 60 seconds of observation. Provider services outside the owned trees remain excluded. No model prompts are sent, so these results do not establish active development-workload costs.

Process-group changes invalidate that group's cumulative CPU delta. Keep the unaffected app/runtime result when its own group remains stable. Record unavailable provider/combined CPU as null. RSS medians may fall with compression or paging; this is not proof that a larger workload needs less memory. Preserve pane dimensions and host memory pressure in the raw report.

## M1 workspace collection

Add `--conversations` to measure independent sidebar workspaces, each with one primary clean shell. The resource fixture verifies the workspace count. The timing fixture switches between four workspaces and checks that crash restoration retains all four bindings. Browser, catalog, and real-provider costs remain separate measurements. The default fixture retains its original single-workspace terminal-tab workload for comparison.

`--mode startup` measures 30 fresh processes through empty workspace readiness, with 5 ms polling. It includes private fixture setup and excludes the first rendered frame, provider discovery, and time to an interactive CLI. Filesystem caches may be warm. `--mode all` includes this startup measurement.

`python3 scripts/benchmark_m1.py` measures the native workspace window with clean `zsh -f` shells. It uses isolated metadata and socket roots. It terminates only the processes it creates. Normal provider configurations, active user sessions, and development metadata remain outside the fixtures.

Resource cases use 0, 1, 5, and 10 shells, a five-second warm-up, and 60 seconds of observation. Record app RSS and the sum of distinct app, client, server, and shell RSS separately. RSS includes shared pages and does not establish the physical-footprint gate. This workload has one visible surface. It does not establish two-pane or active-agent resource costs.

Cumulative CPU includes stable live owned processes and the app's reaped children. The latter include periodic runtime queries. Request child CPU snapshots at the observation boundaries through a directory-event watcher. Diagnostics do not poll continuously. Record their monotonic timestamps alongside the collector's elapsed time. The collector's own CPU is excluded, but its load remains on the host.

The workspace observes private-runtime exit and attachment notifications instead of polling session status. Selection, explicit reconnect, closing, and launch operations inspect immediately. Existing private servers receive hooks only after a session ownership token is verified. Stopping hidden agents is never a performance optimization.

Use `--foreground` to request a visible resource fixture and record actual visibility/application activation at both CPU boundaries. Requested foreground placement alone is not evidence that the OS kept the window active. Use `--split` for two visible panes plus one warm hidden surface. Physical footprint is reported separately as a bounded vmmap observation. Selection diagnostics also record RSS across repeated surface lifecycles; this does not establish longer process create/close stability.

Timing fixtures cycle through four sessions, with 40 warm selections and 110 surface recreations. Discard five warm-up observations from each class. The resulting counts can exceed 35 and 105 because normal launch/restore paths also emit observations. Report the actual counts. The boundary ends at an attached, laid-out, focused native view. It excludes first terminal bytes and rendered-display latency.

The crash check saves a generated history viewport, kills its own app process, and reloads the same SQLite metadata. Verify private process identities, the generated viewport marker, workspace count, and tab count. It does not prove exact scroll anchoring for arbitrarily wrapped output after a window-size change.

## M3 collection

`scripts/benchmark_m3.py` adds selected-diff, file-lifecycle, and panel resource fixtures. The standard patch contains about one MiB and 5,000 rows. Five warm-ups precede 30 timed observations. The boundary includes Git reads, validation, parsing, table reload, and native layout. It excludes physical display latency. The optional dense case changes every line and produces about twice as much patch data.

One hundred preview/workspace cycles report retained row/buffer accounting, watcher count, and terminal surface count. The collector also checks rapid selection, clipboard copying on a private test pasteboard, continuous edits, focus, hidden-watcher shutdown, and an unsent shell draft. Timing mode reuses M1's reattachment and app-crash checks with Files/Changes active.

Resource mode observes ten clean shells for 60 seconds after warm-up. Open-panel fixtures use a generated Git checkout; closed-panel fixtures use Home. Their absolute budgets are checked separately. Physical footprint remains a separate vmmap observation. Record exact binary hashes, scopes, counts, results, and post-measurement changes with each run.

## M4 continuity collection

`scripts/benchmark_m4.py` runs ten warm-up cycles and 100 measured lifecycle cycles. Each cycle launches and closes two owned clean shells, exercises a split, and returns to the ten-session baseline. It records process disappearance, retained surfaces, watchers, composer views, application-managed task handles, decoded buffer accounting, and RSS. Task-handle counts cover Spookky's retained references, not every internal Swift runtime task.

Five 20-cycle RSS medians exclude warm-ups. The report flags sustained growth for allocation investigation. Passing the bounded-cycle rule does not establish an overnight plateau.

The default workload runs for at least 1,800 seconds. Generated output runs at one line per second in a separate owned process. The fixture preserves unsent shell input while switching, evicting surfaces, closing/reopening its window, and editing generated files. Checkpoints record elapsed seconds and retained counts. The same ten surviving shells then receive a five-second warm-up and 60-second idle observation. RSS and physical footprint remain separate.

The existing timing collector supplies warm selection, recreated-surface attachment, wrapped-history resize, and app-crash restoration checks. Their boundary remains attachment, layout, and focus. Physical display latency and active model-workload costs remain open.

`--overnight` selects 28,800 seconds. `--smoke` selects two lifecycle cycles and a one-second diagnostic workload. Smoke results never count as performance acceptance. Reports retain checkpoints after interruption. The fixture terminates only its own app and private server.

## Conversation workspace sample, 17 October 2026

Local Release measurements on a 16 GiB Mac14,10 used separate conversation workspaces with clean shells. Each resource case had a five-second warm-up and 60 seconds of observation. It retained one visible terminal surface. Windows were visible and the app was inactive at both CPU boundaries. Provider discovery was replaced with an empty catalog. Existing user applications and sessions kept running.

| Workspaces and shells | App RSS median, MiB | Total RSS median, MiB | Idle CPU, percent of one core |
| --- | --- | --- | --- |
| 1 | 91.1 | 95.1 | 0.017 |
| 5 | 91.2 | 100.7 | 0.033 |
| 10 | 90.3 | 106.5 | 0.017 |

Total RSS sums distinct app, private runtime, client and shell processes. All three process sets stayed stable. Shared pages and compression affect RSS. Separate app physical-footprint observations were 82.6, 87.6 and 94.3 MiB respectively. These cases contain no WebKit view, real provider or development server. They do not establish the active-agent or overnight gates.

| Measurement | Samples | Median, ms | p95, ms |
| --- | --- | --- | --- |
| Warm conversation selection | 35 | 19.6 | 24.9 |
| Recreated conversation surface | 105 | 50.5 | 58.0 |
| Empty fixture process readiness | 30 | 356.4 | 378.5 |
| Persistent input to rendered pixels at 500 output lines/second | 100 | 8.8 | 10.9 |

Selection starts before changing the workspace and ends at attachment, layout and focus. It includes synchronous sidebar work. It excludes first terminal bytes and display scanout. The four-workspace crash/reopen check retained the same process IDs and visible history marker, with no extra workspace or tab.

Readiness includes fresh private fixture setup. It excludes provider discovery, the first rendered frame and the first interactive CLI. Filesystem caches may be warm. The input harness ends at matching pixels in Ghostty's completed IOSurface, sampled every two milliseconds. It excludes physical keyboard input and compositor/display scanout.

The browser fixture also recorded one resource snapshot after its interaction checks: 200.2 MiB app RSS, 121.7 MiB across four WebKit helpers, and 19.5 MiB across runtime/shell helpers. It had no provider process. WebKit helpers were attributed through the app's LaunchServices coalition. This snapshot includes fixture work and is not a settled browser CPU or memory baseline.

Reports are retained locally under ignored `.cache/` with binary hashes and measurement boundaries. The resource rows preceded the final file-tab context correction. That clean-shell workload materializes no file preview. The selection, startup, input and diff measurements include the correction. Each result is one pass on one host, not a cross-application comparison.

After the file-tab context correction, the standard large-diff fixture passed all 24 checks and 100 selection cycles. Its 30 measured selections had a 99.0 ms median and 113.5 ms p95. Syntax readiness had a 162.5 ms median and 179.2 ms p95. The measurement includes Git reads, parsing, native table reload and layout. It excludes physical display latency. Preview and metadata buffers stayed within their existing bounds, and the collapsed panel released its watcher.


## Layout and startup refinement, 18 October 2026

The local Release binary `5e269a48380d` passed 191 native checks. Provider discovery used an empty or synthetic catalog. Fixtures used owned shells and private runtime roots. Existing user applications and sessions remained running.

| Measurement | Samples | p95 |
| --- | ---: | ---: |
| Warm conversation selection | 35 | 17.4 ms |
| Recreated terminal selection | 105 | 51.0 ms |
| Empty process readiness | 30 | 366.2 ms |
| Large-diff selection | 30 | 133.3 ms |
| Syntax readiness | 30 | 182.7 ms |

Selection ends at native attachment, layout and focus. It excludes physical display latency. Empty readiness includes private setup and excludes provider discovery, the first frame and interactive CLI readiness. Filesystem caches may be warm. The diff fixture also passed 100 selections and its buffer, watcher and surface bounds. The crash/restore fixture retained process identities and its visible history marker.

Two short resource observations used five seconds of warm-up and about 15 seconds of collection each. Both retained stable process sets and collected 61 samples. Split was requested; one shell displayed one surface and five shells displayed two. These are RSS medians from clean-shell workloads. They exclude provider and browser costs.

| Shells | App RSS | App plus owned runtime/shell RSS |
| ---: | ---: | ---: |
| 1 | 110.4 MiB | 116.7 MiB |
| 5 | 120.2 MiB | 135.2 MiB |

CPU counters rounded to zero over these short windows. This does not establish zero CPU use or replace the 60-second idle acceptance measurement. Physical keyboard/IME, spoken VoiceOver and extended sleep/reboot continuity remain separate gates. Direct desktop automation could not bind this development app identity; native verification used app fixtures and screenshots.

## Session workflow revision, 18 October 2026

The final workflow build (`1f497426efea`, source `4195347`) was compared with the installed `e59ad24` implementation. The private baseline copy changed only its bundle identifier and signatures so it could use isolated fixture roots. All four executable text sections matched the installed originals. No user session was stopped.

| Measurement | Samples per build | Baseline | Workflow revision |
| --- | ---: | ---: | ---: |
| Empty readiness, median / p95 | 30 | 366.5 / 514.4 ms | 335.0 / 365.1 ms |
| Warm conversation selection, p95 | 35 | 18.9 ms | 20.7 ms |
| Recreated terminal selection, p95 | 105 | 51.9 ms | 51.2 ms |
| Five-shell app RSS, median | 62 / 65 | 109.3 MiB | 91.9 MiB |
| App plus owned runtime/shell RSS, median | 62 / 65 | 120.9 MiB | 102.5 MiB |
| App physical footprint observation | 1 | 43.8M | 55.2M |

Memory results are mixed. Both resource windows were occluded and inactive at the CPU boundaries. The baseline retained one terminal surface; the revision retained two. Each observation followed five seconds of warm-up and ran for about 15 seconds with five surviving clean shell conversations. CPU observations of 0.066% and 0% were near collector resolution. They do not establish zero CPU use or the full 60-second idle gate.

Empty readiness excludes provider discovery, first-frame rendering and an interactive CLI. Selection ends at native attachment, layout and focus. The baseline ran before the revision; caches may be warm. These measurements do not establish active-provider or browser resource costs. Both crash/restore checks retained process IDs and the visible history marker without creating extra sessions.

The large-diff fixture passed 24 checks with 30 measured selections, 100 lifecycle cycles, diff p95 115.9 ms and syntax p95 207.9 ms. The virtualized sidebar fixture mounted fewer than 100 views for 5,000 metadata rows. Reports and binary hashes remain in private ignored evidence.

The focus-polish Release binary `69e576adba23` passed 262 native assertions across workflow, browser/artifact and file fixtures. The file run retained 100 selection cycles and all buffer, watcher and surface bounds. After five warm-ups, 30 selections measured 103.7 ms median and 107.3 ms p95. Syntax readiness measured 169.1 ms median and 172.5 ms p95. These use the same native readiness boundary and exclude physical display latency. Existing user sessions remained running. This run does not establish a causal performance improvement from the style changes.
