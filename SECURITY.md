# Security policy

## Supported releases

Spookky has no public binary release yet. The current main branch receives fixes during development. Preview releases may have known reliability limitations. The release notes will identify supported versions when binaries become available.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/Pamekitti/spookky/security/advisories/new). Do not publish credentials, private code, prompts, or an exploit in a public issue.

Include affected versions, a minimal reproduction, the impact, and any suggested correction. Remove unrelated personal data. This is a maintainer-run project; no response-time or bounty guarantee is offered.

## Runtime and update boundaries

Spookky launches installed shells and agent CLIs with their own permissions. It owns a separate tmux socket and checks session ownership before attachment or termination. It does not weaken CLI approval defaults or run project setup automatically.

Public installers must use Developer ID signing and Apple notarization. Updates require HTTPS and signed Sparkle feeds and archives. Signing credentials and private fixture output stay outside the repository. Release builds fail when the update public key or signing configuration is missing.
