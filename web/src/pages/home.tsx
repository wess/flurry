import {
	Building2,
	Globe2,
	LockKeyhole,
	Plus,
	Search,
	UserRound,
} from "lucide-react";
import { useState } from "react";
import { send, useAction, useResource } from "../api";
import { Alert, Repositories } from "../components/common";
import { go } from "../navigation";
import type { Repository, User, Site } from "../types";

export function Home({
	user,
	explore,
}: {
	user: User | null;
	explore: boolean;
}) {
	const resource = useResource<{ repositories: Repository[] }>(
		user && !explore ? "/repositories" : "/explore",
	);
	const [filter, setFilter] = useState("");
	const repositories = resource.value?.repositories.filter((repo) =>
		`${repo.name} ${repo.description} ${repo.owner.username}`
			.toLowerCase()
			.includes(filter.toLowerCase()),
	);
	return (
		<section>
			<div className="pagetitle">
				<div>
					<h1>
						{explore || !user ? "Explore repositories" : "Your repositories"}
					</h1>
					<p className="muted">
						{explore || !user
							? "Public code from the people building here."
							: "A quiet place to keep work moving."}
					</p>
				</div>
				{user && (
					<a className="button primary" href="/new">
						<Plus size={16} />
						New repository
					</a>
				)}
			</div>
			<div className="search">
				<Search size={17} />
				<input
					aria-label="Find a repository"
					placeholder="Find a repository…"
					value={filter}
					onChange={(e) => setFilter(e.target.value)}
				/>
			</div>
			<Alert>{resource.error}</Alert>
			{resource.loading ? (
				<p className="muted">Loading repositories…</p>
			) : (
				repositories && <Repositories repositories={repositories} />
			)}
		</section>
	);
}

export function NewRepository({
	user,
	site,
}: {
	user: User | null;
	site?: Site;
}) {
	const action = useAction();
	const organizations = useResource<{
		organizations: { id: string; name: string; slug: string; role: string }[];
	}>(user ? "/organizations" : null);
	const [owner, setOwner] = useState("personal");
	const [name, setName] = useState("");
	if (!user)
		return (
			<p>
				<a href="/login">Sign in</a> to create a repository.
			</p>
		);
	return (
		<section className="narrow newrepository">
			<h1>New repository</h1>
			<p className="muted">
				Start a fresh project here, or{" "}
				<a href="/import">Import a repository</a>.
			</p>
			<form
				className="form panel"
				onSubmit={(event) => {
					event.preventDefault();
					const values = Object.fromEntries(new FormData(event.currentTarget));
					if (owner !== "personal") values.organization_id = owner;
					void action.run(async () => {
						const repo = await send<Repository>("/repositories", values);
						go(`/repositories/${repo.id}`);
					});
				}}
			>
				<div className="repositoryidentity">
					<label>
						Owner
						<span className="selectwithicon">
							{owner === "personal" ? (
								<UserRound size={16} />
							) : (
								<Building2 size={16} />
							)}
							<select
								value={owner}
								onChange={(event) => setOwner(event.target.value)}
							>
								<option value="personal">{user.username}</option>
								{organizations.value?.organizations
									.filter((organization) =>
										["admin", "owner"].includes(organization.role),
									)
									.map((organization) => (
										<option value={organization.id} key={organization.id}>
											{organization.slug}
										</option>
									))}
							</select>
						</span>
					</label>
					<span className="repositoryslash" aria-hidden="true">
						/
					</span>
					<label>
						Repository name
						<input
							name="name"
							required
							maxLength={80}
							pattern="[a-z0-9][a-z0-9.]*"
							placeholder="myproject"
							autoFocus
							value={name}
							onChange={(event) => setName(event.target.value.toLowerCase())}
						/>
					</label>
				</div>
				<p className="repositorypreview">
					Your repository will be created as{" "}
					<strong>
						{owner === "personal"
							? user.username
							: organizations.value?.organizations.find(
									(organization) => organization.id === owner,
								)?.slug || "organization"}
						/{name || "repository"}
					</strong>
					.
				</p>
				<label>
					Description <span className="muted">(optional)</span>
					<input name="description" maxLength={500} />
				</label>
				<fieldset className="choicegroup">
					<legend>Visibility</legend>
					<label className="choice">
						<input
							type="radio"
							name="visibility"
							value="private"
							defaultChecked={
								site?.allow_public === false
									? true
									: (user.preferences?.default_visibility ||
											site?.default_visibility ||
											"private") === "private"
							}
						/>
						<LockKeyhole size={17} />
						<span>
							<strong>Private</strong>
							<small>Only you and people you give access can see it.</small>
						</span>
					</label>
					<label className="choice">
						<input
							type="radio"
							name="visibility"
							value="public"
							disabled={site?.allow_public === false}
							defaultChecked={
								site?.allow_public !== false &&
								(user.preferences?.default_visibility ||
									site?.default_visibility) === "public"
							}
						/>
						<Globe2 size={17} />
						<span>
							<strong>Public</strong>
							<small>Anyone can browse this repository.</small>
						</span>
					</label>
				</fieldset>
				<fieldset className="initializesettings">
					<legend>Initialize this repository</legend>
					<p className="muted">
						Skip these options if you plan to push an existing repository.
					</p>
					<label className="check">
						<input type="checkbox" name="initialize_readme" /> Add a README
					</label>
					<div className="initializeselects">
						<label>
							Add .gitignore
							<select name="gitignore_template" defaultValue="">
								<option value="">None</option>
								<option value="node">Node</option>
								<option value="python">Python</option>
								<option value="rust">Rust</option>
								<option value="elixir">Elixir</option>
							</select>
						</label>
						<label>
							Choose a license
							<select name="license_template" defaultValue="">
								<option value="">None</option>
								<option value="mit">MIT License</option>
								<option value="bsd-3-clause">BSD 3-Clause</option>
								<option value="isc">ISC License</option>
							</select>
						</label>
					</div>
				</fieldset>
				<Alert>{action.error}</Alert>
				<div>
					<button className="primary" disabled={action.busy}>
						{action.busy ? "Creating…" : "Create repository"}
					</button>
				</div>
			</form>
		</section>
	);
}
