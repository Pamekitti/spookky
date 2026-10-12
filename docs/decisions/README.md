# Decision register

Accepted product decisions are recorded here. Technical candidates remain candidates until measured evidence supports adoption.

| ID | Decision | Status |
| --- | --- | --- |
| D01 | Real CLI terminal is the primary interface; no custom chat renderer | Accepted |
| D02 | Project optional, Local default, worktree explicit, initial prompt optional | Accepted |
| D03 | Project -> workspace anchor -> terminal tabs, with stable IDs | Accepted |
| D04 | Cmd+N creates workspace; contextual Cmd+T supports immediate shell start | Accepted |
| D05 | Compact native shell, project + and workspace × | Accepted |
| D06 | Complete file tree and two clearly separated Changes scopes | Accepted |
| D07 | Commit/PR/review-comment workflows excluded from v1 | Accepted |
| D08 | Provider owns history, auth, permissions, model selection, and CLI rendering | Accepted |
| D09 | Resume, reattach, cloud copy, and remote control stay distinct | Accepted |
| D10 | Native macOS direction; Rust not required; HTML remains a prototype | Accepted direction |
| D11 | Full Ghostty embedding | Preferred candidate, M0 gate |
| D12 | Private bundled tmux, one session per terminal | Preferred candidate, M0 gate |
| D13 | SQLite metadata, GRDB adapter | Preferred candidate, pin during implementation |
| D14 | Worktree/file removal separate from workspace entry closing | Accepted |
| D15 | Exact deployment target, packaging, updater, dependencies | Open technical decisions |
| D16 | Public app name and code licensing | Spookky; original application code is not open-source licensed |
| D17 | Speed, bounded resources, effortless starts, clear parallel work, and reliability govern feature selection | Accepted |
| D18 | Public vision stands on user needs and outcomes; integration and dependency names belong in their dedicated sections | Accepted |

## Decisions to resolve before depending on them

[M0 terminal feasibility](m0-terminal-feasibility.md) records the working build, private runtime, and remaining adoption gates. The initial dependency revisions are pinned; full interaction and latency acceptance remains open.

1. Which exact Ghostty embedding API/revision can we build, package, and maintain?
2. Does tmux preserve required CLI input, graphics/clipboard behavior, scrollback, and low overhead?
3. What macOS deployment target follows from the selected engine/toolchain?
4. How will the app reliably detect a busy shell without guessing from terminal text?
5. Which CLI launch mechanisms support optional prompts and acknowledge delivery, if any?
6. What runtime update strategy preserves owned sessions and permits reconnect?
7. Which complete attribution set and runtime notices will accompany app distribution?

These do not reopen the product direction. They are implementation gates and release choices.

## ADR format

When a consequential technical choice is resolved, add a numbered decision file with: status/date, problem, considered options, decision, exact versions, evidence, consequences, and conditions for revisiting it. Link it from this register. Never label an untested candidate as measured or approved.

## Changes made during the design day

The design moved from a required named task/worktree and custom-chat assumptions to a flexible terminal-first workspace. It removed unnecessary navigation and delivery flows, introduced immediate blank workspaces/tabs, and added the optional prompt composer. The final polish replaced repeated sidebar overflow controls with direct actions and standardized layout density.

The current documents incorporate the product decisions and prototype corrections.
