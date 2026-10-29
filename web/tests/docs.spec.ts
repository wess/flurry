import { test, expect } from "@playwright/test";

test("documentation covers browser, Git, fsc, API, automation, MCP, and security", async ({
	page,
}) => {
	await page.goto("/docs");
	await expect(page).toHaveTitle("Flurry documentation — Git, fsc, API, MCP, and automation");
	await expect(page.getByRole("heading", { name: "Build with Flurry" })).toBeVisible();
	await expect(page.getByRole("navigation", { name: "Documentation" })).toBeVisible();
	await expect(page.getByRole("link", { name: "Self-hosting", exact: true })).toBeVisible();

	await page.getByRole("link", { name: "HTTP API", exact: true }).click();
	await expect(page).toHaveURL(/\/docs\/api$/);
	await expect(page).toHaveTitle("HTTP API — Flurry documentation");
	await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
		"href",
		"http://127.0.0.1:4041/docs/api",
	);
	await expect(page.getByRole("heading", { name: "HTTP API" })).toBeVisible();
	await expect(page.getByText("Idempotency-Key", { exact: false }).first()).toBeVisible();
	await page.locator("details").filter({ hasText: "Changes and reviews" }).click();
	await expect(page.getByText("/repositories/{id}/changesets", { exact: true })).toBeVisible();
	await page.screenshot({
		path: "../.impeccable/review/desktop.png",
		fullPage: true,
	});

	await page.setViewportSize({ width: 390, height: 844 });
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(
		true,
	);
	await expect(page.getByRole("navigation", { name: "Documentation" })).toBeVisible();
	await page.screenshot({
		path: "../.impeccable/review/mobile.png",
		fullPage: true,
	});
});

test("OpenAPI and crawler references expose the documentation", async ({ request }) => {
	const response = await request.get("/openapi.json");
	expect(response.ok()).toBe(true);
	const spec = await response.json();
	expect(spec.openapi).toBe("3.1.0");
	expect(spec.paths["/api/repositories/{id}/changesets"].post).toBeTruthy();
	expect(spec.paths["/api/repositories/{id}/webhooks"].post).toBeTruthy();
	expect(spec.components.securitySchemes.bearerToken).toBeTruthy();

	const sitemap = await (await request.get("/sitemap.xml")).text();
	expect(sitemap).toContain("https://flurry.codes/docs/api");
	expect(sitemap).toContain("https://flurry.codes/docs/self-hosting");
	const llms = await (await request.get("/llms.txt")).text();
	expect(llms).toContain("[Documentation](https://flurry.codes/docs)");
	expect(llms).toContain("[Source repository](https://github.com/wess/flurry)");
});
