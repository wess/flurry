import { expect, test } from "@playwright/test";

test("snippets create multi-file revisions with syntax highlighting and clean profiles", async ({
	page,
}) => {
	const username = "snip" + Date.now();
	await page.request.post("/api/signup", {
		data: {
			name: "Snippet author",
			username,
			email: username + "@example.test",
			password: "a long test password",
		},
	});

	await page.goto("/snippets/new");
	await page.getByLabel("Title").fill("Typed request verifier");
	await page.getByLabel("Description (optional)").fill("A compact verification example.");
	await page.getByLabel("Visibility").selectOption("public");
	await page.getByLabel("File 1 name").fill("request.ts");
	await page.getByLabel("request.ts content").fill(
		"export const verify = (id: string) => id.length > 0;\n",
	);
	await page.getByRole("button", { name: "Add file" }).click();
	await page.getByLabel("File 2 name").fill("example.html");
	await page.getByLabel("example.html content").fill(
		"<script>window.untrusted = true;</script>\n",
	);
	await page.getByRole("button", { name: "Create snippet" }).click();

	await expect(page.getByRole("heading", { name: "Typed request verifier" })).toBeVisible();
	await expect(page.locator(".hljs-keyword", { hasText: "const" })).toBeVisible();
	await expect(page.locator(".snippetfile script")).toHaveCount(0);
	await expect(page.getByText("request.ts", { exact: true })).toBeVisible();
	await page.screenshot({
		path: "../.impeccable/review/snip-desktop.png",
		fullPage: true,
	});
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({
		path: "../.impeccable/review/snip-mobile.png",
		fullPage: true,
	});
	expect(
		await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
	).toBe(true);

	await page.setViewportSize({ width: 1280, height: 900 });
	await page.getByRole("link", { name: "Edit", exact: true }).click();
	await page.getByLabel("Revision note (optional)").fill("Require a non-empty subject");
	await page.getByLabel("request.ts content").fill(
		"export const verify = (id: string) => id.trim().length > 0;\n",
	);
	const saved = page.waitForResponse(
		(response) =>
			response.request().method() === "PATCH" &&
			response.url().includes("/api/snippets/"),
	);
	await page.getByRole("button", { name: "Save revision" }).click();
	const savedResponse = await saved;
	const savedBody = await savedResponse.json();
	expect(savedResponse.ok(), JSON.stringify(savedBody)).toBeTruthy();
	expect(savedBody.version).toBe(2);
	await expect(page.getByText("Revision 2", { exact: true })).toBeVisible();
	await expect(page.getByText("Require a non-empty subject", { exact: true })).toBeVisible();

	await page.goto("/" + username);
	await expect(page.getByRole("heading", { name: "Snippet author" })).toBeVisible();
	await expect(page).toHaveURL(new RegExp("/" + username + "$"));

	await page.goto("/login");
	await page.getByLabel("Username or email").fill(username);
	await page.getByLabel("Password", { exact: true }).fill("a long test password");
	await page.getByRole("button", { name: "Sign in", exact: true }).click();
	await expect(page.getByRole("link", { name: username, exact: true })).toBeVisible();
});
