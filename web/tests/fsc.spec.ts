import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, writeFile, readFile, mkdir, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
const execute = promisify(execFile);
const binary = resolve("../cli/target/debug/fsc");
const helperdir = resolve("../cli/target/debug");
const sql = async (query: string) =>
	(await execute("psql", ["postgresql://localhost/flurrye2e", "-At", "-c", query])).stdout.trim();

test("Rust working copies stage snapshots offline, retain local commits, merge two parents, publish tags and pull", async ({
	request,
}) => {
	test.setTimeout(60000);
	const username = `rust${Date.now()}`;
	const signup = await request.post("/api/signup", {
		data: {
			name: "Rust tester",
			username,
			email: `${username}@example.test`,
			password: "a long fixture password",
		},
	});
	const { token } = await signup.json();
	const repository = await (
		await request.post("/api/repositories", { data: { name: "rustcli" } })
	).json();
	const root = await mkdtemp(join(tmpdir(), "fsctest"));
	const env = {
		...process.env,
		FLURRY_URL: "http://127.0.0.1:4041",
		FLURRY_TOKEN: token,
	};
	const cli = async (...args: string[]) =>
		JSON.parse((await execute(binary, ["--json", ...args], { cwd: root, env })).stdout);
	try {
		await cli("clone", repository.id, root);
		await writeFile(join(root, "a"), "staged\n");
		await writeFile(join(root, "b"), "base\n");
		await cli("add", ".");
		await writeFile(join(root, "a"), "edited after staging\n");
		const committed = await cli("commit", "-m", "Initial local snapshot");
		expect(committed.commit).toHaveLength(36);
		const status = await cli("status");
		expect(status.unstaged.a).toHaveLength(64);
		await cli("restore", "a");
		expect(await readFile(join(root, "a"), "utf8")).toBe("staged\n");
		await writeFile(join(root, "untracked"), "preserve\n");
		await expect(cli("restore", "untracked")).rejects.toThrow(/untracked files are preserved/);
		expect(await readFile(join(root, "untracked"), "utf8")).toBe("preserve\n");
		await rm(join(root, "untracked"));
		const published = await cli("push");
		expect(published.protected).toBe(true);
		expect(published.review_id).toBeTruthy();
		await cli("review", "approve", published.review_id);
		await cli("review", "land", published.review_id);
		await cli("pull");
		await cli("switch", "-c", "feature");
		await writeFile(join(root, "b"), "feature\n");
		await cli("add", "b");
		await cli("commit", "-m", "Feature edit");
		const feature = await cli("push");
		expect(feature.protected).toBe(false);
		await cli("switch", "main");
		expect(await readFile(join(root, "b"), "utf8")).toBe("base\n");
		await writeFile(join(root, "c"), "main work\n");
		await cli("add", "c");
		await cli("commit", "-m", "Main work");
		const merged = await cli("merge", "feature");
		expect(merged.head).toHaveLength(36);
		expect(await readFile(join(root, "b"), "utf8")).toBe("feature\n");
		await cli("tag", "-a", "v1.0", "-m", "Native release");
		const pushed = await cli("push", "--tags");
		const change = await (
			await request.get(`/api/repositories/${repository.id}/changesets/${pushed.head}`)
		).json();
		expect(change.changeset.merge_parent).toBe(feature.head);
		await cli("review", "approve", pushed.review_id);
		await cli("review", "land", pushed.review_id);
		await cli("pull");
		const fileLimit = await sql("SELECT file_bytes FROM instance WHERE id = 1");
		try {
			await sql("UPDATE instance SET file_bytes = 10485760 WHERE id = 1");
			await writeFile(join(root, "too.big"), "x".repeat(10485761));
			await cli("add", "too.big");
			await cli("commit", "-m", "Over the instance file-size limit");
			await expect(cli("push")).rejects.toThrow(/file-size limit/);
			expect((await cli("push", "--abort")).canceled).toBe(true);
		} finally {
			await sql(`UPDATE instance SET file_bytes = ${fileLimit} WHERE id = 1`);
		}
		await writeFile(join(root, "too.big"), "fixed\n");
		await cli("add", "too.big");
		await cli("commit", "--amend", "-m", "Fix the unpublished commit");
		const fixed = await cli("push");
		await cli("review", "approve", fixed.review_id);
		await cli("review", "land", fixed.review_id);
		await cli("pull");
		const initialized = join(root, "initialized");
		await mkdir(initialized);
		await writeFile(join(initialized, "keep"), "existing local work\n");
		await expect(
			execute(binary, ["--json", "init", "retryinit"], {
				cwd: initialized,
				env: { ...env, FLURRY_TOKEN: "invalidfixture" },
			}),
		).rejects.toThrow(/401/);
		await execute(binary, ["--json", "init", "retryinit"], {
			cwd: initialized,
			env,
		});
		expect(await readFile(join(initialized, "keep"), "utf8")).toBe("existing local work\n");
		const second = join(root, "second");
		await mkdir(second);
		await cli("clone", repository.id, second);
		expect(await readFile(join(second, "a"), "utf8")).toBe("staged\n");
		expect(await readFile(join(second, "b"), "utf8")).toBe("feature\n");
		const refs = await (await request.get(`/api/repositories/${repository.id}/refs`)).json();
		expect(refs.tags[0].target).toBe(pushed.head);
		const offline = await execute(binary, ["--json", "status"], {
			cwd: root,
			env: { ...env, FLURRY_URL: "http://127.0.0.1:1" },
		}).catch((error) => error);
		expect(offline.stderr).toContain("Server does not match");
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("standard Git clones and pushes via the helper with stable IDs, executable modes, tags, merges and protected-main reviews", async ({
	request,
}) => {
	test.setTimeout(90000);
	const username = `git${Date.now()}`;
	const signup = await request.post("/api/signup", {
		data: {
			name: "Git tester",
			username,
			email: `${username}@example.test`,
			password: "a long fixture password",
		},
	});
	const { token } = await signup.json();
	const repository = await (
		await request.post("/api/repositories", { data: { name: "gitcli" } })
	).json();
	const root = await mkdtemp(join(tmpdir(), "fscgit"));
	const env = {
		...process.env,
		PATH: `${helperdir}:${process.env.PATH}`,
		FLURRY_URL: "http://127.0.0.1:4041",
		FLURRY_TOKEN: token,
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_GLOBAL: "/dev/null",
	};
	const git = async (cwd: string, ...args: string[]) =>
		(
			await execute(
				"git",
				["-c", "user.name=Git tester", "-c", "user.email=tester@example.test", ...args],
				{ cwd, env, maxBuffer: 4 * 1024 * 1024 },
			)
		).stdout.trim();
	const url = `flurry::http://127.0.0.1:4041/${repository.id}`;
	try {
		await git(root, "clone", url, "one");
		const one = join(root, "one");
		await git(one, "switch", "-c", "feature");
		await writeFile(join(one, "run.sh"), "#!/bin/sh\necho hello\n");
		await chmod(join(one, "run.sh"), 0o755);
		await git(one, "add", ".");
		await git(one, "commit", "-m", "Original Git commit");
		const original = await git(one, "rev-parse", "HEAD");
		await git(one, "push", "origin", "feature");
		await git(root, "clone", "--branch", "feature", url, "two");
		const two = join(root, "two");
		expect(await git(two, "rev-parse", "HEAD")).toBe(original);
		expect(await git(two, "ls-files", "--stage")).toMatch(/^100755/);
		await git(one, "tag", "v1.0");
		await git(one, "push", "origin", "v1.0");
		await git(one, "tag", "-a", "v2.0", "-m", "Annotated release");
		const annotation = await git(one, "rev-parse", "v2.0");
		await git(one, "push", "origin", "v2.0");
		await git(one, "switch", "-c", "other");
		await writeFile(join(one, "other"), "other\n");
		await git(one, "add", ".");
		await git(one, "commit", "-m", "Other work");
		await git(one, "switch", "feature");
		await writeFile(join(one, "feature"), "feature\n");
		await git(one, "add", ".");
		await git(one, "commit", "-m", "Feature work");
		await git(one, "merge", "--no-ff", "other", "-m", "Merge other");
		const merged = await git(one, "rev-parse", "HEAD");
		await git(one, "push", "origin", "feature");
		await git(two, "fetch", "origin");
		expect(await git(two, "rev-parse", "origin/feature")).toBe(merged);
		expect((await git(two, "show", "-s", "--format=%P", merged)).split(" ")).toHaveLength(2);
		await expect(git(one, "push", "origin", "feature:main")).rejects.toThrow(/main is protected/);
		const reviews = await (await request.get(`/api/repositories/${repository.id}/reviews`)).json();
		expect(reviews.reviews).toHaveLength(1);
		await expect(git(one, "push", "origin", "feature:main")).rejects.toThrow(/main is protected/);
		const repeated = await (await request.get(`/api/repositories/${repository.id}/reviews`)).json();
		expect(repeated.reviews).toHaveLength(1);
		const review = reviews.reviews[0].id;
		expect(
			(
				await request.post(`/api/repositories/${repository.id}/reviews/${review}/approve`, {
					data: {},
				})
			).ok(),
		).toBe(true);
		expect(
			(
				await request.post(`/api/repositories/${repository.id}/reviews/${review}/land`, {
					data: {},
				})
			).ok(),
		).toBe(true);
		await git(two, "fetch", "origin");
		expect(await git(two, "rev-parse", "origin/main")).toBe(merged);
		await git(root, "clone", url, "three");
		expect(await git(join(root, "three"), "rev-parse", "HEAD")).toBe(merged);
		expect(await git(join(root, "three"), "rev-parse", "v1.0")).toBe(original);
		expect(await git(join(root, "three"), "rev-parse", "v2.0")).toBe(annotation);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("standard Git clones public Flurry repositories over smart HTTP", async ({ request }) => {
	test.setTimeout(60000);
	const username = `smart${Date.now()}`;
	const signup = await request.post("/api/signup", {
		data: {
			name: "Smart transport tester",
			username,
			email: `${username}@example.test`,
			password: "a long fixture password",
		},
	});
	const { token } = await signup.json();
	const repository = await (
		await request.post("/api/repositories", {
			data: { name: "smarthttp", visibility: "public" },
		})
	).json();
	const submitted = await (
		await request.post(`/api/repositories/${repository.id}/changesets`, {
			data: {
				base: null,
				message: "Initial source",
				files: [{ path: "readme.md", content: "Flurry smart transport\n" }],
			},
		})
	).json();
	await request.post(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/approve`, {
		data: {},
	});
	await request.post(`/api/repositories/${repository.id}/reviews/${submitted.review_id}/land`, {
		data: {},
	});

	const root = await mkdtemp(join(tmpdir(), "flurrysmart"));
	const env = {
		...process.env,
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_GLOBAL: "/dev/null",
	};

	try {
		await execute(
			"git",
			["clone", `http://127.0.0.1:4041/repositories/${repository.id}.git`, "checkout"],
			{ cwd: root, env, maxBuffer: 16 * 1024 * 1024 },
		);
		expect(await readFile(join(root, "checkout", "readme.md"), "utf8")).toBe(
			"Flurry smart transport\n",
		);
		const checkout = join(root, "checkout");
		await writeFile(join(checkout, "feature.txt"), "topic work\n");
		await execute("git", ["add", "."], { cwd: checkout, env });
		await execute(
			"git",
			[
				"-c",
				"user.name=Smart transport tester",
				"-c",
				"user.email=smart@example.test",
				"commit",
				"-m",
				"Topic work",
			],
			{ cwd: checkout, env },
		);
		const auth = Buffer.from(`${username}:${token}`).toString("base64");
		await execute(
			"git",
			[
				"-c",
				`http.extraHeader=Authorization: Basic ${auth}`,
				"push",
				"origin",
				"HEAD:refs/heads/feature",
			],
			{ cwd: checkout, env, maxBuffer: 16 * 1024 * 1024 },
		);

		await execute(
			"git",
			[
				"clone",
				"--branch",
				"feature",
				`http://127.0.0.1:4041/repositories/${repository.id}.git`,
				"topic",
			],
			{ cwd: root, env, maxBuffer: 16 * 1024 * 1024 },
		);
		expect(await readFile(join(root, "topic", "feature.txt"), "utf8")).toBe("topic work\n");
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});
