import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

test("account and repository settings persist, enforce privacy, and preserve removed history", async ({
	page,
	playwright,
}) => {
	const username = `p${Date.now()}`;
	const password = "a long test password";
	await page.request.post("/api/signup", {
		data: {
			name: "Settings tester",
			username,
			email: `${username}@example.test`,
			password,
		},
	});
	await page.goto("/settings/preferences");
	await page.getByLabel("Appearance").selectOption("dark");
	await page.getByLabel("Wrap long lines").check();
	await page.getByLabel("Make my profile visible only to me").check();
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
	const anonymous = await playwright.request.newContext({
		baseURL: "http://127.0.0.1:4041",
	});
	expect((await anonymous.get(`/api/profiles/${username}`)).status()).toBe(404);
	await page.screenshot({
		path: "../artifacts/preferences.png",
		fullPage: true,
	});
	await page.getByRole("link", { name: "Access tokens", exact: true }).click();
	await page.getByLabel("Token name").fill("Read-only laptop");
	await page.getByLabel("Current password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Create token", exact: true }).click();
	const secret = page.getByLabel("New access token");
	await expect(secret).toBeVisible();
	expect(await secret.inputValue()).toMatch(/^flr_/);
	await page
		.getByRole("button", { name: "I saved the token", exact: true })
		.click();
	await expect(secret).toHaveCount(0);
	await page.getByRole("button", { name: "Revoke", exact: true }).click();
	await expect(page.getByText("No API tokens.")).toBeVisible();
	await page.getByRole("link", { name: "Sessions", exact: true }).click();
	await expect(page.getByText("This session", { exact: true })).toBeVisible();
	await page.goto("/new");
	await page.getByLabel("Repository name").fill("settingsrepo");
	await page
		.getByRole("button", { name: "Create repository", exact: true })
		.click();
	await expect(page).toHaveURL(/\/repositories\//);
	const id = page.url().match(/repositories\/([^/?#]+)/)![1]!;
	await page
		.getByRole("link", { name: "Settings", exact: true })
		.filter({ hasText: "Settings" })
		.click();
	await page
		.getByLabel("Description", { exact: true })
		.fill("Updated from settings");
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(
		page.getByText("Updated from settings", { exact: true }).first(),
	).toBeVisible();
	await page
		.getByRole("button", { name: "Archive repository", exact: true })
		.click();
	await expect(
		page.getByRole("button", { name: "Reopen repository", exact: true }),
	).toBeVisible();
	await expect(
		page.getByRole("button", { name: "New change", exact: true }),
	).toHaveCount(0);
	await page
		.locator("summary")
		.filter({ hasText: "Remove repository" })
		.click();
	await page.getByLabel("Type repository name to confirm").fill("settingsrepo");
	await page
		.locator("details.danger")
		.getByLabel("Current password", { exact: true })
		.fill(password);
	await page
		.getByRole("button", { name: "Remove repository", exact: true })
		.click();
	await expect(
		page.getByRole("heading", { name: "Removed repositories" }),
	).toBeVisible();
	await page.getByRole("button", { name: "Restore", exact: true }).click();
	await expect(
		page.getByText("No removed repositories.", { exact: true }),
	).toBeVisible();
	const restored = await page.request.get(`/api/repositories/${id}`);
	expect((await restored.json()).archived).toBe(true);
	await page.goto("/settings/account");
	await page.getByLabel("New password").fill("a new long test password");
	await page.getByLabel("Current password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.getByRole("status")).toContainText("Saved");
	await page.getByRole("button", { name: "Sign out", exact: true }).click();
	await page
		.getByLabel("Username or email", { exact: true })
		.fill(`${username}@example.test`);
	await page
		.getByLabel("Password", { exact: true })
		.fill("a new long test password");
	await page.getByRole("button", { name: "Sign in", exact: true }).click();
	await expect(
		page.getByRole("heading", { name: "Settings tester", exact: true }),
	).toBeVisible();
	await anonymous.dispose();
});

test("administrator settings show service status and apply instance policy", async ({
	page,
}) => {
	const username = `a${Date.now()}`;
	const password = "a long test password";
	await page.request.post("/api/signup", {
		data: {
			name: "Administrator test",
			username,
			email: `${username}@example.test`,
			password,
		},
	});
	// promote only this synthetic account in the separate browser-test database
	await promisify(execFile)("psql", [
		"postgresql://localhost/flurrye2e",
		"-c",
		`UPDATE users SET admin = true WHERE username = '${username}'`,
	]);
	await page.goto("/settings/instance");
	await expect(
		page.getByRole("heading", { name: "Administration", exact: true }),
	).toBeVisible();
	await expect(page.getByText("Git executable", { exact: true })).toBeVisible();
	await page
		.getByLabel("Instance name", { exact: true })
		.fill("Flurry test instance");
	await page.getByLabel("Current password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.locator(".brandname")).toHaveText("Flurry test instance");
	await page.screenshot({
		path: "../artifacts/administration.png",
		fullPage: true,
	});
	await page.getByLabel("Instance name", { exact: true }).fill("Flurry");
	await page.getByLabel("Current password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.locator(".brandname")).toHaveText("Flurry");
});

test("agent accounts and role-based teams can be managed in the browser", async ({
	page,
}) => {
	const suffix = Date.now();
	const username = `team${suffix}`;
	const agentUsername = `worker.${suffix}`;
	const password = "a long test password";
	await page.request.post("/api/signup", {
		data: { name: "Team owner", username, email: `${username}@example.test`, password },
	});

	await page.goto("/settings/agents");
	await page.getByLabel("Display name").fill("Release worker");
	await page.getByLabel("Username").fill(agentUsername);
	await page.getByLabel("Current password", { exact: true }).last().fill(password);
	await page.getByRole("button", { name: "Create agent", exact: true }).click();
	await expect(page.getByLabel("New agent credential")).toHaveValue(/^fla_/);
	await page.getByRole("button", { name: "I saved it", exact: true }).click();
	await expect(page.getByText(`@${agentUsername}`)).toBeVisible();
	await page.screenshot({ path: "../artifacts/agent-accounts.png", fullPage: true });

	await page.goto("/organizations");
	await page.getByLabel("Name", { exact: true }).fill("Release group");
	await page.getByLabel("Slug", { exact: true }).fill(`release-${suffix}`);
	await page.getByRole("button", { name: "Create organization", exact: true }).click();
	await expect(page.getByRole("heading", { name: "Release group" })).toBeVisible();
	const organization = page.url().match(/organizations\/([^/?#]+)/)![1]!;
	await page.request.post(`/api/organizations/${organization}/members`, {
		data: { username: agentUsername, role: "member" },
	});
	await page.reload();
	await expect(page.getByText("Agent account · member")).toBeVisible();

	await page.locator("summary").filter({ hasText: "Create team" }).click();
	const createTeam = page.locator("details.inlineform").filter({ hasText: "Create team" });
	await createTeam.getByLabel("Name").fill("Release automation");
	await createTeam.getByLabel("Slug").fill("release-automation");
	await createTeam.getByRole("button", { name: "Create team", exact: true }).click();
	await page.getByRole("button", { name: /Release automation/ }).click();
	const addMember = page.locator("details.inlineform").filter({ hasText: "Add team member" });
	await addMember.locator("summary").click();
	await addMember.getByLabel("Organization member username").fill(agentUsername);
	await addMember.getByRole("button", { name: "Add team member", exact: true }).click();
	await expect(page.getByText("Agent · member")).toBeVisible();
	await page.screenshot({ path: "../artifacts/teams.png", fullPage: true });
	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({ path: "../artifacts/teams-mobile.png", fullPage: true });
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
