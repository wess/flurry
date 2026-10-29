import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";

test("profiles, private repositories, review, landing and immutable history", async ({
	page,
	playwright,
}) => {
	const errors: string[] = [];
	page.on("pageerror", (error) => errors.push(error.message));
	const username = `u${Date.now()}`;
	await page.goto("/signup");
	await page.getByLabel("Display name").fill("Wess Tester");
	await page.getByLabel("Username").fill(username);
	await page.getByLabel("Email").fill(`${username}@example.test`);
	await page.getByLabel("Password").fill("a long test password");
	await page
		.getByRole("button", { name: "Create account", exact: true })
		.click();
	await expect(
		page.getByRole("heading", { name: "Wess Tester" }),
	).toBeVisible();
	await page.getByRole("link", { name: "Edit profile" }).click();
	await page.getByLabel("Bio").fill("Building small, useful tools.");
	await page.getByLabel("Location").fill("Virginia");
	await page.getByLabel("Website").fill("https://wess.io");
	await page.getByRole("button", { name: "Save profile" }).click();
	await expect(page.getByText("Building small, useful tools.")).toBeVisible();
	await page
		.getByRole("link", { name: "New repository", exact: true })
		.first()
		.click();
	await page.getByLabel("Repository name").fill("flurry");
	await page
		.getByLabel("Description")
		.fill("A small home for code and changes.");
	await page
		.getByRole("button", { name: "Create repository", exact: true })
		.click();
	await expect(
		page.getByRole("heading", { name: "Start this repository" }),
	).toBeVisible();
	const repo = page.url().match(/repositories\/([^/?#]+)/)![1]!;
	const anonymous = await playwright.request.newContext({
		baseURL: "http://127.0.0.1:4041",
	});
	expect((await anonymous.get(`/api/repositories/${repo}`)).status()).toBe(404);
	await page.getByRole("button", { name: "New change", exact: true }).click();
	await page.getByLabel("Change message").fill("Add the first readme");
	await page.getByLabel("File path 1", { exact: true }).fill("readme.md");
	await page
		.getByLabel("File contents 1")
		.fill("# Flurry\n\nSource control, kept simple.\n");
	await page.getByRole("button", { name: "Submit for review" }).click();
	await expect(
		page.getByRole("heading", { name: "Add the first readme" }),
	).toBeVisible();
	await page.getByLabel("Add a comment").fill("Ready for the first landing.");
	await page.getByRole("button", { name: "Comment", exact: true }).click();
	await expect(page.getByText("Ready for the first landing.")).toBeVisible();
	await page
		.getByRole("button", { name: "Approve change", exact: true })
		.click();
	await expect(
		page.getByRole("button", { name: "Land change", exact: true }),
	).toBeVisible();
	await page.getByRole("button", { name: "Land change", exact: true }).click();
	await expect(page.getByText("Landed on main as")).toBeVisible();
	await mkdir("../artifacts", { recursive: true });
	await page.screenshot({ path: "../artifacts/review.png", fullPage: true });
	await page.getByRole("link", { name: "Files", exact: true }).click();
	await page.getByText("Clone repository").click();
	await expect(page.locator(".clonecommands code").first()).toContainText(
		`/repositories/${repo}.git`,
	);
	await page.getByRole("link", { name: "Issues", exact: true }).click();
	await page.getByRole("button", { name: "New issue", exact: true }).click();
	await page.getByLabel("Title").fill("Document the release process");
	await page
		.getByLabel("Details")
		.fill("Capture the checklist before the first release.");
	await page.getByRole("button", { name: "Create issue", exact: true }).click();
	await expect(
		page.getByRole("heading", { name: "Document the release process" }),
	).toBeVisible();
	await page.getByLabel("Add a comment").fill("I will draft this in the wiki.");
	await page.getByRole("button", { name: "Comment", exact: true }).click();
	await expect(page.getByText("I will draft this in the wiki.")).toBeVisible();
	await page.getByRole("link", { name: "Wiki", exact: true }).click();
	await page.getByRole("button", { name: "New page", exact: true }).click();
	await page.getByLabel("Slug").fill("releases");
	await page.getByLabel("Title").fill("Release process");
	await page.getByLabel("Content").fill("Review, tag, publish, and verify.");
	await page.getByRole("button", { name: "Save page", exact: true }).click();
	await expect(
		page.getByRole("heading", { name: "Release process" }),
	).toBeVisible();
	await page.getByRole("link", { name: "Wiki", exact: true }).click();
	await page.getByRole("link", { name: /Release process/ }).click();
	await expect(
		page.getByText("Review, tag, publish, and verify."),
	).toBeVisible();
	await page.screenshot({
		path: "../artifacts/collaboration.png",
		fullPage: true,
	});
	await page.getByRole("link", { name: "Files", exact: true }).click();
	await page.getByLabel("Search repository code").fill("kept simple");
	await page.getByLabel("Search repository code").press("Enter");
	await expect(page.getByText("1 result for “kept simple”")).toBeVisible();
	await page.screenshot({ path: "../artifacts/search.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({
		path: "../artifacts/search-mobile.png",
		fullPage: true,
	});
	expect(
		await page.evaluate(
			() => document.documentElement.scrollWidth <= window.innerWidth,
		),
	).toBe(true);
	await page.setViewportSize({ width: 1280, height: 720 });
	await page.getByRole("link", { name: /readme\.md/ }).click();
	await expect(
		page.getByText("Source control, kept simple.", { exact: true }).first(),
	).toBeVisible();
	await page.getByRole("button", { name: "Edit file", exact: true }).click();
	await page.getByLabel("Change message").fill("Improve the readme");
	await page
		.getByLabel("File contents 1")
		.fill("# Flurry\n\nA quiet place for your code.\n");
	await page.getByRole("button", { name: "Submit for review" }).click();
	await page
		.getByRole("button", { name: "Approve change", exact: true })
		.click();
	await page.getByRole("button", { name: "Land change", exact: true }).click();
	await expect(page.getByText("Landed on main as")).toBeVisible();
	await page.getByRole("link", { name: "History", exact: true }).click();
	await expect(
		page.getByRole("link", { name: "Improve the readme", exact: true }),
	).toBeVisible();
	await page
		.getByRole("link", { name: "Add the first readme", exact: true })
		.click();
	await page.getByRole("link", { name: "readme.md File", exact: true }).click();
	await expect(page.locator(".codeviewer")).toContainText(
		"Source control, kept simple.",
	);
	await page.goto(`/users/${username}`);
	await expect(page.getByText("Building small, useful tools.")).toBeVisible();
	await page.screenshot({ path: "../artifacts/profile.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({ path: "../artifacts/mobile.png", fullPage: true });
	expect(
		await page.evaluate(
			() => document.documentElement.scrollWidth <= window.innerWidth,
		),
	).toBe(true);
	await page.getByRole("button", { name: "Sign out", exact: true }).click();
	await expect(
		page.getByRole("heading", { name: "Sign in to Flurry" }),
	).toBeVisible();
	const publicProfile = await anonymous.get(`/api/profiles/${username}`);
	expect((await publicProfile.json()).repositories).toEqual([]);
	await anonymous.dispose();
	expect(errors).toEqual([]);
});

test("new repository flow initializes a ready-to-use project", async ({
	page,
}) => {
	const username = `n${Date.now()}`;
	await page.request.post("/api/signup", {
		data: {
			name: "Repository starter",
			username,
			email: `${username}@example.test`,
			password: "a long test password",
		},
	});
	const organization = await (
		await page.request.post("/api/organizations", {
			data: { name: "Starter workshop", slug: `starter-${Date.now()}` },
		})
	).json();
	await page.goto("/new");
	await expect(
		page.getByText(`${username}/repository`, { exact: true }),
	).toBeVisible();
	await page.getByLabel("Repository name").fill("starter");
	await page.getByLabel("Owner").selectOption(organization.id);
	await expect(
		page.getByText(`${organization.slug}/starter`, { exact: true }),
	).toBeVisible();
	await page.getByLabel("Description").fill("A prepared project.");
	await page.getByRole("radio", { name: /Public/ }).check();
	await page.getByLabel("Add a README").check();
	await page.getByLabel("Add .gitignore").selectOption("node");
	await page.getByLabel("Choose a license").selectOption("mit");
	await page.screenshot({
		path: "../artifacts/new-repository.png",
		fullPage: true,
	});
	await page.getByRole("button", { name: "Create repository" }).click();
	await expect(
		page.getByRole("link", { name: organization.slug }),
	).toBeVisible();
	await expect(page.getByRole("button", { name: "New change" })).toBeVisible();
	await expect(page.getByRole("link", { name: "README.md" })).toBeVisible();
	await expect(page.getByRole("link", { name: ".gitignore" })).toBeVisible();
	await expect(page.getByRole("link", { name: "LICENSE" })).toBeVisible();
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto("/new");
	await expect(
		page.getByRole("heading", { name: "New repository" }),
	).toBeVisible();
	expect(
		await page.evaluate(
			() => document.documentElement.scrollWidth <= window.innerWidth,
		),
	).toBe(true);
	await page.screenshot({
		path: "../artifacts/new-repository-mobile.png",
		fullPage: true,
	});
});

test("structured automated review verifies findings and keeps disposition human", async ({
	page,
	playwright,
}) => {
	const suffix = Date.now();
	const owner = `review${suffix}`;
	const verifierName = `verify${suffix}`;
	const password = "a long test password";
	await page.request.post("/api/signup", {
		data: { name: "Review owner", username: owner, email: `${owner}@example.test`, password },
	});
	const repositoryResponse = await page.request.post("/api/repositories", { data: { name: "review.intelligence" } });
	const repositoryBody = await repositoryResponse.text();
	expect(repositoryResponse.ok(), repositoryBody).toBeTruthy();
	const repository = JSON.parse(repositoryBody);
	const submitted = await (await page.request.post(`/api/repositories/${repository.id}/changesets`, {
		data: { base: null, message: "Harden account lookup", files: [{ path: "lib/account.ex", content: "def find(id)\n  Store.get(id)\nend\n" }] },
	})).json();

	const verifier = await playwright.request.newContext({ baseURL: "http://127.0.0.1:4041" });
	await verifier.post("/api/signup", {
		data: { name: "Independent verifier", username: verifierName, email: `${verifierName}@example.test`, password },
	});
	await page.request.post(`/api/repositories/${repository.id}/members`, { data: { username: verifierName, role: "maintain" } });

	const run = await (await page.request.post(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/runs`, {
		data: { profiles: ["correctness", "security"], status_context: "review/verified-findings" },
	})).json();
	const finding = await (await page.request.post(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/runs/${run.id}/findings`, {
		data: {
			fingerprint: "account-lookup-ownership",
			category: "security",
			severity: "high",
			classification: "introduced",
			title: "Account lookup does not enforce ownership",
			body: "The new lookup accepts any identifier without binding it to the authenticated account.",
			evidence: "The changed call path reaches Store.get directly and performs no owner comparison.",
			path: "lib/account.ex",
			side: "after",
			line: 2,
		},
	})).json();
	await verifier.post(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/findings/${finding.id}/verified`, {
		data: { note: "Confirmed through the changed lookup path." },
	});
	await page.request.patch(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/runs/${run.id}`, {
		data: { state: "completed", summary: "Two specialists completed; one finding verified.", reconcile: true },
	});

	await page.goto(`/repositories/${repository.id}/reviews/${submitted.review_id}`);
	await expect(page.getByRole("heading", { name: "Automated review" })).toBeVisible();
	await expect(page.getByRole("heading", { name: "Account lookup does not enforce ownership" })).toBeVisible();
	await expect(page.getByText("verified", { exact: true })).toBeVisible();
	await expect(page.getByText("Line 2: Account lookup does not enforce ownership")).toBeVisible();
	await page.screenshot({ path: "../artifacts/structured-review.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({ path: "../artifacts/structured-review-mobile.png", fullPage: true });
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
	await page.setViewportSize({ width: 1280, height: 900 });
	await page.getByRole("button", { name: "Resolve", exact: true }).click();
	await expect(page.getByText("No open findings on this review.")).toBeVisible();
	await page.getByRole("button", { name: "History", exact: true }).click();
	await expect(page.getByRole("heading", { name: "Account lookup does not enforce ownership" })).toBeVisible();
	const activity = await (await page.request.get(`/api/repositories/${repository.id}/activity`)).json();
	expect(activity.events.some((event: { type: string }) => event.type === "review.finding.resolved")).toBe(true);

	await page.goto(`/repositories/${repository.id}/settings`);
	await page.getByRole("button", { name: "Automated review", exact: true }).click();
	await page.getByLabel("Request reviews").selectOption("every_revision");
	await page.getByText("Regression", { exact: true }).click();
	await page.getByLabel("Optional status context").fill("review/findings");
	const saved = page.waitForResponse((response) => response.url().endsWith(`/api/repositories/${repository.id}`) && response.request().method() === "PATCH");
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	expect((await saved).ok()).toBeTruthy();
	const configured = await (await page.request.get(`/api/repositories/${repository.id}`)).json();
	expect(configured.review_trigger).toBe("every_revision");
	expect(configured.review_profiles).toContain("regression");
	expect(configured.review_status_context).toBe("review/findings");
	await verifier.dispose();
});

test("automation provenance, evaluations, symbols, and activity stay inspectable", async ({
	page,
}) => {
	const username = `a${Date.now()}`;
	await page.request.post("/api/signup", {
		data: {
			name: "Automation reviewer",
			username,
			email: `${username}@example.test`,
			password: "a long test password",
		},
	});
	const repositoryResponse = await page.request.post("/api/repositories", {
		data: { name: `evaluated.${Date.now()}` },
	});
	const repositoryBody = await repositoryResponse.text();
	expect(repositoryResponse.ok(), repositoryBody).toBeTruthy();
	const repository = JSON.parse(repositoryBody);
	const submittedResponse = await page.request.post(
		`/api/repositories/${repository.id}/changesets`,
		{
			headers: { "Idempotency-Key": "browser-automation-1" },
			data: {
				base: null,
				message: "Add generated worker",
				files: [
					{
						path: "worker.ts",
						content: "export function run() {\n\treturn true;\n}\n",
					},
				],
				automation: {
					name: "Build worker",
					version: "1.0",
					trigger: "api",
					external_id: "run-42",
					metadata: { attempt: 1 },
				},
			},
		},
	);
	const submittedBody = await submittedResponse.text();
	expect(submittedResponse.ok(), submittedBody).toBeTruthy();
	const submitted = JSON.parse(submittedBody);
	const evaluationPath = `/api/repositories/${repository.id}/changesets/${submitted.changeset.id}/evaluations`;
	await page.request.post(evaluationPath, {
		data: {
			context: "quality/tests",
			state: "failure",
			summary: "One regression",
			pass: 7,
			fail: 1,
		},
	});
	await page.request.post(evaluationPath, {
		data: {
			context: "quality/tests",
			state: "success",
			summary: "All checks passed",
			pass: 8,
			fail: 0,
			score: 1,
			target_url: "https://checks.example.test/runs/42",
		},
	});

	await page.goto(
		`/repositories/${repository.id}/reviews/${submitted.review_id}`,
	);
	await expect(
		page.getByText("Build worker 1.0", { exact: true }),
	).toBeVisible();
	await expect(
		page.getByText("All checks passed", { exact: true }),
	).toBeVisible();
	await expect(page.getByText("One regression", { exact: true })).toBeVisible();
	await expect(page.locator(".symbolchip", { hasText: "run" })).toBeVisible();
	await expect(page.getByLabel("run, function, added")).toBeVisible();
	await expect(page.getByLabel("Open quality/tests result")).toHaveAttribute(
		"href",
		"https://checks.example.test/runs/42",
	);
	await page.screenshot({
		path: "../artifacts/automation-review.png",
		fullPage: true,
	});

	await page.getByRole("link", { name: "Activity", exact: true }).click();
	await expect(
		page.getByRole("heading", { name: "Repository activity" }),
	).toBeVisible();
	await expect(
		page.getByText("Add generated worker", { exact: true }).first(),
	).toBeVisible();
	await expect(
		page.getByText("quality/tests", { exact: true }).first(),
	).toBeVisible();
	await page.screenshot({ path: "../artifacts/activity.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({
		path: "../artifacts/activity-mobile.png",
		fullPage: true,
	});
	expect(
		await page
			.locator(".tabs")
			.evaluate((element) => getComputedStyle(element).flexWrap),
	).toBe("nowrap");
	const activeTab = await page.locator(".tabs > a.active").boundingBox();
	const tabBar = await page.locator(".tabs").boundingBox();
	const tabMetrics = await page.locator(".tabs").evaluate((element) => ({
		clientWidth: element.clientWidth,
		scrollWidth: element.scrollWidth,
		scrollLeft: element.scrollLeft,
		overflow: getComputedStyle(element).overflowX,
	}));
	expect(activeTab).not.toBeNull();
	expect(tabBar).not.toBeNull();
	expect(activeTab!.x).toBeGreaterThanOrEqual(tabBar!.x);
	expect(
		activeTab!.x + activeTab!.width,
		JSON.stringify(tabMetrics),
	).toBeLessThanOrEqual(tabBar!.x + tabBar!.width);
	expect(
		await page.evaluate(
			() => document.documentElement.scrollWidth <= window.innerWidth,
		),
	).toBe(true);
	await page.goto(
		`/repositories/${repository.id}/reviews/${submitted.review_id}`,
	);
	await expect(page.getByText("Score 1", { exact: true })).toBeVisible();
	await expect(
		page.getByText("8 passed · 0 failed", { exact: true }),
	).toBeVisible();
	await page.screenshot({
		path: "../artifacts/automation-review-mobile.png",
		fullPage: true,
	});
});
