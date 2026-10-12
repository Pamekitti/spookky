# HighlighterSwift source

This directory vendors HighlighterSwift 3.1.0 from commit `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`.

Source: [smittytone/HighlighterSwift](https://github.com/smittytone/HighlighterSwift/tree/fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0).

Spookky adds `tokenRanges` in `Highlighter.swift`. It reads UTF-16 ranges and token scopes from the pinned highlight.js emitter instead of converting and scanning HTML. The original converter exceeded the large-preview timing target. Highlight.js, language definitions, themes, and the original attributed-text API remain upstream code. The added method relies on the pinned emitter structure; its output length is checked before returning ranges. The package omits the upstream test target because its tests are not vendored. Spookky tests source preservation and token ranges through its adapter.

The upstream [license](LICENCE.md) and asset notices are retained. Reapply and verify the conversion patch when updating the pinned source.

Vendored Swift blank lines and theme end-of-file whitespace are normalized. This changes formatting only.
