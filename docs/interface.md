# Interface specification

The polished [prototype source](../prototype/spookky-workspace.html) is the visual baseline. [Flows](flows.md) define behavior when a mock fixture is incomplete. Native controls preserve this hierarchy and density. The [native control specification](native-design-reference.md) defines shared geometry and component states. macOS input and accessibility conventions remain authoritative.

## Shell

```text
+----------------------+------------------------------------------------------+
| Sidebar toggle       | [ Codex       x ] [ Terminal    x ] +       [sidebar] |
| + New workspace  CmdN+------------------------------+-----------------------+
| Search           CmdK| branch / directory     split | Files     Changes     |
|                      +------------------------------+-----------------------+
| Projects          +  |                              | workspace path        |
| northstar         +  | Real CLI terminal            | Search files          |
|   Session recovery x |                              |                       |
|   feat/search      x |                              | src/                  |
| atlas             +  |                              |   session.ts          |
|                      |                              |   workspace.ts        |
| No project        +  |                              |                       |
|   Home             x |                              |                       |
|                      |                              |                       |
| Personal    Settings | CLI input stays in terminal  |                       |
+----------------------+------------------------------+-----------------------+
```

Opening a file inserts an adjacent preview between terminal and file list. The file pane can be resized, maximized, or closed. There is no separate app-wide title toolbar and no automatic bottom terminal.

The sidebar toggle sits in the fixed 40-point tab-strip header. It does not scroll with sidebar entries. The header measures native window-button clearance before placing the first tab. Fullscreen removes that reservation. Collapsed navigation, projects and workspaces use centered 32-point targets on one vertical axis. The header toggle retains its 28-point utility target.

The left sidebar collapses to a 58px icon rail. The right sidebar hides completely. The right-edge Code control shows its label at widths of 900 points or more and its icon at smaller widths. Its selected state reflects Files/Changes visibility. Unused header and tab-strip space moves the normal window. Terminal, prompt, and file content retain their own mouse gestures. Header dragging is disabled during fullscreen and its transitions. Compact native titlebar integration preserves standard window controls without adding another empty row.

Terminal text selection remains highlighted after mouse release. Cmd+C copies that selection. Programs that request mouse input keep their gestures. Shift selection retains Ghostty's normal behavior.

When a file preview moves from a wide layout into a window below 800 points, dismiss the file-list overlay once so the preview remains readable. The toolbar control can reopen the overlay on demand.

## Start page

```text
                       New workspace

       +------------------------------------------------+
       | Start with a prompt...                         |
       |                                                |
       | [Codex v]                                (up)  |
       +------------------------------------------------+
        [Project v] [Local v] [From origin/dev v]*
        path / branch             Prompt optional · Cmd+Enter

        >_ Open Terminal                              Cmd T

        Recent projects                         + Add project
        folder northstar                   ~/code/northstar
        folder atlas                       ~/code/atlas

       * Source appears only when creating a worktree.
```

The prompt is an optional launch draft. Its editor grows from 80 points to the smaller of 300 points or half the available content height, then scrolls. The composer uses a 13-point radius and one integrated provider/launch footer. The chosen provider stays visible. The send arrow has an accessible label that describes whether it opens the CLI or starts it with a prompt.

Terminal mode collapses the prompt and exposes one Open Terminal action with Cmd+T. It does not repeat a second Terminal launch row. Recent projects appear only before project selection, sorted by actual recent use. Merely selecting a project does not change recency.

## Spacing and dimensions

These are the native component dimensions. The HTML retains the approved flow and layout reference; native differences are listed in the source comparison.

| Element | Reference |
| --- | --- |
| Spacing scale | 4, 8, 12, 16, 24, 32px; 6px for compact icon padding |
| Expanded sidebar | 232 points |
| Collapsed sidebar | 58px; centered 32-point row targets |
| Tab strip | 40px |
| Terminal, preview, and Files/Changes headers | 40 points |
| Project row | 28 points |
| Workspace row | 46px with name and secondary location |
| File row / common icon target | 28px |
| Right sidebar | 248 points |
| Composer | 560px maximum width; 80-point minimum prompt height; grows to 300 points or half the available content height |
| Menus | 8px corner radius, 5-6px inner padding |
| Dialog | 400px maximum width, 20px padding, 10px radius |
| Main text / dense labels / metadata | 13px / 12px / 11px |
| Terminal font | System monospace, default 13px, user-adjustable |

### Native control convention

Use SF Symbols in the native app. A symbol beside a row or button label uses a 14-point regular glyph in a 16-point slot, followed by 6 points of space. Icon-only add, close, and pane controls use a 14-point medium glyph centered in a 28×28-point target. The tab close target is 24 points wide. Tabs occupy the full 40-point strip, with a trailing separator and restrained selected fill. Keep the symbol's optical size consistent within each role rather than stretching every symbol to a fixed image rectangle.

Keep 8 points between compact controls, 12 points between sections, and 4 points within a compound control. Use 8-point sidebar selection insets. Project rows remain 28 points high, workspace rows 46 points high, and the tab strip 40 points high. Use the existing 13/12/11-point type hierarchy. Clip titles and paths before they displace an action. Overflowing workspace titles use a 14-point trailing fade. Hover or keyboard focus reveals the hidden end in one pass after 350 ms, at 32 points per second with a duration from 0.5 to 6 seconds. Exit returns the title in 200 ms. Reduce Motion retains a static fade. Tooltips and accessibility labels retain the full text.

Use four button roles: primary launch, secondary destination/direct launch, quiet navigation/utility, and destructive confirmation. Filled controls retain their role on hover and press. Quiet controls use the foreground wash. All roles have a visible native keyboard focus ring and a disabled state. Selected rows and tabs carry the selection fill. Project add and workspace/tab close actions appear on row hover or descendant keyboard focus. Standalone add controls remain visible. Actions reserve their space at rest and never move the title when revealed. Row and tab hover fills cover their enclosing component; nested label buttons do not draw another fill. Files and Changes use the same quiet selection treatment, not the system-blue segmented style. A plain-language visual fixture must not display the Unicode stress-test names used by automated compatibility checks.

The HTML's fixed 760px frame is a preview constraint, not a native window requirement. Avoid shrinking text to fit more controls. At 800px and below, secondary sidebars overlay; at 600px and below, diffs use unified layout. Touch targets should expand if a touch-capable surface is ever supported.

### Native row and preview geometry

Project icons start 16 points from the sidebar edge; project titles start at 40. Nested workspace icons start at 32 points; titles and their secondary metadata start at 56. No-project workspace icons and titles use the top-level 16/40 alignment. Each leading icon has a 16-point slot and an 8-point gap to its title. Project groups have an 8-point gap. Close controls align to the title line, with a reserved 28-point target at the trailing edge. Add and close glyphs use 12-point regular-weight symbols and a centered 20-point hover fill with a 5-point radius. Tab close targets are 24 by 24 points.

Files and preview tables use the plain native style with no enclosing horizontal content inset. File group headings and root icons begin 8 points from the panel edge. Root filenames begin at 28 points; each directory level adds 12 points. Directory disclosure uses native chevrons. Files use native code, document, configuration, image, archive or generic symbols. Repository and symlink entries remain distinct. Git status letters carry semantic colors and descriptive accessibility names. Parent paths use secondary text and yield space before the filename. Status indicators remain 8 points from the trailing edge. Selection uses a foreground wash; only the table with keyboard focus draws its focus outline.

Preview line-number columns cannot autoresize. Each column measures its largest displayed number and adds 12 points, with a 28-point minimum. Change signs occupy a separate 16-point column; code has an 8-point leading inset. Plain previews show one number column, unified diffs show two, and each split side shows one. Source indentation remains unchanged. Diff backgrounds cover the entire row, including gutters. Split columns resize with their pane without reloading the selected rows.

Routine Git-filter policy appears in a Preview information popover. Errors, limits, conflicts and unavailable-content notices remain visible. Below 480 points of preview width, Open With and Reveal in Finder move into a visible overflow menu. Below 360 points, context, diff layout and preview information also move there. Maximize and close remain visible. The filename keeps its full path tooltip.

## Color and type

Use system interface type and a separate monospace terminal/code face. Ordinary text uses weight 400; titles and selected emphasis use 500. Prefer muted structure and thin borders over boxes around every row.

| Token | Dark | Light |
| --- | --- | --- |
| Background | `#151110` | `#f9f9fa` |
| Sidebar/surface | `#1a1716` | `#ececec` |
| Raised/card | `#201e1c` | `#ffffff` |
| Hover wash | foreground at 7% | foreground at 4% |
| Selected wash | foreground at 10% | foreground at 6% |
| Text | `#eae8e6` | `#0a0a0a` |
| Secondary | `#a8a5a3` | `#4a4847` |
| Metadata | `#9a9795` | `#605e5d` |
| Border | `#2a2827` | `#e5e5e5` |
| Warning | `#e5c07b` | `#906d01` |
| Destructive | `#cc4444` | `#e7000b` |
| Success | `#5fb37f` | `#009966` |

Diff additions/removals use muted green/red backgrounds plus explicit signs and line numbers. Status must also have a text/accessibility label. A green process indicator in the prototype means a session exists; it is not proof of a successful task.

## Direct controls

- Clicking a project expands or collapses its workspace rows. Project **+** creates a workspace with that project selected and expands its group. Workspace **×** closes that entry. Collapse does not change selection, drafts, or processes. Collapse state persists. Finding a workspace expands its parent group.
- Keep the close button inside the selected row's visual boundary. Closing another row must not steal selection.
- Secondary rename/remove/delete actions live in contextual menus, opened by right-click or Shift+F10. Context menus anchor to the entry and stay inside the window.
- Project menus open from the exact add or picker control that invoked them. Keep the trigger visible when there is room below it.
- Use recognizable Terminal, Codex, and Claude glyphs in tabs. Native asset choices require their own provenance check; do not invent provider branding.
- A long tab strip scrolls the active tab into view after layout and icons settle. Project identities use the GitHub owner avatar from their origin remote when available, with text monograms as a fallback. The avatar changes to a disclosure chevron on hover or keyboard focus. Avatar downloads are asynchronous and cached; no account is required. Session glyphs distinguish Terminal, Codex and Claude Code without provider logo assets. Exceptional lifecycle states use static indicators. A running process is not labeled as agent activity or task success.
- Files and Changes have both text labels and icons. File groups include counts. Long names truncate with a path tooltip.
- Keep diff context and layout actions in the preview header. Show the extra conflict selector only for a conflicted file.
- If workspace title equals branch name, use location type and tab count on the second row rather than duplicating the name.
- Workspace titles start with a friendly two-word name. The first composer starting prompt can replace it once; manual names always win. See [naming behavior](flows.md#launch-and-initial-prompt).
- For Spookky's automatically generated branch, show Worktree and the tab count on the second row. Other branch names remain visible. Tooltips retain the full branch and path, including during exceptional lifecycle states.

## Agent attention

Tabs, workspace metadata, collapsed workspace icons, and terminal headers share the [agent activity](agent-activity.md) labels. The existing 16 pt status slot holds the activity indicator. Working uses a visible-only native spinner that respects Reduce Motion. Needs input, failures, and unread completion have distinct shapes and text labels. Directory, branch, provider, and child-agent details remain available in tooltips. Lifecycle launch and attachment failures take precedence over activity hints.

Right-click actions mark completion attention read or unread and reset activity. The overflow menu includes status text. Settings separates provider monitoring, banners, sounds, preview privacy, Dock count, and visible-terminal suppression. App sounds default to off because provider sound hooks remain active.

## Code syntax

Files, unified diffs and split diffs share semantic syntax colors. Source text and indentation remain intact. Comments use an italic monospace face. Tabs display at four-column stops without changing copied text.

| Role | Dark | Light |
| --- | --- | --- |
| Keyword | `#c678dd` | `#75507b` |
| Comment | `#9a9795` | `#605e5d` |
| String / regular expression | `#7ec699` | `#3e7905` |
| Number / literal constant | `#e5c07b` | `#805600` |
| Function / heading | `#61afef` | `#3465a4` |
| Type / built-in / attribute | `#56b6c2` | `#07666d` |
| Variable / tag | `#dc6b6b` | `#9d1732` |

Code uses 12-point monospace text in 18-point rows. Diff captions identify the index, working copy, HEAD or merge-base commit. Unified and Split controls show the effective layout. Narrow panes retain the split preference and render unified content. Unchanged selected rows survive a refresh at the same positions.

Files/Changes and preview reads run quietly in the background. Routine refreshes retain the current rows, selection, layout, notices, and preview-information control until new results arrive. Do not flash Updating or Loading messages. Clear the previous scope's status when switching workspaces and the previous file's notices when selecting another file. Errors, conflicts, limits, and unavailable-content notices remain visible.

HighlighterSwift supplies the language definitions. Spookky's bounded range adapter styles complete documents off the main thread. It retains at most three unchanged documents within 16 MiB, counts that cache within the preview budget, and clears it on scope changes, suspension or preview closure. Diff colors use the exact old/new comparison versions, including staged renames and absent sides. Results must match the current generation and displayed source line before styling. Unknown file types stay plain. A highlighting error appears in Preview information while readable text remains available.

## Keyboard commands

| Shortcut | Action |
| --- | --- |
| Cmd+B | Toggle the project/workspace sidebar |
| Cmd+L | Toggle Files/Changes |
| Cmd+N | Create an unbound workspace |
| Cmd+T | Open Terminal from a blank tab or add a blank tab from a running tab |
| Cmd+W | Close the selected tab through its lifecycle rules |
| Cmd+K | Find a workspace |
| Cmd+Shift+[ / ] | Previous / next tab |
| Cmd+Enter | Launch only while the optional composer owns input focus |

Buttons, menus and shortcuts share their actions. Other terminal keys remain with the CLI. Sidebar collapse preserves input focus. Hiding Files/Changes while it owns focus returns to the terminal or composer. Overflow exposes a menu of all tabs and an explicit New blank tab action.

## Interaction details

Tab and workspace titles rename in place. Return commits a nonempty name. Escape cancels. Switching, closing or resizing cancels the editor without moving focus to an unrelated entry.

Each composer owns up to 50 Undo levels. Undo and Redo operate only on native text editors; terminal-focused shortcuts retain terminal routing. Undo history stays with the retained editor and is not persisted across restart.

Menus close on Escape and restore focus. Arrow keys navigate contextual actions. Dialogs keep keyboard focus inside while open. Visible action labels and accessibility names must agree.

Inputs retain focus while typing; do not rebuild the entire interface per keystroke. Validation retains values and places the error near the relevant action. Loading states identify the current step and allow cancellation when safe.

Keep primary launch actions visible. Reveal sidebar utilities on hover and keyboard focus. Keep compact controls distinguishable in both themes. Native VoiceOver behavior needs real testing; the HTML checks do not establish native accessibility.

## Visual QA

After a coherent change, inspect blank Home, selected project, worktree options, running CLI, terminal plus diff, file tree, menus, dialogs, and errors. Compare the native app at 1440 × 900, 1120 × 760, and 650 × 450 in both themes. Compare the HTML preview at desktop, 390px, and 320px widths. Check focus, scrolling, truncation, empty states, and restoration.

Verification boundaries are recorded in [current status](status.md). The prior appearance is saved as [spookky-before-polish.html](../prototype/spookky-before-polish.html).
