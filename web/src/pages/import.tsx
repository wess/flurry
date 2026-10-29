import { useState } from "react";
import { send, useAction, useResource } from "../api";
import { Alert } from "../components/common";
import { go } from "../navigation";
import type {
	Repository,
	Site,
	SourceConnection,
	SourceProvider,
	SourceRepository,
	User,
} from "../types";

type Connections = {
	providers: SourceProvider[];
	connections: SourceConnection[];
};

export function ImportRepository({
	user,
	site,
}: {
	user: User | null;
	site?: Site;
}) {
	const action = useAction();
	const connectionAction = useAction();
	const connections = useResource<Connections>(user ? "/source-connections" : null);
	const connectionData = connections.value;
	const [connection, setConnection] = useState("");
	const selected = connections.value?.connections.find(
		(value) => value.id === connection,
	);
	const repositories = useResource<{ repositories: SourceRepository[] }>(
		selected && selected.provider !== "other"
			? `/source-connections/${selected.id}/repositories`
			: null,
	);
	const [url, setUrl] = useState("");
	const [branch, setBranch] = useState("");
	const [name, setName] = useState("");
	const [description, setDescription] = useState("");

	if (!user)
		return (
			<p>
				<a href="/login">Sign in</a> to import a repository.
			</p>
		);

	const choose = (repository: SourceRepository) => {
		setUrl(repository.url);
		setBranch(repository.branch || "");
		setName(repositoryName(repository.name));
		setDescription(repository.description || "");
	};

	const connect = (provider: SourceProvider) =>
		void connectionAction.run(async () => {
			const result = await send<{ authorization_url: string }>(
				`/source-connections/${provider.id}/start`,
			);
			window.location.assign(result.authorization_url);
		});

	return (
		<section className="narrow">
			<h1>Import a repository</h1>
			<p className="muted">
				Paste a public clone URL and import it directly. Connect an account to
				browse and import private repositories.
			</p>

			{connectionData &&
				connectionData.providers.length + connectionData.connections.length > 0 && (
				<section className="sourceconnections">
					<div className="row">
						{connectionData.providers.map((provider) => (
							<button
								type="button"
								onClick={() => connect(provider)}
								disabled={connectionAction.busy}
								key={provider.id}
							>
								Connect {provider.name}
							</button>
						))}
					</div>
					{connectionData.connections.length > 0 && (
						<>
							<label>
								Import using
								<select
									value={connection}
									onChange={(event) => setConnection(event.target.value)}
								>
									<option value="">No connection — public repository</option>
									{connectionData.connections.map((value) => (
										<option value={value.id} key={value.id}>
											{value.account} on {value.host}
										</option>
									))}
								</select>
							</label>
							<div className="connectedaccounts">
								{connectionData.connections.map((value) => (
									<div className="row" key={value.id}>
										<span>
											<strong>{value.account}</strong> on {value.host}
										</span>
										<button
											type="button"
											disabled={connectionAction.busy}
											onClick={() =>
												void connectionAction.run(async () => {
													await send(`/source-connections/${value.id}`, {}, "DELETE");
													if (connection === value.id) setConnection("");
													connections.reload();
												})
											}
										>
											Disconnect
										</button>
									</div>
								))}
							</div>
						</>
					)}
					<Alert>{connections.error || connectionAction.error}</Alert>
					{repositories.loading && <p className="muted">Loading repositories…</p>}
					<Alert>{repositories.error}</Alert>
					{repositories.value?.repositories.length ? (
						<div className="panel sourcerepositories">
							{repositories.value.repositories.map((repository) => (
								<button
									type="button"
									onClick={() => choose(repository)}
									key={repository.id}
								>
									<strong>{repository.full_name}</strong>
									<span>{repository.private ? "Private" : "Public"}</span>
								</button>
							))}
						</div>
					) : null}
				</section>
			)}

			<form
				className="form panel"
				onSubmit={(event) => {
					event.preventDefault();
					const values = Object.fromEntries(new FormData(event.currentTarget));
					void action.run(async () => {
						const repo = await send<Repository>("/imports", values);
						go(`/repositories/${repo.id}`);
					});
				}}
			>
				<input type="hidden" name="connection_id" value={connection} />
				<label>
					Source repository URL
					<input
						name="url"
						type="url"
						required
						placeholder="https://git.example.com/owner/repository"
						autoFocus
						maxLength={1000}
						value={url}
						onChange={(event) => setUrl(event.target.value)}
						onBlur={() => {
							if (!name) setName(repositoryName(url));
						}}
					/>
					<small>Public repositories need no account or access token.</small>
				</label>
				<label>
					Branch <span className="muted">(optional)</span>
					<input
						name="branch"
						maxLength={200}
						placeholder="Use the default branch"
						value={branch}
						onChange={(event) => setBranch(event.target.value)}
					/>
				</label>
				<label>
					Repository name in Flurry <span className="muted">(optional)</span>
					<input
						name="name"
						maxLength={80}
						pattern="[a-z0-9][a-z0-9.]*"
						placeholder="Taken from the clone URL"
						value={name}
						onChange={(event) => setName(event.target.value)}
					/>
					<small>Lowercase letters, numbers, and dots.</small>
				</label>
				<label>
					Description <span className="muted">(optional)</span>
					<input
						name="description"
						maxLength={500}
						value={description}
						onChange={(event) => setDescription(event.target.value)}
					/>
				</label>
				<label>
					Visibility
					<select
						name="visibility"
						defaultValue={
							site?.allow_public === false
								? "private"
								: user.preferences?.default_visibility ||
									site?.default_visibility ||
									"private"
						}
					>
						<option value="private">Private — only you can access it</option>
						<option value="public" disabled={site?.allow_public === false}>
							Public — anyone can browse it
						</option>
					</select>
				</label>
				<details className="credentials">
					<summary>Use a one-time access token</summary>
					<label>
						Git username <span className="muted">(optional)</span>
						<input
							name="username"
							autoComplete="off"
							placeholder="git"
							maxLength={200}
						/>
					</label>
					<label>
						Access token <span className="muted">(optional)</span>
						<input
							name="token"
							type="password"
							autoComplete="off"
							maxLength={4096}
						/>
						<small>Used only for this transfer and never saved.</small>
					</label>
				</details>
				<Alert>{action.error}</Alert>
				<div className="row">
					<button className="primary" disabled={action.busy}>
						{action.busy ? "Starting import…" : "Import repository"}
					</button>
					<a href="/new">Create an empty repository instead</a>
				</div>
			</form>

			<OtherConnection
				busy={connectionAction.busy}
				error={connectionAction.error}
				onSave={() => connections.reload()}
				run={connectionAction.run}
			/>
		</section>
	);
}

function OtherConnection({
	busy,
	error,
	onSave,
	run,
}: {
	busy: boolean;
	error: string;
	onSave: () => void;
	run: (action: () => Promise<void>) => Promise<void>;
}) {
	return (
		<details className="panel sourceother">
			<summary>Connect another Git host</summary>
			<form
				className="form"
				onSubmit={(event) => {
					event.preventDefault();
					const form = event.currentTarget;
					void run(async () => {
						await send("/source-connections", Object.fromEntries(new FormData(form)));
						form.reset();
						onSave();
					});
				}}
			>
				<label>
					Git host
					<input name="host" required placeholder="git.example.com" maxLength={253} />
				</label>
				<label>
					Git username
					<input name="username" placeholder="git" maxLength={200} />
				</label>
				<label>
					Access token
					<input
						name="token"
						type="password"
						required
						autoComplete="off"
						maxLength={4096}
					/>
					<small>Encrypted at rest and available only to your linked imports.</small>
				</label>
				<Alert>{error}</Alert>
				<button disabled={busy}>Save connection</button>
			</form>
		</details>
	);
}

function repositoryName(value: string) {
	try {
		const path = value.includes("://") ? new URL(value).pathname : value;
		return (
			path
				.split("/")
				.filter(Boolean)
				.at(-1)
				?.replace(/\.git$/, "")
				.toLowerCase()
				.replace(/[^a-z0-9.]+/g, ".")
				.replace(/^\.+|\.+$/g, "")
				.slice(0, 80) || ""
		);
	} catch {
		return "";
	}
}
