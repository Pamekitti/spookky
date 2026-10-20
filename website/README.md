# Spookky website

The website is a static GitHub Pages site. It uses real native screenshots and original artwork. It has no analytics or third-party browser scripts.

## Preview and check

```sh
python3 scripts/serve_website.py
```

Use the printed local address. For browser checks:

```sh
cd website
npm ci
npx playwright install chromium
npm test
```

The checks cover desktop, 390px, 320px, system light/dark appearance, keyboard access, screenshot links, release metadata, and downloads without JavaScript.

## Release availability

`release-manifest.json` contains `{"release":null}` until a public installer passes its release gates. The primary action downloads the current main branch as a source ZIP, with build instructions beside it. This plain link works without JavaScript or a metadata request. The page states that a build is required.

A verified manifest changes the button to a direct Mac installer download with the version, requirements, and size. The secondary action then links to GitHub. Missing or invalid metadata keeps the source download available.

Follow [the release procedure](../docs/releasing.md) before publishing metadata or the signed updater feed. Never add a placeholder installer URL.

## Artwork

On macOS, `node website/tools/render-brand.mjs --social-only` updates the social image. Omit the flag to also render the DMG background with paired standard/Retina representations. `tiffutil` combines the DMG representations. The app icon is stored in `App/Assets.xcassets`.

The original ghost mascot stays beside the wordmark. The page follows the system color theme without storing a browser preference.

The workspace images were captured on 19 October 2026 from the real native app at 1440 × 900 points and 100% zoom. The Retina images are 2880 × 1800 pixels. They show a disposable Northstar project, three real Codex CLI sessions, and the selected session's search empty-state change. Codex CLI 0.163.0 made the 20-line addition and passed `node --check app.js`; the other two sessions are idle. App metadata, provider history, and the private runtime are isolated from daily work.

The capture uses the locally packaged 0.1.4 (104) app from source `86e3ef96b2506c8c16d104bf1172914d5f994989`. Its native source matches main at `b3e1bd48b5859fc60664e51acbc8d08a66f62a26`. Both appearances show the same state. The terminal retains its configured dark theme in the light app appearance. The captures include the operating system's window-sharing indicator. Terminal text and native controls have not been composited or altered.

On narrow screens, the image focuses on the diff; its image link and caption open the complete capture. These images establish appearance, not performance, recovery, or full provider compatibility. The HTML prototype is not a source of native compatibility evidence.

## Deployment

`python3 scripts/build_website.py` creates the filtered `.cache/site` directory. The Pages workflow deploys this directory from main. Do not deploy the raw website directory with its development dependencies and tools.
