import {test, expect} from "@playwright/test";
const sourceURL = "https://github.com/Pamekitti/spookky/archive/refs/heads/main.zip";
for (const width of [1440,390,320]) {
  test(`layout and assets at ${width}px`, async ({page},testInfo) => {
    await page.setViewportSize({width,height:1000});
    const failures=[];
    page.on("response", response => {if(response.status()>=400) failures.push(response.url());});
    await page.emulateMedia({colorScheme:"dark"});
    await page.goto("./");
    await expect(page.getByRole("heading",{level:1})).toContainText("native Mac workspace");
    await page.locator("footer").scrollIntoViewIfNeeded();
    await expect.poll(()=>page.locator("img").evaluateAll(images=>images.every(image=>image.complete && image.naturalWidth>0))).toBe(true);
    expect(failures).toEqual([]);
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await expect(page.locator("#workspace-full")).toHaveAttribute("href","assets/workspace-dark.png");
    await page.screenshot({path:testInfo.outputPath("dark.png"),fullPage:true});
    await page.emulateMedia({colorScheme:"light"});
    await expect(page.locator("#workspace-full")).toHaveAttribute("href","assets/workspace-light.png");
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await page.screenshot({path:testInfo.outputPath("light.png"),fullPage:true});
    await page.getByRole("link",{name:"Privacy",exact:true}).click();
    await expect(page.getByRole("heading",{level:1})).toHaveText("Privacy");
  });
}
test("source downloads directly before an installer is available",async({page})=>{
  await page.goto("./");
  await expect(page.locator("#download")).toHaveAttribute("href",sourceURL);
  await expect(page.locator("#download")).toHaveText("Download source ZIP ↓");
  await expect(page.locator("#release-detail")).toContainText("Build required. No public Mac installer");
  await page.keyboard.press("Tab");
  await expect(page.getByRole("link",{name:"Skip to content"})).toBeFocused();
  await page.route(sourceURL, route=>route.fulfill({
    contentType:"application/zip",
    headers:{"Content-Disposition":'attachment; filename="spookky-main.zip"'},
    body:Buffer.from("PK\x05\x06"+"\x00".repeat(18),"binary")
  }));
  const downloading = page.waitForEvent("download");
  await page.locator("#download").click();
  expect((await downloading).suggestedFilename()).toBe("spookky-main.zip");
});
test("a published manifest supplies the download",async({page})=>{
  await page.route("**/release-manifest.json",route=>route.fulfill({json:{release:{version:"0.1.0-preview.1",build:100,channel:"preview",minimumOS:"14.0",architecture:"arm64",assetURL:"https://github.com/Pamekitti/spookky/releases/download/v0.1.0-preview.1/Spookky.dmg",bytes:1048576,sha256:"a".repeat(64),notesURL:"https://github.com/Pamekitti/spookky/releases/tag/v0.1.0-preview.1"}}}));
  await page.goto("./");
  await expect(page.locator("#download")).toContainText("Download Preview for Mac");
  await expect(page.locator("#download")).toHaveAttribute("href","https://github.com/Pamekitti/spookky/releases/download/v0.1.0-preview.1/Spookky.dmg");
  await expect(page.locator("#release-detail")).toContainText("1.0 MB");
  await expect(page.locator("#secondary-action")).toHaveText("GitHub");
  await expect(page.locator("#secondary-action")).toHaveAttribute("href","https://github.com/Pamekitti/spookky");
});
test("invalid release metadata retains the source link",async({page})=>{
  await page.route("**/release-manifest.json",route=>route.fulfill({json:{release:{version:"0.1.0",architecture:"arm64",assetURL:"https://invalid.example/download.dmg"}}}));
  await page.goto("./");
  await expect(page.locator("#download")).toHaveAttribute("href",sourceURL);
});
test("source download works without JavaScript",async({browser,baseURL})=>{
  const context=await browser.newContext({javaScriptEnabled:false,baseURL});
  const page=await context.newPage();
  await page.goto("./");
  await expect(page.getByRole("link",{name:"Download source ZIP"})).toHaveAttribute("href",sourceURL);
  await context.close();
});
test("unavailable release metadata keeps the download usable",async({page})=>{
  await page.route("**/release-manifest.json",route=>route.abort());
  await page.goto("./");
  await expect(page.locator("#download")).toHaveAttribute("href",sourceURL);
  await expect(page.locator("#secondary-action")).toHaveText("Build from source");
});
