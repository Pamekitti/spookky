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

The six checks cover desktop, 390px, 320px, keyboard access, and release metadata.

## Release availability

`release-manifest.json` contains `{"release":null}` until a public installer passes its release gates. The primary action then points to the source. A verified manifest changes it to a Mac download with the version, requirements, size, and checksum.

Follow [the release procedure](../docs/releasing.md) before publishing metadata or the signed updater feed. Never add a placeholder installer URL.

## Artwork

On macOS, `node website/tools/render-brand.mjs` renders the social image and a DMG background with paired standard/Retina representations. `tiffutil` combines the DMG representations. The app icon is stored in `App/Assets.xcassets`.

The workspace images show native development builds using generated demo files. The HTML prototype is not a source of native compatibility evidence.

## Deployment

`python3 scripts/build_website.py` creates the filtered `.cache/site` directory. The Pages workflow deploys this directory from main. Do not deploy the raw website directory with its development dependencies and tools.
