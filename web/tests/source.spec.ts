import { test, expect } from "@playwright/test";

test("import and explicit push controls show the source and selected landed revision", async ({
	page,
}) => {
	const username = `s${Date.now()}`;
	await page.request.post("/api/signup", {
		data: {
			name: "Source tester",
			username,
			email: `${username}@example.test`,
			password: "a long test password",
		},
	});
	const created = await page.request.post("/api/repositories", {
		data: { name: "linked" },
	});
	const repo = await created.json();
	const submitted = await page.request.post(
		`/api/repositories/${repo.id}/changesets`,
		{
			data: {
				base: null,
				message: "Imported files",
				files: [{ path: "readme.md", content: "Imported content\n" }],
			},
		},
	);
	const { review_id } = await submitted.json();
	await page.request.post(
		`/api/repositories/${repo.id}/reviews/${review_id}/approve`,
		{ data: {} },
	);
	const landing = await page.request.post(
		`/api/repositories/${repo.id}/reviews/${review_id}/land`,
		{ data: {} },
	);
	const { head } = await landing.json();
	const source = {
		url: "https://git.example.com/example/repo.git",
		branch: "main",
		commit: "a".repeat(40),
		status: "ready",
		operation: "import",
		error: null,
		message: "Imported 1 files",
		review_id: null,
		synced_at: new Date().toISOString(),
	};
	let pushRequests = 0;
	await page.route("**/api/imports", async (route) => {
		const body = route.request().postDataJSON();
		expect(body.url).toBe("https://git.example.com/example/repo");
		expect(body.visibility).toBe("private");
		expect(body.token).toBe("test transfer credential");
		await route.fulfill({ status: 202, json: repo });
	});
	await page.route(`**/api/repositories/${repo.id}/source`, (route) =>
		route.fulfill({ json: { source } }),
	);
	await page.route(
		`**/api/repositories/${repo.id}/source/push`,
		async (route) => {
			pushRequests++;
			expect(route.request().postDataJSON().head).toBe(head);
			expect(route.request().postDataJSON().token).toBe("write credential");
			await route.fulfill({
				status: 202,
				json: {
					source: { ...source, message: "Pushed landed changes to main" },
				},
			});
		},
	);
	await page.goto("/new");
	await page
		.getByRole("link", { name: "Import a repository", exact: true })
		.click();
	await page
		.getByLabel("Source repository URL")
		.fill("https://git.example.com/example/repo");
	await page.getByLabel("Repository name in Flurry").fill("linked");
	await page.getByText("Use a one-time access token").click();
	await page
		.locator("details.credentials")
		.getByLabel("Access token")
		.fill("test transfer credential");
	await page
		.getByRole("button", { name: "Import repository", exact: true })
		.click();
	await expect(page.getByText("Linked source", { exact: true })).toBeVisible();
	await expect(
		page.getByRole("link", { name: "git.example.com" }),
	).toHaveAttribute("href", "https://git.example.com/example/repo");
	await page
		.getByRole("button", { name: "Push to source", exact: true })
		.click();
	await expect(page.getByRole("dialog")).toContainText(head.slice(0, 10));
	await expect(page.getByRole("dialog")).toContainText(
		"Unlanded reviews are excluded",
	);
	await page.getByRole("button", { name: "Cancel", exact: true }).click();
	expect(pushRequests).toBe(0);
	await page
		.getByRole("button", { name: "Push to source", exact: true })
		.click();
	await page
		.getByRole("dialog")
		.getByLabel("Access token")
		.fill("write credential");
	await page
		.getByRole("dialog")
		.getByRole("button", { name: "Push to source", exact: true })
		.click();
	await expect(page.getByRole("dialog")).toHaveCount(0);
	expect(pushRequests).toBe(1);
	await page.screenshot({ path: "../artifacts/source.png", fullPage: true });
});

test("a public repository imports from its URL without a connection", async ({
	page,
}) => {
	const username = `p${Date.now()}`;
	await page.request.post("/api/signup", {
		data: {
			name: "Public importer",
			username,
			email: `${username}@example.test`,
			password: "a long test password",
		},
	});

	const submitted: { current: Record<string, string> | null } = { current: null };
	await page.route("**/api/imports", async (route) => {
		submitted.current = route.request().postDataJSON();
		await route.fulfill({
			status: 202,
			json: {
				id: "11111111-1111-4111-8111-111111111111",
				name: "public.project",
				description: "",
				visibility: "private",
				head: null,
				inserted_at: new Date().toISOString(),
				owner: { id: "owner", name: "Public importer", username },
			},
		});
	});

	await page.goto("/import");
	await expect(page.getByText("Public repositories need no account")).toBeVisible();
	await page
		.getByLabel("Source repository URL")
		.fill("https://git.example.com/owner/Public-Project.git");
	await page.getByLabel("Source repository URL").press("Tab");
	await expect(page.getByLabel("Repository name in Flurry")).toHaveValue(
		"public.project",
	);
	await page.screenshot({ path: "../artifacts/import-desktop.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({ path: "../artifacts/import-mobile.png", fullPage: true });
	await page.getByRole("button", { name: "Import repository" }).click();
	await expect.poll(() => submitted.current).not.toBeNull();
	expect(submitted.current?.url).toBe(
		"https://git.example.com/owner/Public-Project.git",
	);
	expect(submitted.current?.token).toBe("");
	expect(submitted.current?.connection_id).toBe("");
});
