# Prototype

This is the finalized design reference for Spookky's first native version. It simulates projects, workspaces, agent sessions, Git states, files, and recovery. It never runs the displayed commands.

## Files

| File | Purpose |
| --- | --- |
| [spookky-workspace.html](spookky-workspace.html) | Editable fragment with scoped CSS, sample data, and interaction logic |
| [index.html](index.html) | Generated standalone preview |
| [preview-template.html](preview-template.html) | Exported standalone host wrapper with a source insertion marker |
| [spookky-before-polish.html](spookky-before-polish.html) | Saved comparison baseline before the last visual refinement |

## Run and update

From the repository root:

```sh
python3 scripts/render_prototype.py
python3 scripts/check_repo.py
python3 -m http.server 48766 --bind 127.0.0.1 --directory prototype
```

Open [localhost:48766](http://127.0.0.1:48766/). The preview can also be opened directly as a file, but browser storage behavior may vary for file URLs. Use the local server for reproducible checks.

Edit `spookky-workspace.html`, then regenerate `index.html`. Keep the template's source marker intact. Do not edit the generated page independently or let it drift from the fragment. The renderer needs only Python and this repository.

The pinned CDN icon script requires connectivity on first load. The preview uses the exported host's local state adapter. The app simulation still enforces its 15,500-byte snapshot envelope; oversized or failed saves warn rather than silently truncating drafts. This limit must not become the native storage design.

Settings contains **Prototype scenarios** for deterministic failures and Reset sample data. Provider handoff examples are fixtures, not integrations. The native app implements these layers separately; the prototype does not establish their correctness or performance.

## Review order

Start with the bottom composer. Confirm Codex on first use, provider/folder chips inside, Local by default, and worktree options inside the folder popover. Type an optional draft, open Terminal below, and check that the draft remains in saved prototype state.

Use New session or project + for another agent. Supporting + opens Browser, Files & Changes, Artifact or Terminal. In Split view, both tab groups share one 40-point row. Full view joins the primary first and all support tabs. Selecting primary keeps the tool tabs visible. Returning to Split restores the last support and divider width. Check synthetic page/artifact input while switching tabs, sessions and layout.

Browser and artifact panels are local UI fixtures. They do not fetch a website or read a local file. Their synthetic draft fields can be saved with prototype state. This does not establish native WebKit form retention after restart. Enter in a terminal records simulated input only. Never execute sample terminal text outside this preview.

Assess details freely as keep/change/remove. There is no required review or commit sequence.

New sample workspaces use friendly names and can be named once by the first composer prompt. Manual renames remain fixed. Older prototype snapshots without rename metadata keep their saved titles because their original naming source is unknown. Native metadata records that source and can migrate known automatic generic labels safely.

See [interface specification](../docs/interface.md), [current flows](../docs/flows.md), and [current status](../docs/status.md).
