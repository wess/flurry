import { useState } from "react";
import { BookOpen, CircleDot, PackageOpen, Plus } from "lucide-react";
import { send, useAction, useResource } from "../api";
import { Alert, Empty } from "../components/common";
import { date, go } from "../navigation";
import type { Repository, User } from "../types";

type Person = Pick<User, "id" | "name" | "username">;
type Issue = {
	number: number;
	title: string;
	body: string;
	state: "open" | "closed";
	locked: boolean;
	author: Person;
	labels: { id: string; name: string; color: string }[];
	comments?: {
		id: string;
		body: string;
		author: Person;
		inserted_at: string;
	}[];
	inserted_at: string;
};
type Release = {
	id: string;
	tag: string;
	title: string;
	notes: string;
	draft: boolean;
	prerelease: boolean;
	assets: { id: string; name: string; bytes: number }[];
	inserted_at: string;
};
type WikiPage = {
	slug: string;
	title: string;
	body: string;
	version: number;
	updated_at: string;
};

export function Issues({
	repo,
	number,
	user,
	write,
}: {
	repo: Repository;
	number?: string;
	user: User | null;
	write: boolean;
}) {
	return number ? (
		<IssueDetail repo={repo} number={number} user={user} write={write} />
	) : (
		<IssueList repo={repo} user={user} />
	);
}

function IssueList({ repo, user }: { repo: Repository; user: User | null }) {
	const resource = useResource<{ issues: Issue[] }>(
		`/repositories/${repo.id}/issues?state=all`,
	);
	const action = useAction();
	const [creating, setCreating] = useState(false);
	return (
		<div className="collaborationpage">
			<div className="sectionheading">
				<div>
					<h2>Issues</h2>
					<p>Track decisions, defects, and follow-up work.</p>
				</div>
				{user && (
					<button
						className="primary small"
						onClick={() => setCreating(!creating)}
					>
						<Plus size={14} />
						New issue
					</button>
				)}
			</div>
			<Alert>{resource.error || action.error}</Alert>
			{creating && (
				<form
					className="form panel"
					onSubmit={(event) => {
						event.preventDefault();
						const values = new FormData(event.currentTarget);
						void action.run(async () => {
							const issue = await send<Issue>(
								`/repositories/${repo.id}/issues`,
								{ title: values.get("title"), body: values.get("body") },
							);
							go(`/repositories/${repo.id}/issues/${issue.number}`);
						});
					}}
				>
					<label>
						Title
						<input name="title" required maxLength={200} />
					</label>
					<label>
						Details
						<textarea name="body" rows={7} />
					</label>
					<button className="primary" disabled={action.busy}>
						Create issue
					</button>
				</form>
			)}
			{resource.value?.issues.length ? (
				<div className="panel collaborationlist">
					{resource.value.issues.map((issue) => (
						<a
							key={issue.number}
							href={`/repositories/${repo.id}/issues/${issue.number}`}
						>
							<CircleDot size={17} />
							<span className="grow">
								<strong>{issue.title}</strong>
								<small>
									#{issue.number} opened by {issue.author.name} ·{" "}
									{date(issue.inserted_at)}
								</small>
							</span>
							<span className="badge">{issue.state}</span>
						</a>
					))}
				</div>
			) : (
				!resource.loading && (
					<Empty title="No issues">
						Open an issue when work needs a durable place for discussion.
					</Empty>
				)
			)}
		</div>
	);
}

function IssueDetail({
	repo,
	number,
	user,
	write,
}: {
	repo: Repository;
	number: string;
	user: User | null;
	write: boolean;
}) {
	const resource = useResource<Issue>(
		`/repositories/${repo.id}/issues/${number}`,
	);
	const action = useAction();
	const issue = resource.value;
	return (
		<div className="collaborationpage">
			<Alert>{resource.error || action.error}</Alert>
			{issue && (
				<>
					<div className="sectionheading">
						<div>
							<h2>{issue.title}</h2>
							<p>
								#{issue.number} opened by {issue.author.name} ·{" "}
								{date(issue.inserted_at)}
							</p>
						</div>
						{write && (
							<button
								className="small"
								disabled={action.busy}
								onClick={() =>
									void action.run(async () => {
										await send(
											`/repositories/${repo.id}/issues/${number}`,
											{ state: issue.state === "open" ? "closed" : "open" },
											"PATCH",
										);
										resource.reload();
									})
								}
							>
								{issue.state === "open" ? "Close issue" : "Reopen issue"}
							</button>
						)}
					</div>
					<div className="panel discussion">
						<article>
							<strong>{issue.author.name}</strong>
							<p>{issue.body || "No details provided."}</p>
						</article>
						{issue.comments?.map((comment) => (
							<article key={comment.id}>
								<strong>{comment.author.name}</strong>
								<small>{date(comment.inserted_at)}</small>
								<p>{comment.body}</p>
							</article>
						))}
					</div>
					{user && !issue.locked && (
						<form
							className="form panel"
							onSubmit={(event) => {
								event.preventDefault();
								const form = event.currentTarget;
								const body = new FormData(form).get("body");
								void action.run(async () => {
									await send(
										`/repositories/${repo.id}/issues/${number}/comments`,
										{ body },
									);
									form.reset();
									resource.reload();
								});
							}}
						>
							<label>
								Add a comment
								<textarea name="body" rows={4} required />
							</label>
							<button className="primary" disabled={action.busy}>
								Comment
							</button>
						</form>
					)}
				</>
			)}
		</div>
	);
}

export function Releases({
	repo,
	user,
	write,
}: {
	repo: Repository;
	user: User | null;
	write: boolean;
}) {
	const resource = useResource<{ releases: Release[] }>(
		`/repositories/${repo.id}/releases`,
	);
	const action = useAction();
	const [creating, setCreating] = useState(false);
	return (
		<div className="collaborationpage">
			<div className="sectionheading">
				<div>
					<h2>Releases</h2>
					<p>Publish named, immutable points in repository history.</p>
				</div>
				{user && write && (
					<button
						className="primary small"
						onClick={() => setCreating(!creating)}
					>
						<Plus size={14} />
						New release
					</button>
				)}
			</div>
			<Alert>{resource.error || action.error}</Alert>
			{creating && (
				<form
					className="form panel"
					onSubmit={(event) => {
						event.preventDefault();
						const form = event.currentTarget;
						const values = new FormData(form);
						void action.run(async () => {
							await send(`/repositories/${repo.id}/releases`, {
								tag: values.get("tag"),
								title: values.get("title"),
								notes: values.get("notes"),
								draft: false,
								prerelease: values.get("prerelease") === "on",
							});
							form.reset();
							setCreating(false);
							resource.reload();
						});
					}}
				>
					<label>
						Existing tag
						<input name="tag" required />
					</label>
					<label>
						Title
						<input name="title" required maxLength={200} />
					</label>
					<label>
						Notes
						<textarea name="notes" rows={7} />
					</label>
					<label className="check">
						<input type="checkbox" name="prerelease" />
						Mark as prerelease
					</label>
					<button className="primary" disabled={action.busy}>
						Publish release
					</button>
				</form>
			)}
			{resource.value?.releases.length ? (
				<div className="collaborationlist">
					{resource.value.releases.map((release) => (
						<article className="panel releasecard" key={release.id}>
							<PackageOpen size={20} />
							<div className="grow">
								<h3>{release.title}</h3>
								<small>
									{release.tag} · {date(release.inserted_at)}
									{release.prerelease ? " · prerelease" : ""}
								</small>
								<p>{release.notes}</p>
								{release.assets.map((asset) => (
									<a
										key={asset.id}
										href={`/api/repositories/${repo.id}/release-assets/${asset.id}`}
									>
										{asset.name} ({asset.bytes.toLocaleString()} bytes)
									</a>
								))}
							</div>
						</article>
					))}
				</div>
			) : (
				!resource.loading && (
					<Empty title="No releases">
						Create a tag, then publish a release for it.
					</Empty>
				)
			)}
		</div>
	);
}

export function Wiki({
	repo,
	slug,
	write,
}: {
	repo: Repository;
	slug?: string;
	write: boolean;
}) {
	const list = useResource<{ pages: WikiPage[] }>(
		slug ? null : `/repositories/${repo.id}/wiki`,
	);
	const page = useResource<WikiPage>(
		slug ? `/repositories/${repo.id}/wiki/${slug}` : null,
	);
	const action = useAction();
	const location = slug || "index";
	const [editingFor, setEditingFor] = useState<string | null>(null);
	const editing = editingFor === location;
	if (!slug)
		return (
			<div className="collaborationpage">
				<div className="sectionheading">
					<div>
						<h2>Wiki</h2>
						<p>Keep repository knowledge close to the work.</p>
					</div>
					{write && (
						<button
							className="primary small"
							onClick={() => setEditingFor(editing ? null : location)}
						>
							<Plus size={14} />
							New page
						</button>
					)}
				</div>
				<Alert>{list.error || action.error}</Alert>
				{editing && (
					<WikiForm
						repo={repo}
						action={action}
						saved={(savedSlug) => {
							setEditingFor(null);
							go(`/repositories/${repo.id}/wiki/${savedSlug}`);
						}}
					/>
				)}
				{list.value?.pages.length ? (
					<div className="panel collaborationlist">
						{list.value.pages.map((item) => (
							<a
								key={item.slug}
								href={`/repositories/${repo.id}/wiki/${item.slug}`}
							>
								<BookOpen size={17} />
								<span>
									<strong>{item.title}</strong>
									<small>{item.slug}</small>
								</span>
							</a>
						))}
					</div>
				) : (
					!list.loading && (
						<Empty title="No wiki pages">
							Create the first page for guides, decisions, or runbooks.
						</Empty>
					)
				)}
			</div>
		);
	return (
		<div className="collaborationpage">
			<Alert>{page.error || action.error}</Alert>
			{page.value && (
				<>
					<div className="sectionheading">
						<div>
							<h2>{page.value.title}</h2>
							<p>
								Version {page.value.version} · updated{" "}
								{date(page.value.updated_at)}
							</p>
						</div>
						{write && (
							<button
								className="small"
								onClick={() => setEditingFor(editing ? null : location)}
							>
								Edit page
							</button>
						)}
					</div>
					{editing ? (
						<WikiForm
							repo={repo}
							action={action}
							page={page.value}
							saved={() => {
								setEditingFor(null);
								page.reload();
							}}
						/>
					) : (
						<article className="panel wikipage">{page.value.body}</article>
					)}
				</>
			)}
		</div>
	);
}

function WikiForm({
	repo,
	action,
	page,
	saved,
}: {
	repo: Repository;
	action: ReturnType<typeof useAction>;
	page?: WikiPage;
	saved?: (slug: string) => void;
}) {
	return (
		<form
			className="form panel"
			onSubmit={(event) => {
				event.preventDefault();
				const values = new FormData(event.currentTarget);
				const slug = String(values.get("slug"));
				void action.run(async () => {
					await send(
						`/repositories/${repo.id}/wiki/${slug}`,
						{
							title: values.get("title"),
							body: values.get("body"),
							version: page?.version,
						},
						"PUT",
					);
					if (saved) saved(slug);
					else go(`/repositories/${repo.id}/wiki/${slug}`);
				});
			}}
		>
			<label>
				Slug
				<input
					name="slug"
					required
					pattern="[a-z0-9][a-z0-9-]{0,99}"
					defaultValue={page?.slug}
					readOnly={Boolean(page)}
				/>
			</label>
			<label>
				Title
				<input
					name="title"
					required
					maxLength={200}
					defaultValue={page?.title}
				/>
			</label>
			<label>
				Content
				<textarea name="body" rows={14} defaultValue={page?.body} />
			</label>
			<button className="primary" disabled={action.busy}>
				Save page
			</button>
		</form>
	);
}
