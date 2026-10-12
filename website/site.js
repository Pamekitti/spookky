"use strict";
const root = document.documentElement;
const themeButton = document.getElementById("theme");
const systemTheme = () => matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
function applyTheme(theme) {
  root.dataset.theme = theme;
  if (themeButton) themeButton.setAttribute("aria-label", `Switch to ${theme === "dark" ? "light" : "dark"} theme`);
  const image = document.getElementById("workspace-image");
  if (image) {
    image.src = `assets/workspace-${theme}.png`;
    image.closest("picture").querySelector("source").srcset = image.src;
  }
}
let savedTheme;
try { savedTheme = localStorage.getItem("spookky-site-theme"); } catch {}
applyTheme(["light", "dark"].includes(savedTheme) ? savedTheme : systemTheme());
themeButton?.addEventListener("click", () => {
  const theme = root.dataset.theme === "dark" ? "light" : "dark";
  applyTheme(theme);
  try { localStorage.setItem("spookky-site-theme", theme); } catch {}
});
matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
  try { if (localStorage.getItem("spookky-site-theme")) return; } catch {}
  applyTheme(systemTheme());
});
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
    const link = document.getElementById("release-notes");
    link.hidden = false; link.href = notes.href;
  } catch { /* The source link remains useful if release metadata is unavailable. */ }
}
showRelease();
