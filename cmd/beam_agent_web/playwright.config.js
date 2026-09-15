const { defineConfig } = require("@playwright/test");
module.exports = defineConfig({
  testDir: "./test/browser",
  testIgnore: "**/observatory*.spec.js",
  workers: 1,
  timeout: 30000,
  use: {
    baseURL: "http://localhost:4174",
    channel: "chrome",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "MIX_ENV=test mix run --no-start scripts/browser_fixture.exs",
    url: "http://localhost:4174",
    timeout: 120000,
    reuseExistingServer: false,
  },
});
