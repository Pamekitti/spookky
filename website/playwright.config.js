import {defineConfig} from "@playwright/test";
export default defineConfig({testDir:"tests", reporter:"list", use:{baseURL:"http://127.0.0.1:48768/spookky/"}, webServer:{command:"python3 ../scripts/serve_website.py",url:"http://127.0.0.1:48768/spookky/",reuseExistingServer:true},outputDir:"../.cache/website-tests"});
