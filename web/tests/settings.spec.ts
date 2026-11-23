import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const sql = async (query: string) =>
	(
		await promisify(execFile)("psql", [
			"postgresql://localhost/flurrye2e",
			"-At",
			"-c",
			query,
		])
	).stdout.trim();

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
	await page.getByLabel("Your password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.locator(".brandname")).toHaveText("Flurry test instance");
	await page.screenshot({
		path: "../artifacts/administration.png",
		fullPage: true,
	});
	await page.getByLabel("Instance name", { exact: true }).fill("Flurry");
	await page.getByLabel("Your password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Save changes", exact: true }).click();
	await expect(page.locator(".brandname")).toHaveText("Flurry");
});

test("an administrator finds an account, reads its details, and promotes it with only their own password", async ({
	page,
	playwright,
}) => {
	const stamp = Date.now();
	const username = `a${stamp}`;
	const target = `m${stamp}`;
	const password = "a long test password";
	const other = await playwright.request.newContext({
		baseURL: "http://127.0.0.1:4041",
	});
	await other.post("/api/signup", {
		data: {
			name: "Managed account",
			username: target,
			email: `${target}@example.test`,
			password: "known only to the managed account",
		},
	});
	await other.dispose();
	await page.request.post("/api/signup", {
		data: {
			name: "Promoting administrator",
			username,
			email: `${username}@example.test`,
			password,
		},
	});
	await sql(`UPDATE users SET admin = true WHERE username = '${username}'`);
	await page.goto("/admin");
	await page.getByRole("button", { name: "Users", exact: true }).click();
	await expect(page).toHaveURL(/\/admin\/users$/);

	// the newest account is far past the first page; search finds it by email
	await page.getByLabel("Find an account").fill(`${target}@example`);
	await expect(page.locator(".usercount")).toHaveText("1–1 of 1 account");
	await expect(page).toHaveURL(new RegExp(`/admin/users\\?q=${target}%40example$`));
	const account = page.locator(".userentry").filter({ hasText: `@${target}` });
	const details = page.getByRole("dialog", { name: "Managed account" });

	await account
		.getByRole("link", { name: `View details for @${target}` })
		.click();
	await expect(page).toHaveURL(/\/admin\/users\/[0-9a-f-]{36}\?q=/);
	await expect(details.getByText(`${target}@example.test`)).toBeVisible();
	await expect(details.getByText("not verified")).toBeVisible();
	await expect(details.getByText("Member", { exact: true })).toBeVisible();
	await expect(details).not.toContainText(/password|recovery|secret/i);
	await details.screenshot({ path: "../artifacts/accountdetails.png" });

	// the open account is part of the address: reload keeps it, back closes it
	await page.reload();
	await expect(details).toBeVisible();
	await page.keyboard.press("Escape");
	await expect(page.getByRole("dialog")).toHaveCount(0);
	await expect(page.getByLabel("Find an account")).toHaveValue(
		`${target}@example`,
	);
	await account
		.getByRole("link", { name: `View details for @${target}` })
		.click();
	await expect(details).toBeVisible();
	await page.goBack();
	await expect(page.getByRole("dialog")).toHaveCount(0);

	await account.locator("summary").click();
	await expect(account.getByText(`Signed in as @${username}.`)).toBeVisible();
	await expect(
		account.getByLabel("Current password", { exact: true }),
	).toHaveCount(0);
	// ownership is only offered to owners
	await expect(account.getByLabel("Owner", { exact: true })).toHaveCount(0);
	await account.getByLabel("Administrator", { exact: true }).check();
	await account.getByLabel("Your password", { exact: true }).fill(password);
	await account.screenshot({ path: "../artifacts/administrationusers.png" });
	await account
		.getByRole("button", { name: "Update account access", exact: true })
		.click();
	await expect(account.locator("summary")).toContainText("administrator");
});

test("an owner adds and removes another owner with only their own password", async ({
	page,
	playwright,
}) => {
	const stamp = Date.now();
	const username = `o${stamp}`;
	const target = `c${stamp}`;
	const password = "a long test password";
	const other = await playwright.request.newContext({
		baseURL: "http://127.0.0.1:4041",
	});
	await other.post("/api/signup", {
		data: {
			name: "Second owner",
			username: target,
			email: `${target}@example.test`,
			password: "known only to the second owner",
		},
	});
	await other.dispose();
	await page.request.post("/api/signup", {
		data: {
			name: "Founding owner",
			username,
			email: `${username}@example.test`,
			password,
		},
	});
	const previous = await sql("SELECT owner_id FROM instance WHERE id = 1");
	const flags = () =>
		sql(`SELECT owner, admin, disabled FROM users WHERE username = '${target}'`);
	try {
		await sql(
			`UPDATE instance SET owner_id = (SELECT id FROM users WHERE username = '${username}') WHERE id = 1`,
		);
		await page.goto(`/admin/users?q=${target}`);
		const account = page.locator(".userentry").filter({ hasText: `@${target}` });
		const save = account.getByRole("button", {
			name: "Update account access",
			exact: true,
		});
		await account.locator("summary").click();
		await account.getByLabel("Owner", { exact: true }).check();
		await account.getByLabel("Your password", { exact: true }).fill(password);
		await save.click();
		await expect(account.locator("summary")).toContainText("instance owner");
		expect(await flags()).toBe("t|t|f");

		// an owner is always an administrator and cannot be disabled while one
		await expect(
			account.getByLabel("Administrator", { exact: true }),
		).toBeChecked();
		await expect(
			account.getByLabel("Administrator", { exact: true }),
		).toBeDisabled();
		await expect(account.getByLabel(/^Disable sign-in/)).toBeDisabled();
		await account.screenshot({ path: "../artifacts/administrationowner.png" });

		await account.getByLabel("Owner", { exact: true }).uncheck();
		await account.getByLabel("Your password", { exact: true }).fill(password);
		await save.click();
		await expect(account.locator("summary")).not.toContainText("instance owner");
		await expect(account.locator("summary")).toContainText("administrator");
		expect(await flags()).toBe("f|t|f");

		// nobody changes their own ownership, and the founder's is fixed
		await page.goto(`/admin/users?q=${username}`);
		const own = page.locator(".userentry").filter({ hasText: `@${username}` });
		await expect(own.locator("summary")).toContainText("founding owner");
		await own.locator("summary").click();
		await expect(own.getByLabel("Owner", { exact: true })).toBeChecked();
		await expect(own.getByLabel("Owner", { exact: true })).toBeDisabled();
	} finally {
		await sql(
			`UPDATE instance SET owner_id = ${previous ? `'${previous}'` : "NULL"} WHERE id = 1`,
		);
	}
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
