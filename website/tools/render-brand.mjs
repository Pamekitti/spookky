import {chromium} from "@playwright/test";
import {readFile,mkdir} from "node:fs/promises";
import {fileURLToPath} from "node:url";
import path from "node:path";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"../..");
const mascot="data:image/png;base64,"+(await readFile(path.join(root,"website/assets/mascot.png"))).toString("base64");
const browser=await chromium.launch();
try {
  const page=await browser.newPage({viewport:{width:1200,height:630},deviceScaleFactor:1});
  await page.setContent(`<style>*{box-sizing:border-box}body{margin:0;background:#151110;color:#eae8e6;font-family:-apple-system,BlinkMacSystemFont,sans-serif}.card{width:1200px;height:630px;padding:76px;position:relative}h1{font-size:80px;letter-spacing:-4px;font-weight:600;margin:0 0 28px}p{font-size:32px;line-height:1.4;max-width:610px;margin:0;color:#c7c2c0}small{position:absolute;bottom:65px;color:#d9b9ed;font-size:19px;letter-spacing:1px}img{position:absolute;right:35px;top:60px;width:440px;height:440px}</style><div class=card><h1>Spookky</h1><p>A native Mac workspace<br>for terminals and<br>coding agents.</p><small>MADE FOR THE MAC. OPEN SOURCE.</small><img src="${mascot}" alt=""></div>`);
  await page.locator("img").evaluate(image=>image.decode());
  await page.screenshot({path:path.join(root,"website/assets/social.png")});
  await mkdir(path.join(root,".cache/brand"),{recursive:true});
  await page.setViewportSize({width:660,height:420});
  await page.setContent(`<style>body{margin:0;background:#f9f9fa;color:#151110;font-family:-apple-system,BlinkMacSystemFont,sans-serif}.art{width:660px;height:420px;position:relative;padding:34px;box-sizing:border-box}h1{font-size:32px;letter-spacing:-1px;margin:0 0 8px;font-weight:550}p{font-size:13px;color:#4a4847;margin:0}.arrow{position:absolute;top:183px;left:305px;font-size:38px;color:#75507b}img{position:absolute;bottom:22px;right:26px;width:90px;height:90px}small{position:absolute;left:34px;bottom:35px;font-size:11px;color:#4a4847}</style><div class=art><h1>Spookky</h1><p>Drag Spookky into Applications, then open it there.</p><span class=arrow>→</span><small>A little room for parallel work.</small><img src="${mascot}" alt=""></div>`);
  await page.locator("img").evaluate(image=>image.decode());
  await page.screenshot({path:path.join(root,"website/assets/dmg-background.png")});
  const retina=await browser.newPage({viewport:{width:660,height:420},deviceScaleFactor:2});
  await retina.setContent(await page.content());
  await retina.locator("img").evaluate(image=>image.decode());
  await retina.screenshot({path:path.join(root,"website/assets/dmg-background@2x.png")});
  await promisify(execFile)("tiffutil", ["-cathidpicheck", path.join(root,"website/assets/dmg-background.png"), path.join(root,"website/assets/dmg-background@2x.png"), "-out", path.join(root,"website/assets/dmg-background.tiff")]);
  console.log("Rendered social card and Retina DMG background.");
} finally {await browser.close();}
