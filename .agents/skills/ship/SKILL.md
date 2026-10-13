---
name: ship
description: Ship scoped Spookky changes through a pull request to main. Use for /ship, ship it, open a PR, or push and PR in this repository. Includes logical commits, rebase, verification, public-source audit, and PR creation.
---

# Ship Spookky through a PR

Finish with a feature branch pushed to origin and a PR targeting `main`. Commit scoped work before rebasing. Keep separate concerns in separate commits.

Read the repository's `AGENTS.md` and `docs/development.md`. Use `docs/lifecycle.md` for native development and installation boundaries. This repository targets `origin/main`; do not infer a different integration branch from a generic shipping skill.

An explicit shipping request authorizes scoped commits, a feature-branch push, and the PR. It does not authorize merging, publishing installers, or replacing the installed daily app. When selected implicitly, establish the requested action before external writes.

## Inspect the checkout

Find the repository root with `git rev-parse --show-toplevel`. Read the current branch, status, staged and unstaged diffs, recent commits, upstream, and existing PR. Check `gh auth status` before starting delivery.

Fetch origin and inspect its advertised refs. Confirm that `origin/main` exists. Keep unrelated edits and active sessions intact. Never use broad staging, automatic stashing, reset, or clean to make the checkout appear ready.

Use a descriptive `codex/<topic>` branch. If the current branch is an integration branch, an unrelated workspace name, or a branch already used by a merged PR, create or rename to an unused local feature branch. Preserve existing remote branches and unrelated PRs.

## Make logical commits

Treat uncommitted changes within the user's scope as work to commit, rather than a reason to stop shipping.

Before committing, give a short grouping plan. Group by behavior and review concern, with foundations before dependent features. Keep generated files with their generator changes and tests with the behavior they verify. Separate independent runtime fixes, features, release tooling, and documentation when the diff supports that split.

One commit is appropriate for one concern. Do not collapse several concerns into one commit for convenience. Do not invent extra commits for a single small change.

Stage named paths. For a file containing multiple concerns, stage selected hunks or construct a named index patch. Inspect `git diff --cached` before each commit. Never use `git add .` or `git add -A`.

Use the repository-configured human Git identity and concise conventional commit messages. Do not change authorship settings or add AI coauthor trailers. Project skills belong in a commit when the user requested their creation; private agent notes and transcripts do not.

## Rebase onto current main

Once scoped commits are complete and the checkout is clean:

```sh
git fetch origin main
git rebase origin/main
```

If unrelated dirty work prevents rebasing, preserve it and use an isolated checkout for the shipping branch. Do not stash another task's work automatically.

Resolve a conflict only when both sides' intended behavior are clear. Inspect the resulting diff and regenerate affected outputs. Ask for the specific decision when intent is ambiguous. Never skip a conflicting commit or discard work just to finish the rebase.

Do not rewrite an existing remote branch. If rebasing previously pushed commits requires a force push, use a new descriptive feature branch for the rebased work. Preserve the old remote branch and explain the new PR relationship.

## Verify the rebased result

Run the repository checker and whitespace check:

```sh
python3 scripts/check_repo.py
git diff --check origin/main...HEAD
```

Choose the remaining checks from the affected area and `docs/development.md`:

- Python tooling: `python3 -m unittest discover -s scripts -p 'test_*.py'`.
- Swift/runtime/native changes: `swift test`, relevant native builds, and bundle verification. Build Debug and Release sequentially when build settings or packaging change.
- Terminal input, focus, or lifecycle: verify the affected behavior in the owned development app with real terminals. Use isolated fixtures and retain process identities for continuity claims.
- Prototype changes: regenerate its preview and inspect desktop and narrow browser layouts.
- Website changes: use its documented browser tests.
- Workflow changes: inspect event gates, exact source revisions, permissions, and release approval boundaries. Local parsing is not a GitHub run.

Keep the installed daily app and other worktrees' runtimes intact. Do not repeat unchanged UI checks after a clean rebase. Recheck when a relevant code change, conflict resolution, or specific failure invalidates the prior evidence.

Fix failures within the authorized scope, then rerun the affected checks. If a required check cannot run, report its exact blocker and make the PR a draft when that gap prevents review readiness. Do not turn unexecuted checks into passing claims.

## Audit and push the public source

Inventory all advertised origin refs with `git ls-remote origin`. Inspect the outgoing commits and named paths. Run the public-source audit before pushing.

```sh
python3 scripts/check_public.py --history
```

If this shared local repository has private Git notes, preserve them. The checker rejects any local notes ref. Audit in an isolated clone of the shipping branch created with `--no-local --single-branch --no-tags` instead. This avoids copying unrelated local refs and their private history. Set that clone's origin to the actual public origin URL, fetch its advertised refs into a local audit namespace, and run the checker there. Include the shipping branch and all advertised public refs in the audit. Never delete private notes or use a mirror push to bypass this boundary.

Exclude private state, AI notes, session metadata, fixture output, credentials, and actual local checkout paths. Preserve dependency notices. Push only the feature branch, without force:

```sh
git push -u origin HEAD
```

If the remote branch has advanced, inspect and reconcile its commits without overwriting them. Revalidate affected checks before retrying.

## Open and verify the PR

Follow `.github/PULL_REQUEST_TEMPLATE.md`. Lead with the trigger and resulting behavior. Include actual checks, relevant native evidence, state/dependency changes, and remaining delivery limits. Keep fixture paths, terminal contents, and private evidence out of the public description.

Write the exact multiline description to an ignored file and use `gh pr create --base main --body-file <file>`. Use a concise title describing the final scope. If a matching PR already exists, update it within the authorized scope instead of creating a duplicate.

Verify the remote head equals the local head. Read back the PR's URL, base, head, state, and current checks. Report the PR link, commit count, local verification, and observed CI status. Opening a PR does not prove CI success, merge, installation, or an app update.
