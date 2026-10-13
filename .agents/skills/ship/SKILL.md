---
name: ship
description: Ship scoped Spookky changes through a pull request to main. Use for /ship, ship it, open a PR, or push and PR. Makes logical commits, rebases, verifies affected behavior, audits public source, and opens the PR.
---

# Ship Spookky

An explicit shipping request authorizes scoped commits, feature-branch push, and PR creation. Installation and merging need separate authorization.

1. Inspect status, diff, branch, upstream, and existing PR. Confirm GitHub authentication. Preserve unrelated work and sessions.
2. Use an unused `codex/<topic>` branch. Commit scoped dirty work in logical groups, foundations first. Keep tests and generated files with their feature. Stage named paths or hunks and inspect the index. Preserve configured human authorship without AI trailers.
3. Fetch and rebase onto `origin/main` after committing. Preserve unrelated dirty work through an isolated checkout. Resolve only clear conflicts. Never skip commits, reset work, auto-stash another task, or force push. Use a new branch if rebasing pushed history would require rewriting the remote.
4. Run `python3 scripts/check.py --plan`, then `python3 scripts/check.py`. Matching passed receipts survive metadata-only commits and unchanged rebases. Use `--force` when external runtime changes invalidate evidence. Verify affected native input/focus/lifecycle once in the owned dev app. Automated receipts do not replace GUI evidence.
5. Inventory advertised origin refs and audit outgoing public source with `python3 scripts/check_public.py --history`. Preserve private Git notes. If they block the checker, audit an isolated `--no-local --single-branch --no-tags` clone containing the outgoing head and advertised public refs. Never publish notes or mirror-push.
6. Push only the feature branch. Follow `.github/PULL_REQUEST_TEMPLATE.md` and use `gh pr create --base main --body-file <ignored-file>`. Update a matching PR within scope. Verify its base, exact local/remote head, state, and checks.

Fix scoped failures and rerun affected checks. Report exact blockers; use a draft if required verification is missing. Read [development](../../../docs/development.md) and [lifecycle](../../../docs/lifecycle.md) only as needed. Report the PR link, commit count, local checks, and observed CI status.

When merging is authorized, re-query required checks, review threads, mergeability, and head. Use `gh pr merge --match-head-commit <sha>` with the allowed merge method. This repository currently permits squash merges. Keep logical review commits on the PR and never bypass protection.
