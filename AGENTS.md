# Spookky agent instructions

Build a fast, reliable native macOS workspace around real CLI terminals. Keep the interface compact and resource use bounded.

## Work

- Follow the latest user instruction. Answer questions without implementing them. Finish authorized work without repeated confirmation.
- Inspect Git state and relevant files first. Preserve unrelated edits and active sessions. Use `rg`, batch reads, and keep one todo item in progress.
- Read only relevant contracts: [product](docs/product.md)/[flows](docs/flows.md), [UI](docs/interface.md), [runtime](docs/architecture.md), or [development](docs/development.md). Check [status](docs/status.md) before claiming acceptance.
- Run `python3 scripts/check.py --plan`, then selected checks once. Reuse matching passed receipts. Recheck changed behavior or failures. Batch UI changes before one focused verification.
- Use the project [ship skill](.agents/skills/ship/SKILL.md). Make logical commits, rebase onto main, audit, and open a PR. Never push directly to main or force push. Merge only when authorized and the exact head is ready.

## Boundaries

- Keep provider-owned input, authentication, permissions, and history. No custom agent chat or approval layer.
- Projects, worktrees, and prompts stay optional. Preserve immediate Home shell access, Cmd+N/Cmd+T behavior, drafts, and workspace anchors.
- Reattach surviving processes without relaunching agents or resending prompts. Unknown activity and uncertain delivery remain explicit.
- Launch with argument arrays. Keep terminal bytes in the terminal stack. Bound buffers and keep scanning, Git, and persistence off the UI thread.
- Own only Spookky processes and private sockets. Separate dev, fixture, and installed state. Never stop hidden agents to reduce memory.
- Project opening is passive. Never run project setup or prototype terminal samples automatically.
- Use `codex/<topic>` branches. Spawn agents only when requested. Keep private state outside public source and refs. Preserve dependency notices.
- Installation, releases, deployment, and messages require their own authorization. Private installers remain the active update path.

## Report

Lead with the result. Use plain prose without em dashes. Load the writing skill for longer prose. State checks and remaining limits. Tests or a merge do not prove installed delivery. Measure relevant resource effects.
