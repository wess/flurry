import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";

test("email verification, notifications and password recovery are reachable", async ({
	page,
}) => {
	const username = `identity${Date.now()}`;
	await page.goto("/signup");
	await page.getByLabel("Display name").fill("Identity Tester");
	await page.getByLabel("Username").fill(username);
	await page.getByLabel("Email").fill(`${username}@example.test`);
	await page.getByLabel("Password").fill("a long fixture password");
	await page
		.getByRole("button", { name: "Create account", exact: true })
		.click();

	await expect(
		page.getByText("Verify your email to keep account recovery available."),
	).toBeVisible();
	const verification = page.waitForResponse((response) =>
		response.url().endsWith("/api/email/verification"),
	);
	await page.getByRole("button", { name: "Send verification" }).click();
	expect((await verification).status()).toBe(200);

	await page.getByRole("link", { name: "Notifications" }).click();
	await expect(
		page.getByRole("heading", { name: "Notifications" }),
	).toBeVisible();
	await expect(
		page.getByRole("heading", { name: "You’re all caught up" }),
	).toBeVisible();
	await mkdir("../artifacts", { recursive: true });
	await page.screenshot({
		path: "../artifacts/notifications.png",
		fullPage: true,
	});

	await page.setViewportSize({ width: 390, height: 844 });
	await page.screenshot({
		path: "../artifacts/notifications-mobile.png",
		fullPage: true,
	});
	expect(
		await page.evaluate(
			() => document.documentElement.scrollWidth <= window.innerWidth,
		),
	).toBe(true);

	const signedOut = page.waitForResponse(
		(response) =>
			response.url().endsWith("/api/session") &&
			response.request().method() === "DELETE",
	);
	await page.getByRole("button", { name: "Sign out" }).click();
	expect((await signedOut).status()).toBe(200);
	await expect(
		page.getByRole("heading", { name: "Sign in to Flurry" }),
	).toBeVisible();
	await page.getByRole("link", { name: "Forgot your password?" }).click();
	await expect(
		page.getByRole("heading", { name: "Reset your password" }),
	).toBeVisible();
	await page.getByLabel("Email").fill(`${username}@example.test`);
	await page.getByRole("button", { name: "Send recovery link" }).click();
	await expect(
		page.getByText("Check your email for the recovery link."),
	).toBeVisible();
});
