import { mkdir, readdir, lstat, chmod, writeFile } from "node:fs/promises";
import { resolve, join, dirname } from "node:path";

type State = {
	url: string;
	repository: string;
	base: string | null;
	prefix: string;
	files: Record<string, string>;
};
type Tree = {
	revision: string | null;
	entries: { name: string; type: "tree" | "blob"; hash: string }[];
};
const server = new URL(process.env.FLURRY_URL || "http://127.0.0.1:4040");
if (
	server.protocol !== "https:" &&
	!(
		server.protocol === "http:" &&
		["localhost", "127.0.0.1", "[::1]"].includes(server.hostname)
	)
)
	throw new Error("Use HTTPS for a remote Flurry server");
if (
	server.username ||
	server.password ||
	server.pathname !== "/" ||
	server.search ||
	server.hash
)
	throw new Error("FLURRY_URL must be a server origin");
const token = process.env.FLURRY_TOKEN;
const [command, ...args] = Bun.argv.slice(2);

async function api<T>(path: string, body?: unknown): Promise<T> {
	const response = await fetch(new URL(`/api${path}`, server), {
		method: body === undefined ? "GET" : "POST",
		redirect: "error",
		headers: {
			...(token ? { Authorization: `Bearer ${token}` } : {}),
			...(body === undefined ? {} : { "Content-Type": "application/json" }),
		},
		body: body === undefined ? undefined : JSON.stringify(body),
	});
	const data = await response.json();
	if (!response.ok)
		throw new Error(
			data.error +
				(data.details?.paths ? `: ${data.details.paths.join(", ")}` : ""),
		);
	return data as T;
}

function valid(path: string) {
	const parts = path.split("/");
	if (
		!path ||
		path.includes("\\") ||
		path.includes("\0") ||
		parts.some((p) => !p || p === "." || p === "..") ||
		[".flurry", ".git"].includes(parts[0]!.toLowerCase())
	)
		throw new Error(`Unsafe checkout path: ${path}`);
	return path;
}
const hash = (bytes: Uint8Array) =>
	new Bun.CryptoHasher("sha256").update("blob\0").update(bytes).digest("hex");

async function state(): Promise<State> {
	const file = join(process.cwd(), ".flurry/state.json");
	const value = (await Bun.file(file).json()) as State;
	if (value.url !== server.origin)
		throw new Error(`Set FLURRY_URL=${value.url} to use this checkout`);
	Object.keys(value.files).forEach(valid);
	if (value.prefix) valid(value.prefix);
	return value;
}

async function scan(path = ""): Promise<Record<string, Uint8Array>> {
	const files: Record<string, Uint8Array> = {};
	for (const entry of await readdir(path || ".", { withFileTypes: true })) {
		if (
			[
				".flurry",
				".git",
				"node_modules",
				"deps",
				"_build",
				".DS_Store",
			].includes(entry.name)
		)
			continue;
		const child = [path, entry.name].filter(Boolean).join("/");
		if (entry.isSymbolicLink())
			throw new Error(`Symlinks are not supported: ${child}`);
		if (entry.isDirectory()) Object.assign(files, await scan(child));
		else if (entry.isFile()) {
			if ((await lstat(child)).size > 104_857_600)
				throw new Error(`File exceeds 100 MiB: ${child}`);
			files[valid(child)] = new Uint8Array(await Bun.file(child).arrayBuffer());
		}
	}
	return files;
}

async function changes(current: State) {
	const files = await scan(current.prefix);
	const edits: { path: string; base64?: string; content?: null }[] = [];
	for (const [path, bytes] of Object.entries(files)) {
		if (hash(bytes) !== current.files[path])
			edits.push({ path, base64: Buffer.from(bytes).toString("base64") });
	}
	for (const path of Object.keys(current.files)) {
		if (!files[path]) edits.push({ path, content: null });
	}
	return edits;
}

async function clone() {
	const [repository, destination, prefix = ""] = args;
	if (!repository || !destination)
		throw new Error(
			"Usage: clone <repository id> <empty directory> [directory prefix]",
		);
	if (prefix) valid(prefix);
	const root = resolve(destination);
	await mkdir(root, { recursive: true });
	if ((await readdir(root)).length)
		throw new Error("Checkout destination must be empty");
	const meta = await api<{ head: string | null }>(
		`/repositories/${encodeURIComponent(repository)}`,
	);
	const files: Record<string, string> = {};
	const bytes: Record<string, Uint8Array> = {};
	const collision = new Set<string>();
	let cacheSize = 0;
	let checkoutSize = 0;
	const revision = meta.head;
	const directories = [prefix];
	if (revision)
		while (directories.length) {
			const directory = directories.pop()!;
			const tree = await api<Tree>(
				`/repositories/${repository}/tree?${new URLSearchParams({ path: directory, revision })}`,
			);
			for (const entry of tree.entries) {
				const path = valid([directory, entry.name].filter(Boolean).join("/"));
				if (collision.has(path.toLowerCase()))
					throw new Error(`Case-colliding checkout paths: ${path}`);
				collision.add(path.toLowerCase());
				if (entry.type === "tree") {
					directories.push(path);
					continue;
				}
				const file = await api<{
					content: string;
					encoding: string;
					hash: string;
				}>(
					`/repositories/${repository}/file?${new URLSearchParams({ path, revision })}`,
				);
				const data =
					file.encoding === "base64"
						? new Uint8Array(Buffer.from(file.content, "base64"))
						: new TextEncoder().encode(file.content);
				if (hash(data) !== entry.hash || file.hash !== entry.hash)
					throw new Error(`Content integrity failed: ${path}`);
				checkoutSize += data.byteLength;
				if (checkoutSize > 128 * 1024 * 1024)
					throw new Error("This client currently limits checkouts to 128 MiB");
				files[path] = entry.hash;
				bytes[path] = data;
				if (Object.keys(files).length > 10000)
					throw new Error(
						"This client currently limits checkouts to 10,000 files",
					);
			}
		}
	for (const [path, data] of Object.entries(bytes)) {
		const target = join(root, path);
		await mkdir(dirname(target), { recursive: true });
		await writeFile(target, data, { flag: "wx" });
		if (cacheSize + data.byteLength <= 64 * 1024 * 1024) {
			const cache = join(root, ".flurry/objects", files[path]!);
			await mkdir(dirname(cache), { recursive: true });
			await writeFile(cache, data);
			cacheSize += data.byteLength;
		}
	}
	if (prefix) await mkdir(join(root, prefix), { recursive: true });
	await mkdir(join(root, ".flurry"), { recursive: true });
	const checkout: State = {
		url: server.origin,
		repository,
		base: revision,
		prefix,
		files,
	};
	await writeFile(
		join(root, ".flurry/state.json"),
		JSON.stringify(checkout, null, 2) + "\n",
	);
	await chmod(join(root, ".flurry/state.json"), 0o600);
	console.log(
		JSON.stringify({
			directory: root,
			revision,
			files: Object.keys(files).length,
		}),
	);
}

try {
	if (command === "clone") await clone();
	else if (command === "status" || command === "submit") {
		const current = await state();
		const edits = await changes(current);
		if (command === "status")
			console.log(
				JSON.stringify(
					{
						base: current.base,
						changes: edits.map((file) => ({
							path: file.path,
							kind:
								file.content === null
									? "deleted"
									: current.files[file.path]
										? "modified"
										: "added",
						})),
					},
					null,
					2,
				),
			);
		else {
			const message = args.join(" ");
			if (!message || !edits.length)
				throw new Error(
					!message ? "Supply a change message" : "No changes to submit",
				);
			console.log(
				JSON.stringify(
					await api(`/repositories/${current.repository}/changesets`, {
						base: current.base,
						message,
						files: edits,
					}),
					null,
					2,
				),
			);
		}
	} else if (command === "approve" || command === "land") {
		const [repository, review] = args;
		if (!repository || !review)
			throw new Error(`Usage: ${command} <repository id> <review id>`);
		console.log(
			JSON.stringify(
				await api(
					`/repositories/${encodeURIComponent(repository)}/reviews/${encodeURIComponent(review)}/${command}`,
					{},
				),
				null,
				2,
			),
		);
	} else if (command === "repositories")
		console.log(JSON.stringify(await api("/repositories"), null, 2));
	else if (command === "login") {
		if (!process.env.FLURRY_EMAIL || !process.env.FLURRY_PASSWORD)
			throw new Error(
				"Set FLURRY_EMAIL and FLURRY_PASSWORD for login; the returned token is a credential",
			);
		console.log(
			JSON.stringify(
				await api("/login", {
					email: process.env.FLURRY_EMAIL,
					password: process.env.FLURRY_PASSWORD,
				}),
				null,
				2,
			),
		);
	} else
		console.log(
			"Flurry client\n\nFLURRY_URL sets the server; FLURRY_TOKEN authenticates requests.\nCommands: login, repositories, clone <repository> <directory> [prefix], status, submit <message>, approve <repository> <review>, land <repository> <review>\n\nCheckouts keep a fixed base. After landing, use a fresh checkout for the next change.",
		);
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	process.exitCode = 1;
}
