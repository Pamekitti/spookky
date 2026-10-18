# Native control specification

Spookky's native controls follow the geometry and interaction rules below. The launch, ownership, and recovery flows remain defined by [the product contract](product.md) and [flows](flows.md).

## Components

| Component | Geometry | Behavior |
| --- | --- | --- |
| Sidebar | 232-point column, 58-point rail, 8-point outer selection inset | Keeps project and workspace navigation compact |
| Project row | 28 points, 16-point icon slot, separate 28-point add action | Click toggles expansion; avatar becomes a chevron on hover/focus; add appears on hover/focus |
| Conversation row | 32 points, one title line, optional attention indicator | Static truncation, full tooltip, contextual actions on hover/focus, separate selection and keyboard focus |
| Tab | 40-point strip, muted inactive title, one selection/hover fill, 24-by-24-point close target | One shared bounded-width tab component uses a trailing separator; close appears on hover/focus |
| Composer | 800-point maximum width, 80-point minimum prompt, 13-point card radius | Always available on landing; optional prompt; supporting Terminal retains the agent draft |
| Files / Changes | Native file picker and a dedicated Changes view, 28-point list rows | Individual file tabs remain separate from change-review context |
| Preview | 40-point header, 28-point utility targets, muted notices, explicit diff signs | Read-only native selection/copy and Spookky's existing limit states remain intact |
| Menus and dialogs | Native NSMenu, NSAlert, and folder picker; shared type, path, warning, and destination styling | Uses macOS placement, focus, cancellation, and platform metrics |

Leading symbols use 14 points in a 16-point slot. Add and close symbols use 12-point regular weight with a centered 20-point hover fill and 5-point radius. Symbols retain their natural proportions. Compact buttons use 28-point targets and 8-point corner radii. The 24-point tab close target remains the only smaller utility target. Filled buttons have primary, secondary, and destructive roles; quiet controls draw only their interaction or selection state.

Dark hover and selection washes use the foreground at 7% and 10% opacity. Light washes use 4% and 6%. They composite over the current surface instead of using a separate opaque gray for every component. Light OKLCH reference values are converted to fixed sRGB values at development time. There is no runtime color-conversion dependency.

Metadata uses an independently tuned native pair, `#9a9795` and `#605e5d`, to retain at least 4.5:1 contrast over both ordinary and selected sidebar rows. Inactive tabs and supporting labels use the secondary foreground. Preview actions stay aligned to the right edge.

Native keyboard focus keeps the macOS focus indicator. Disabled controls remain visible at 45% opacity and do not gain a hover fill. Error text uses the warning role and keeps its recovery action nearby. Destructive confirmations retain native dialog semantics.

## Review requirements

Compare blank Home, agent composer, selected project, worktree controls, terminals, splits, Files, both diff layouts, dialogs, menus, and recovery states at 1440×900, 1120×760, and 650×450 in both themes. Check icon optical weight, row alignment, padding, truncation, selected states, keyboard focus, and cancellation. Use disposable runtime/data roots and plain-language fixtures. Preserve the previous screenshot baseline.

The pass must preserve Cmd+N → Cmd+T, typed drafts, checkout scope, process identity, and terminal focus. Build and test evidence does not establish physical typing, IME composition, spoken VoiceOver, provider responses, or extended continuity. Those checks keep their existing pending status.

The completed native pass and measured build boundaries are recorded in [current status](status.md).

The interface specification records the final native table margins and row hierarchy. Its explicit geometry supersedes the initial row inset mapping.

## Chrome and syntax follow-up

The native interface uses the fixed header, centered rail, declared shortcuts, and native code colors defined in the interface specification. Syntax roles reference the pinned CodeMirror highlighting mapping and Ember terminal colors. Native light-theme values are tuned independently for contrast. HighlighterSwift supplies language definitions.

The range adapter and its upstream dependency notices are recorded in [dependency provenance](../THIRD_PARTY.md). Shared AppKit controls implement Spookky's sidebar and tab strip.

## Component finish pass

The native interface includes an expanding composer, labeled worktree fields, full-height tabs, inline rename, project avatars with monogram fallbacks, lifecycle indicators and compact preview overflow. Native file categories replace generic document icons. Code retains its native selection and fixed gutters, with 18-point rows and explicit comparison captions.

Native controls, cached GitHub owner avatars, generated text monograms and SF Symbols implement these roles. Avatar loading permits two concurrent downloads, limits each response to 512 KiB, and decodes images to 64 pixels. The cache holds 32 images in memory and at most 10 MiB on disk. Images refresh after seven days; failed refreshes retain stale images and wait an hour before retrying on demand.

Verification boundaries are recorded in [current status](status.md).
