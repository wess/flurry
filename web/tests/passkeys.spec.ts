import { expect, test } from "@playwright/test";

test("passkeys register, provide passwordless sign-in, and can be revoked", async ({ page }) => {
	const client = await page.context().newCDPSession(page);
	await client.send("WebAuthn.enable");
	const { authenticatorId } = await client.send("WebAuthn.addVirtualAuthenticator", {
		options: {
			protocol: "ctap2",
			transport: "internal",
			hasResidentKey: true,
			hasUserVerification: true,
			isUserVerified: true,
			automaticPresenceSimulation: true,
		},
	});

	const username = "passkey" + Date.now();
	const password = "a long passkey test password";
	await page.goto("http://localhost:4041/signup");
	await page.getByLabel("Display name").fill("Passkey tester");
	await page.getByLabel("Username").fill(username);
	await page.getByLabel("Email").fill(username + "@example.test");
	await page.getByLabel("Password").fill(password);
	await page.getByRole("button", { name: "Create account", exact: true }).click();
	await expect(page).toHaveURL(new RegExp(`/${username}$`));
	await page.goto("http://localhost:4041/settings/security");
	await page.getByLabel("Passkey name").fill("Personal laptop");
	await page
		.locator(".passkeysettings")
		.getByLabel("Current password", { exact: true })
		.fill(password);
	await page.getByRole("button", { name: "Add passkey", exact: true }).click();
	await expect(page.getByText("Personal laptop", { exact: true })).toBeVisible();
	await expect(page.getByText("Passkey added", { exact: true })).toBeVisible();

	await page.getByRole("button", { name: "Sign out", exact: true }).click();
	await page.getByRole("button", { name: "Sign in with a passkey", exact: true }).click();
	await expect(page.getByRole("link", { name: username, exact: true })).toBeVisible();

	await page.goto("http://localhost:4041/settings/security");
	await page.getByText("Manage", { exact: true }).click();
	await page.getByLabel("Name", { exact: true }).fill("Hardware-backed key");
	await page.getByRole("button", { name: "Rename passkey", exact: true }).click();
	await expect(page.getByText("Hardware-backed key", { exact: true })).toBeVisible();

	await page.getByText("Manage", { exact: true }).click();
	await page.locator(".passkeymanage").getByLabel("Current password", { exact: true }).fill(password);
	await page.getByRole("button", { name: "Remove passkey", exact: true }).click();
	await expect(page.getByText("No passkeys are registered yet.", { exact: true })).toBeVisible();

	await client.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
});
