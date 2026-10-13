# Daily development lifecycle

Use the installed Spookky app to work on Spookky. Test changes in a development app built from the worktree containing those changes. Promote reviewed main builds through the release path.

## Daily app and development apps

| App | Source | State and runtime | Updates |
| --- | --- | --- | --- |
| Daily Spookky in Applications | A tested main build | Production database and private terminal socket | Local replacement now; Sparkle after signed delivery is verified |
| Spookky Dev for a worktree | That worktree, including its edits | Separate database and terminal socket for that checkout | Rebuild that checkout explicitly |
| Disposable native fixture | Chosen test build | Explicit fixture overrides | Never replaces the daily app |

The daily app remains open while development apps run. Each worktree keeps its own DerivedData and Swift build outputs. No shared mutable build directory is configured.

## Change and test

1. Open or create a Spookky workspace anchored to the checkout you want to change.
2. Make the change in that checkout. Preserve unrelated work.
3. For a native change, run the checks and open its development app:

   ```sh
   python3 scripts/check_repo.py
   swift test
   python3 scripts/dev.py run
   ```

4. Verify the affected interaction once with real terminal input, focus, and lifecycle when relevant. Use the affected [acceptance requirements](acceptance.md) without repeating unchanged verification. Documentation changes need the repository checker only. Python and website changes have their own checks in [development](development.md).
5. Quit that development app before rebuilding it. Choose Keep sessions running when you need to reattach its terminals after the rebuild.
6. Use `/ship` for logical commits, rebase, public audit, push, and PR creation. Include the tested commit, checks, and remaining limits. Merge after the required checks pass.

Dependencies require the explicit first-build steps in [development setup](development.md). The run command reports a missing dependency and does not install it automatically.

Run the same command from a second worktree to test both changes at once. The app's development name includes its checkout folder. The bundle identifier, database folder, and socket root use a 16-character hash of the canonical checkout path. A symlink to the same checkout has the same identity. A moved checkout gets a new development identity. Its old data remains available for deliberate recovery.

Debug and Release in one checkout share development state. Run one configuration at a time. The launcher refuses to rebuild while either configuration in that checkout is running. Helper packaging replaces executable files atomically so retained terminal processes keep their existing files during a rebuild. Worktree isolation does not isolate provider credentials, provider history, project services, ports, or databases belonging to the project under development.

Useful commands:

```sh
python3 scripts/dev.py info
python3 scripts/dev.py build
python3 scripts/dev.py run --configuration Release
```

The info command prints the exact bundle identity, app path, database folder, and runtime root without building or starting anything. Xcode builds also derive their database and socket roots from the embedded source checkout. Use the launcher for a distinct macOS application identity per worktree.

Existing shared development data is preserved. New checkout-specific builds do not automatically import it. Production ignores development root overrides.

## Merge and update the daily app now

The PR runs affected tests before merge. Main's Checks workflow runs source checks without repeating native or browser builds. After it passes, prepare a local installer from an isolated main checkout:

```sh
.cache/release-tools/bin/python scripts/prepare_main_update.py --open
```

Create the pinned release-tools environment as described in [releasing](releasing.md) before the first run. Preparation fetches origin/main, creates a detached checkout, runs source and Swift checks, builds native Release, audits the bundle, and packages a local DMG. It preserves the checkout and artifacts under ignored `.cache/` folders. It does not change your working branch or installed app.

A failed build can retry using the retained clean checkout and its build caches. Changed source and existing installer output require inspection before reuse.

Inspect the candidate before installation. Verify the changed interaction in the development app built in the printed main checkout. Quit that app through its normal session choices. The packaged installer uses the production identity and carries the exact main commit in its manifest.

Quit the daily app with Keep sessions running. Replace Spookky in Applications from the DMG, retain the previous installer for recovery, and reopen it. Verify drafts, workspace scope, and attachment to surviving terminals. This replacement requires an explicit installation step. Local installers have automatic updates disabled.

This local path stays on your Mac. Do not upload unsigned installers to the public repository's Actions artifacts or public releases.

## Signed merge-to-update path

A release PR increases the build number in `release.json`, updates the version when appropriate, regenerates the Xcode project, and commits `docs/releases/<version>.md`. Ordinary code PRs can merge without requesting a release.

Set repository variable `SPOOKKY_AUTO_RELEASE=true` after the signing credentials are configured. A successful main push's Checks run then triggers signed release preparation. It uses the checked commit, skips an existing tag or an already-published build, and preserves the protected release environment's approval requirement. Preview tags use `v<version>-preview.<build>`. Manual preparation remains available.

Preparation creates a signed, notarized draft. Installation and actual Sparkle update tests gate publication. Once those pass, publish the immutable release and promote its signed feed and download manifest through the website PR described in [releasing](releasing.md). The installed signed app can then find the update through its existing update controls. User consent and postponed restarts remain intact.

The current local daily app needs one manual installation of a signed build to enter this path. It has no update key or feed. A main merge alone cannot make that installed version update automatically.

On 13 October 2026, the live release environment required maintainer approval and had no signing secrets. The automatic-release variable was absent. Signed automatic delivery remains deferred while private installers are in use. Remaining signed installation, update, and compatibility gates are recorded in [status](status.md).
