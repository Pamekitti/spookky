# Instructions for agents working on Spookky

## Read before editing

Read `README.md`, `docs/product.md`, and `docs/build-plan.md`. For the area being changed, read `docs/flows.md`, `docs/interface.md`, or `docs/architecture.md`. Use `docs/acceptance.md` for verification.

Current stage: native terminal, workspace, project/worktree, file/diff, and continuity implementation. Read docs/status.md for verified behavior and remaining gates. M0 compatibility and daily-use acceptance remain incomplete. Do not report prototype behavior as proof of terminal compatibility, process recovery, Git correctness, or performance.

The user's latest explicit instruction takes precedence. Otherwise, current product and flow documents define behavior. The prototype defines the visual reference. Identify a material conflict before implementing a different flow.

## Protect the product direction

Spookky prioritizes speed, bounded resource use, effortless starts, understandable parallel work, and reliability. These commitments in `docs/product.md` govern feature selection and architecture.

For a runtime feature, identify the user need, the smallest useful interaction, and its added resource/state cost. Measure relevant effects when changing rendering, terminal retention, file scanning, or background work. Do not add features just to match another product's list.

Keep immediate shell access and the compact interface intact. Never meet memory targets by silently stopping hidden agents or dropping user drafts. Separate performance goals from measured results and report app/runtime costs alongside total session costs.

Public positioning describes Spookky's user needs and outcomes without competitor comparisons. Supported integrations can be named in compatibility sections. Preserve technical dependency attribution and notices.

## Product invariants

- The central surface is the real CLI terminal. Do not build a custom agent chat renderer, model protocol, approval UI, or transcript store.
- Projects are optional. Worktrees are optional. Agent starting prompts are optional. A plain Home shell must work without an agent or app account.
- Cmd+N creates an unbound workspace. Cmd+T creates a blank tab from a running tab, or opens Terminal immediately from a blank tab. Preserve typed agent drafts when taking that shortcut.
- A workspace owns one anchor folder. Tabs share its files. A terminal's `cd` does not silently change Files/Changes scope.
- Project + creates a workspace for that project. Workspace × closes its entry. Files and branches remain unless deletion is separately requested.
- Keep the compact shell. Do not introduce a global title toolbar, automatic bottom shell, required task form, review checklist, commit wizard, or PR workflow.
- Preserve the provider's authentication, permissions, shortcuts, prompt editor, and history. Do not weaken permission defaults.
- Reconnecting a view must not launch another agent or resend an initial prompt.
- Unknown activity remains unknown. Process presence does not prove an agent is working or a task succeeded.

## How to work

- A question is a question. Answer it without implementing unless the user asks for action.
- For multi-step work, keep a short todo list with one item in progress. Finish authorized work and report specific blockers.
- Inspect current files and Git state before editing. Preserve unrelated changes and active user sessions.
- Use `rg` for search. Batch independent reads. Make one coherent UI change set, then verify it once. Recheck after relevant changes or specific failures.
- Use existing patterns and the spacing/control rules in `docs/interface.md`. Prefer direct actions over unnecessary menus.
- Avoid speculative layers, unused packages, placeholder services, and dependencies added only for future work.
- Use isolated checkouts when concurrent work requires them. Name feature branches `codex/<description>` unless directed otherwise. Do not spawn other agents unless requested.
- Keep commits scoped to one concern. Stage named paths. Do not push, publish, send external messages, or deploy without authorization.
- For shipping Spookky changes or opening a PR, use the repository's [ship skill](.agents/skills/ship/SKILL.md). Commit scoped dirty work in logical groups, then rebase onto `origin/main`, verify, audit, push the feature branch, and open the PR.
- Before public pushes, audit all remote refs. Exclude AI notes, session metadata, private state, fixture output, and local checkout paths. Preserve required dependency licenses and notices.
- Do not install dependencies or run setup code from a user's project automatically. Registration and opening Local are passive operations.
- Never execute terminal fixture text from the HTML prototype. It is sample data.

## Native implementation boundaries

Start with M0 in `docs/build-plan.md`. Terminal rendering and persistence are technical gates, not established capabilities. Record exact dependency revisions and license notices if adopted.

Use argument arrays for executable launches. Treat paths and initial prompts as data. Never interpolate them into shell command strings. If a shell layer is unavoidable, isolate and test that boundary.

Keep terminal bytes inside the terminal stack. Keep file scanning, Git, and persistence off the main UI thread. Bound retained buffers, decoded diffs, logs, and concurrent subprocesses.

Own only Spookky's runtime. Never attach to or stop the user's default tmux server, another terminal application's processes, or unrelated dev servers. Separate development and release data roots.

Use stable record IDs. Canonicalize checkout identity without losing the selected subdirectory. Git files, the process owner, and provider history have distinct authorities. Reconcile observed state after crashes before retrying operations.

Do not claim exactly-once delivery to a CLI without an acknowledgment mechanism. Persist launch intent and expose uncertain prompt delivery rather than automatically resending.

## Verification and reporting

Current repository checks:

```sh
python3 scripts/check_repo.py
```

Node.js enables an additional JavaScript syntax check. The checker reports when it is unavailable. Preview instructions are in `prototype/README.md`.

For prototype changes, regenerate `prototype/index.html`, check the changed flow in a browser, and inspect desktop and narrow layouts. For native changes, add only commands that really exist to `docs/development.md`. Verify real terminal input, focus, and lifecycle in the running app when those features are touched.

Tests should cover a concrete risk or requirement. Do not create tests that only repeat implementation details. Distinguish targeted checks from the full acceptance suite. Report what changed, what ran, and what remains unproven.

Write plain prose. No em dashes. Lead with the result. Use short sentences and concrete terms. Put rationale in decision documents; add code comments only for constraints the code cannot express.
