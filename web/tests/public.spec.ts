import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const sql = async (query: string) =>
	(
		await promisify(execFile)("psql", ["postgresql://localhost/flurrye2e", "-At", "-c", query])
	).stdout.trim();

test("public landing explains the engine and self-hosted core on desktop and mobile", async ({
	page,
}) => {
	await page.goto("/");
	await expect(
		page.getByRole("heading", {
			name: "Source control with Git at the edge, not the center.",
		}),
	).toBeVisible();
	await expect(page).toHaveTitle("Flurry — Source control with Git at the edge");
	await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
		"href",
		"http://127.0.0.1:4041/",
	);
	await expect(
		page.getByRole("heading", { name: "From first commit to shared history" }),
	).toBeVisible();
	await expect(page.getByRole("rowheader", { name: "Review" })).toBeVisible();
	await expect(
		page.getByText("Self-hosted. Public and private repositories. Apache 2.0."),
	).toBeVisible();
	await expect(page.getByRole("link", { name: "Docs", exact: true }).first()).toBeVisible();
	await page.screenshot({ path: "../artifacts/landing.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(
		true,
	);
	await page.screenshot({
		path: "../artifacts/landingmobile.png",
		fullPage: true,
	});
});

test("crawler files describe the public product and documentation", async ({ request }) => {
	const robots = await request.get("/robots.txt");
	expect(robots.ok()).toBe(true);
	expect(await robots.text()).toContain("Sitemap: https://flurry.codes/sitemap.xml");
	const sitemap = await (await request.get("/sitemap.xml")).text();
	expect(sitemap).toContain("https://flurry.codes/docs");
	for (const path of ["/llms.txt", "/llm.txt"]) {
		const response = await request.get(path);
		expect(response.ok()).toBe(true);
		expect(await response.text()).toContain("# Flurry");
	}
});

test("instance terms and privacy pages identify the operator boundary", async ({ page }) => {
	await page.goto("/terms");
	await expect(page.getByRole("heading", { name: "Instance terms" })).toBeVisible();
	await expect(page.getByRole("heading", { name: "Your repositories and content" })).toBeVisible();
	await page.goto("/privacy");
	await expect(page.getByRole("heading", { name: "Instance privacy" })).toBeVisible();
	await expect(
		page.getByText("The Flurry open-source project does not receive data", {
			exact: false,
		}),
	).toBeVisible();
});

test("instance owner configures storage safety limits", async ({ page }) => {
	const username = `quota${Date.now()}`;
	const password = "a long test password";
	const response = await page.request.post("/api/signup", {
		data: {
			name: "Quota tester",
			username,
			email: `${username}@example.test`,
			password,
		},
	});
	expect(response.status()).toBe(200);
	const previous = await sql("SELECT owner_id FROM instance WHERE id = 1");
	const limits = await sql(
		"SELECT file_bytes || ',' || project_storage_bytes || ',' || account_storage_bytes FROM instance WHERE id = 1",
	);
	try {
		await sql(
			`UPDATE instance SET owner_id = (SELECT id FROM users WHERE username = '${username}') WHERE id = 1`,
		);
		await page.goto("/admin");
		await expect(page.getByRole("heading", { name: "Administration", exact: true })).toBeVisible();
		await page.getByLabel("Maximum file size (MiB)").fill("64");
		await page.getByLabel("Per-project retained storage (GiB)").fill("8");
		await page.getByLabel("Per-account retained storage (GiB)").fill("32");
		await page.getByLabel("Current password").fill(password);
		await page.getByRole("button", { name: "Save changes" }).click();
		await expect(page.getByRole("status")).toHaveText("Saved");
		expect(await sql("SELECT file_bytes FROM instance WHERE id = 1")).toBe(String(64 * 1048576));
	} finally {
		const [file, project, account] = limits.split(",");
		await sql(
			`UPDATE instance SET owner_id = '${previous}', file_bytes = ${file}, project_storage_bytes = ${project}, account_storage_bytes = ${account} WHERE id = 1`,
		);
	}
});
