import { defineConfig } from "@playwright/test";

export default defineConfig({
	testDir: "./tests",
	workers: 1,
	retries: 0,
	timeout: 30000,
	outputDir: "../artifacts/browser",
	use: {
		baseURL: "http://127.0.0.1:4041",
		browserName: "chromium",
		viewport: { width: 1280, height: 900 },
		trace: "retain-on-failure",
	},
	webServer: {
		command: "cd .. && mix flurry.setup && mix run --no-halt",
		url: "http://127.0.0.1:4041/api/health",
		reuseExistingServer: false,
		timeout: 60000,
		env: {
			DATABASE_URL: "postgresql://localhost/flurrye2e",
			PORT: "4041",
			FLURRY_STORE: "./data/e2eobjects",
			FLURRY_RATE_LIMIT: "1000",
			MIX_ENV: "dev",
		},
	},
});
