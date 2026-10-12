# Terminal and process-owner decision

Status: implemented development stack; full compatibility and distribution acceptance remain pending.

## Decision

Use the pinned Ghostty native embedding with a private tmux runtime. The AppKit app hosts real terminal surfaces. One owned session per tab keeps live processes independent of their visible views.

A separate helper consumes a private launch request and calls exec with an argument array. Persistent operation receipts omit prompts, credentials, and terminal output. The runtime verifies ownership tokens before reattachment or termination. It never uses the user's default tmux server.

The native surface's startup directory is the private runtime directory. The helper retains authority over the shell or agent's actual working directory. This boundary avoids main-thread surface creation entering a potentially blocked project directory.

## Dependencies and costs

[The dependency record](../../Dependencies/README.md) pins Ghostty 1.3.1 and Zig 0.15.2. Xcode 27 requires a compatible installed SDK for Zig and a build-only archive-merging patch. Review these workarounds when upgrading the terminal engine.

Development uses installed tmux. A reproducible bundled runtime and its dependency notices remain distribution gates. SQLite stores workspace metadata separately from runtime receipts and provider history.

Keep at most two visible terminal surfaces plus one warm hidden surface. Releasing a view must preserve process identity and must not resend the initial prompt. Existing history, resize, and crash/reopen fixtures cover those boundaries.

The keyboard bridge adapts the pinned upstream native input behavior. Terminal bytes and provider prompt editors remain inside the terminal stack. Shared provider services may outlive a visible CLI frontend; closing a tab does not authorize stopping unrelated services.

## Acceptance

[Current status](../status.md) records targeted verification and unresolved gates. Human typing, composing input methods, provider responses, graphics/clipboard compatibility, extended continuity, and distribution need complete coverage.

Native event replay and rendered-pixel readiness do not establish physical keyboard-to-display latency. An account or policy block is separate from terminal compatibility. Metadata restore, live reattachment, and provider history resume have distinct authorities.

Keep the current stack while completing those checks. Change it only with a measured failure, a concrete replacement, and updated recovery and resource evidence.
