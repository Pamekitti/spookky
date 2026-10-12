import {test, expect} from "@playwright/test";
for (const width of [1440,390,320]) {
  test(`layout and assets at ${width}px`, async ({page}) => {
    await page.setViewportSize({width,height:1000});
    const failures=[];
    page.on("response", response => {if(response.status()>=400) failures.push(response.url());});
    await page.goto("./");
    await expect(page.getByRole("heading",{level:1})).toContainText("native Mac workspace");
    await page.locator("footer").scrollIntoViewIfNeeded();
    await expect.poll(()=>page.locator("img").evaluateAll(images=>images.every(image=>image.complete && image.naturalWidth>0))).toBe(true);
    expect(failures).toEqual([]);
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await page.getByRole("button",{name:/Switch to/}).click();
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
    await page.getByRole("link",{name:"Privacy",exact:true}).click();
    await expect(page.getByRole("heading",{level:1})).toHaveText("Privacy");
  });
}
test("no installer is offered before a release",async({page})=>{
  await page.goto("./");
  await expect(page.locator("#download")).toHaveAttribute("href","https://github.com/Pamekitti/spookky");
  await expect(page.locator("#release-detail")).toContainText("No installer");
  await page.keyboard.press("Tab");
  await expect(page.getByRole("link",{name:"Skip to content"})).toBeFocused();
});
test("a published manifest supplies the download",async({page})=>{
  await page.route("**/release-manifest.json",route=>route.fulfill({json:{release:{version:"0.1.0-preview.1",build:100,channel:"preview",minimumOS:"14.0",architecture:"arm64",assetURL:"https://github.com/Pamekitti/spookky/releases/download/v0.1.0-preview.1/Spookky.dmg",bytes:1048576,sha256:"a".repeat(64),notesURL:"https://github.com/Pamekitti/spookky/releases/tag/v0.1.0-preview.1"}}}));
  await page.goto("./");
  await expect(page.locator("#download")).toContainText("Download Preview for Mac");
  await expect(page.locator("#release-detail")).toContainText("1.0 MB");
});
test("invalid release metadata retains the source link",async({page})=>{
  await page.route("**/release-manifest.json",route=>route.fulfill({json:{release:{version:"0.1.0",architecture:"arm64",assetURL:"https://invalid.example/download.dmg"}}}));
  await page.goto("./");
  await expect(page.locator("#download")).toHaveAttribute("href","https://github.com/Pamekitti/spookky");
});
