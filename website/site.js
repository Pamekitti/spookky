"use strict";

const appearance = matchMedia("(prefers-color-scheme: light)");
function updateScreenshotLinks() {
  const source = `assets/workspace-${appearance.matches ? "light" : "dark"}.png`;
  for (const id of ["workspace-full", "workspace-caption"]) {
    const link = document.getElementById(id);
    if (link) link.href = source;
  }
}
updateScreenshotLinks();
appearance.addEventListener("change", updateScreenshotLinks);

async function showRelease() {
  const download = document.getElementById("download");
  if (!download) return;
  try {
    const response = await fetch("release-manifest.json", {cache: "no-cache"});
    if (!response.ok) return;
    const {release} = await response.json();
    if (!release || !/^\d+\.\d+\.\d+(?:-preview\.\d+)?$/.test(release.version) || !Number.isSafeInteger(release.bytes) || release.bytes <= 0 || release.architecture !== "arm64" || !/^\d+\.\d+(?:\.\d+)?$/.test(release.minimumOS) || !/^[a-f0-9]{64}$/.test(release.sha256)) return;
    const asset = new URL(release.assetURL);
    const notes = new URL(release.notesURL);
    if (asset.origin !== "https://github.com" || !asset.pathname.startsWith("/Pamekitti/spookky/releases/download/") || !asset.pathname.endsWith(".dmg") || notes.origin !== "https://github.com" || !notes.pathname.startsWith("/Pamekitti/spookky/releases/tag/")) return;
    download.href = asset.href;
    download.textContent = release.channel === "preview" ? "Download Preview for Mac ↓" : "Download for Mac ↓";
    document.getElementById("release-detail").textContent = `${release.version} · Apple Silicon · macOS ${release.minimumOS}+ · ${(release.bytes / 1048576).toFixed(1)} MB`;
    const secondary = document.getElementById("secondary-action");
    secondary.href = "https://github.com/Pamekitti/spookky";
    secondary.textContent = "GitHub";
    const link = document.getElementById("release-notes");
    link.hidden = false; link.href = notes.href;
  } catch { /* The source link remains useful if release metadata is unavailable. */ }
}
showRelease();
