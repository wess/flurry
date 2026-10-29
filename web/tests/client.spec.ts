import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, writeFile, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

const execute = promisify(execFile);

test("the client checks out only selected paths and submits real file changes", async ({
	request,
}) => {
	const name = `c${Date.now()}`;
	const signup = await request.post("/api/signup", {
		data: {
			name: "Client test",
			username: name,
			email: `${name}@example.test`,
			password: "a long test password",
		},
	});
	expect(signup.ok()).toBe(true);
	const { token } = await signup.json();
	const created = await request.post("/api/repositories", {
		data: { name: "client" },
	});
	const repo = await created.json();
	const submitted = await request.post(
		`/api/repositories/${repo.id}/changesets`,
		{
			data: {
				base: null,
				message: "Initial files",
				files: [
					{ path: "lib/main.ex", content: "original\n" },
					{ path: "readme.md", content: "outside sparse checkout\n" },
				],
			},
		},
	);
	const { review_id: initial } = await submitted.json();
	await request.post(
		`/api/repositories/${repo.id}/reviews/${initial}/approve`,
		{ data: {} },
	);
	await request.post(`/api/repositories/${repo.id}/reviews/${initial}/land`, {
		data: {},
	});
	const destination = await mkdtemp(join(tmpdir(), "flurry"));
	const script = resolve("../scripts/flurry.ts");
	const env = {
		...process.env,
		FLURRY_URL: "http://127.0.0.1:4041",
		FLURRY_TOKEN: token,
	};
	const client = (...args: string[]) =>
		execute("bun", [script, ...args], { cwd: destination, env });
	await client("clone", repo.id, destination, "lib");
	expect(await readFile(join(destination, "lib/main.ex"), "utf8")).toBe(
		"original\n",
	);
	await expect(readFile(join(destination, "readme.md"))).rejects.toThrow();
	expect(JSON.parse((await client("status")).stdout).changes).toEqual([]);
	await writeFile(join(destination, "lib/main.ex"), "modified\n");
	await writeFile(join(destination, "lib/new.ex"), "new\n");
	expect(JSON.parse((await client("status")).stdout).changes).toHaveLength(2);
	const submission = JSON.parse(
		(await client("submit", "Update sparse files")).stdout,
	);
	await client("approve", repo.id, submission.review_id);
	await client("land", repo.id, submission.review_id);
	const fetched = await request.get(
		`/api/repositories/${repo.id}/file?path=lib/main.ex`,
	);
	expect((await fetched.json()).content).toBe("modified\n");
	const outside = await request.get(
		`/api/repositories/${repo.id}/file?path=readme.md`,
	);
	expect((await outside.json()).content).toBe("outside sparse checkout\n");
	await expect(client("clone", repo.id, destination)).rejects.toThrow(/empty/);
	await symlink("/tmp", join(destination, "lib/escape"));
	await expect(client("status")).rejects.toThrow(/Symlinks/);
});
