# Native control specification

Spookky's native controls follow the geometry and interaction rules below. The launch, ownership, and recovery flows remain defined by [the product contract](product.md) and [flows](flows.md).

## Components

| Component | Geometry | Behavior |
| --- | --- | --- |
| Sidebar | 264-point default column; selection insets are 3 points left and 8 right | Retains saved widths and uses a neutral palette confined to the sidebar |
| Project row | 28 points, outlined folder, label at 35 points, separate 28-point add action | Click toggles expansion; folder becomes a chevron on hover/focus; add appears on hover/focus |
| Conversation row | 31 points, regular 14-point title at 35 points, two trailing accessory targets | No leading provider mark; hover/focus reveals Pin and Archive; overflowing titles scroll within their clip |
| Tab | 40-point strip, muted inactive title, one selection/hover fill, 24-by-24-point close target | Shared bounded tabs use rounded inset fills; supporting close appears on hover/focus and primary never closes |
| Composer | 800-point maximum width, 80-point minimum prompt, 13-point card radius | Always available on landing; optional prompt; supporting Terminal retains the agent draft |
| Files / Changes | Native file picker and a dedicated Changes view, 28-point list rows | Individual file tabs remain separate from change-review context |
| Preview | 40-point header, 28-point utility targets, muted notices, explicit diff signs | Read-only native selection/copy and Spookky's existing limit states remain intact |
| Menus and dialogs | Native NSMenu, NSAlert, and folder picker; shared type, path, warning, and destination styling | Uses macOS placement, focus, cancellation, and platform metrics |

Leading symbols use 14 points in a 16-point slot. Add and close symbols use 12-point regular weight with a centered 20-point hover fill and 5-point radius. Symbols retain their natural proportions. Compact buttons use 28-point targets and 8-point corner radii. The 24-point tab close target remains the only smaller utility target. Filled buttons have primary, secondary, and destructive roles; quiet controls draw only their interaction or selection state.

Dark hover and selection washes use the foreground at 7% and 10% opacity. Light washes use 4% and 6%. They composite over the current surface instead of using a separate opaque gray for every component. Light OKLCH reference values are converted to fixed sRGB values at development time. There is no runtime color-conversion dependency.

Metadata uses an independently tuned native pair, `#9a9795` and `#605e5d`, to retain at least 4.5:1 contrast over both ordinary and selected sidebar rows. Inactive tabs and supporting labels use the secondary foreground. Preview actions stay aligned to the right edge.

The sidebar overrides these general tokens with neutral dark `#151515`, text `#d9d9d9`, hover `#272727`, and selection `#2d2d2d`, plus corresponding light colors. Highlights are 30 points high with 10-point corners. An unread completion uses an 8-point blue dot. Working uses a 10-point gray ring. Needs input uses a 23-point blue pill with 13-point text.

Long titles start moving after 500 ms at 30 points per second, pause for 800 ms, then restart. Movement stays inside the title area and resets on exit or geometry changes. A non-activating details card appears after 500 ms. It contains the full title, project, relative time and known metadata. Its width is at most 320 scaled points and its placement stays on screen. Reduce Motion keeps titles and the ring static. Hover does not select or acknowledge a conversation.

The linked-worktree and merged-PR glyphs are original small vector drawings. Other native controls use SF Symbols. A purple merge glyph requires verified GitHub state. Activity takes precedence in the final accessory position. Pin/Archive replace the accessories on hover or keyboard focus. Provider identity remains in thread details and accessibility labels.

Native keyboard focus keeps the macOS focus indicator. Disabled controls remain visible at 45% opacity and do not gain a hover fill. Error text uses the warning role and keeps its recovery action nearby. Destructive confirmations retain native dialog semantics.

## Review requirements

Compare blank Home, agent composer, selected project, worktree controls, terminals, splits, Files, both diff layouts, dialogs, menus, and recovery states at 1440×900, 1120×760, and 650×450 in both themes. Check icon optical weight, row alignment, padding, truncation, selected states, keyboard focus, and cancellation. Use disposable runtime/data roots and plain-language fixtures. Preserve the previous screenshot baseline.

The pass must preserve Cmd+N → Cmd+T, typed drafts, checkout scope, process identity, and terminal focus. Build and test evidence does not establish physical typing, IME composition, spoken VoiceOver, provider responses, or extended continuity. Those checks keep their existing pending status.

The completed native pass and measured build boundaries are recorded in [current status](status.md).

The interface specification records the final native table margins and row hierarchy. Its explicit geometry supersedes the initial row inset mapping.

## Chrome and syntax follow-up

The native interface uses the fixed header, native window buttons, declared shortcuts, and native code colors defined in the interface specification. Syntax roles reference the pinned CodeMirror highlighting mapping and Ember terminal colors. Native light-theme values are tuned independently for contrast. HighlighterSwift supplies language definitions.

The range adapter and its upstream dependency notices are recorded in [dependency provenance](../THIRD_PARTY.md). Shared AppKit controls implement Spookky's sidebar and tab strip.

## Component finish pass

The native interface includes an expanding composer, labeled worktree fields, full-height tabs, inline rename, outlined project folders, lifecycle indicators and compact preview overflow. Sidebar rendering does not request avatar downloads. Native file categories replace generic document icons. Code retains its native selection and fixed gutters, with 18-point rows and explicit comparison captions.

Verification boundaries are recorded in [current status](status.md).
