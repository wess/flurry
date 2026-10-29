import { useEffect, useState } from "react";
import { Breadcrumb } from "@wess/atlas-ui/nav/index.tsx";
import {
	FileCode2,
	Folder,
	Activity,
	Bot,
	BookOpen,
	Check,
	CircleDot,
	Copy,
	GitBranch,
	GitCommitHorizontal,
	MessageSquare,
	Plus,
	RefreshCw,
	Search as SearchIcon,
	Settings,
	Tag,
	Terminal,
} from "lucide-react";
import { useResource } from "../api";
import { Alert, Empty, Visibility } from "../components/common";
import { date, dateTime, go, profilePath, short } from "../navigation";
import { Compose } from "../components/compose";
import { SourceLink } from "../components/source";
import { SyntaxBlock } from "../components/syntax";
import { RepositorySettings } from "./settings/repository";
import { ReviewsPage, ReviewPage } from "./reviews";
import { Issues, Releases, Wiki } from "./collaboration";
import type {
	ActivityEvent,
	Change,
	FileContent,
	Repository,
	Site,
	Tree,
	User,
} from "../types";

export function RepositoryPage({
	id,
	section,
	review,
	query,
	user,
	site,
}: {
	id: string;
	section?: string;
	review?: string;
	query: URLSearchParams;
	user: User | null;
	site?: Site;
}) {
	const resource = useResource<Repository>(`/repositories/${id}`);
	const repo = resource.value;
	useEffect(() => {
		const tabs = document.querySelector<HTMLElement>(".tabs");
		const active = tabs?.querySelector<HTMLElement>("a.active");
		if (!tabs || !active) return;
		const reveal = () => {
			const tabBounds = tabs.getBoundingClientRect();
			const activeBounds = active.getBoundingClientRect();
			const delta =
				activeBounds.left +
				activeBounds.width / 2 -
				(tabBounds.left + tabBounds.width / 2);
			tabs.scrollLeft = Math.max(0, tabs.scrollLeft + delta);
		};
		const frame = window.requestAnimationFrame(reveal);
		const observer = new ResizeObserver(reveal);
		observer.observe(tabs);
		window.addEventListener("resize", reveal);
		return () => {
			window.cancelAnimationFrame(frame);
			observer.disconnect();
			window.removeEventListener("resize", reveal);
		};
	}, [section, repo?.id]);
	const [compose, setCompose] = useState(false);
	const [edit, setEdit] = useState<
		{ path: string; content: string } | undefined
	>();
	if (!repo) return <Alert>{resource.error || "Loading repository…"}</Alert>;
	const base = `/repositories/${repo.id}`;
	const own = repo.owner.id === user?.id || repo.role === "owner";
	const write =
		!repo.archived &&
		(own || repo.role === "write" || repo.role === "maintain");
	const maintain = !repo.archived && (own || repo.role === "maintain");
	const open = (file?: { path: string; content: string }) => {
		setEdit(file);
		setCompose(true);
	};
	return (
		<section>
			<div className="repoheading">
				<Breadcrumb
					items={[
						{
							label: repo.owner.username,
							href: profilePath(repo.owner.username),
						},
						{ label: repo.name },
					]}
				/>
				<Visibility value={repo.visibility} />
				{repo.archived && <span className="badge">Archived</span>}
			</div>
			{repo.description && (
				<p className="repodescription">{repo.description}</p>
			)}
			{repo.head && (!section || section === "files") && (
				<CloneCommands repo={repo} user={user} site={site} />
			)}
			<SourceLink repo={repo} own={own} changed={resource.reload} />
			<div className="tabs" role="navigation" aria-label="Repository sections">
				<a
					className={!section || section === "files" ? "active" : ""}
					href={base}
				>
					<FileCode2 size={16} />
					Files
				</a>
				<a
					className={section === "issues" ? "active" : ""}
					href={`${base}/issues`}
				>
					<CircleDot size={16} />
					Issues
				</a>
				<a
					className={section === "reviews" ? "active" : ""}
					href={`${base}/reviews`}
				>
					<MessageSquare size={16} />
					Reviews
				</a>
				<a
					className={section === "releases" ? "active" : ""}
					href={`${base}/releases`}
				>
					<Tag size={16} /> Releases
				</a>
				<a
					className={section === "wiki" ? "active" : ""}
					href={`${base}/wiki`}
				>
					<BookOpen size={16} /> Wiki
				</a>
				<a
					className={section === "history" ? "active" : ""}
					href={`${base}/history`}
				>
					<GitCommitHorizontal size={16} />
					History
				</a>
				<a
					className={section === "activity" ? "active" : ""}
					href={`${base}/activity`}
				>
					<Activity size={16} />
					Activity
				</a>
				<div className="grow" />
				{own && (
					<a
						href={`${base}/settings`}
						className={section === "settings" ? "active" : ""}
					>
						<Settings size={15} />
						Settings
					</a>
				)}
				{write && (
					<button className="primary small" onClick={() => open()}>
						<Plus size={14} />
						New change
					</button>
				)}
			</div>
			{section === "settings" ? (
				<RepositorySettings repo={repo} user={user} changed={resource.reload} />
			) : section === "reviews" ? (
				review ? (
					<ReviewPage
						key={review}
						repo={repo}
						id={review}
						own={maintain}
						user={user}
						changed={resource.reload}
					/>
				) : (
					<ReviewsPage repo={repo} />
				)
			) : section === "issues" ? (
				<Issues repo={repo} number={review} user={user} write={write} />
			) : section === "releases" ? (
				<Releases repo={repo} user={user} write={write} />
			) : section === "wiki" ? (
				<Wiki key={review || "index"} repo={repo} slug={review} write={write} />
			) : section === "history" ? (
				<History repo={repo} />
			) : section === "activity" ? (
				<ActivityPage repo={repo} />
			) : (
				<Files
					key={`${id}:${query.toString()}:${repo.head}`}
					repo={repo}
					query={query}
					own={write}
					edit={open}
				/>
			)}
			{compose && (
				<Compose repo={repo} initial={edit} close={() => setCompose(false)} />
			)}
		</section>
	);
}

function ActivityPage({ repo }: { repo: Repository }) {
	const resource = useResource<{ events: ActivityEvent[] }>(
		`/repositories/${repo.id}/activity`,
	);
	return (
		<>
			<div className="sectionheading">
				<div>
					<h2>Repository activity</h2>
					<p className="muted">
						Changes, reviews, checks, and evaluation attempts in one timeline.
					</p>
				</div>
				<button className="small" onClick={resource.reload}>
					<RefreshCw size={13} /> Refresh
				</button>
			</div>
			<Alert>{resource.error}</Alert>
			{resource.loading ? (
				<p className="muted">Loading activity…</p>
			) : resource.value?.events.length ? (
				<div className="panel activitytimeline">
					{resource.value.events.map((event) => {
						const href = event.review_id
							? `/repositories/${repo.id}/reviews/${event.review_id}`
							: event.changeset_id
								? `/repositories/${repo.id}?revision=${event.changeset_id}`
								: undefined;
						const content = (
							<>
								<span className="activityicon" aria-hidden="true">
									{event.type.startsWith("evaluation") ? (
										<Bot size={16} />
									) : (
										<GitCommitHorizontal size={16} />
									)}
								</span>
								<span className="grow">
									<strong>{event.title}</strong>
									<small>
										{event.detail || event.type.replaceAll(".", " ")}
									</small>
								</span>
								<span className="activitymeta">
									{event.state && (
										<span className={`status ${event.state}`}>
											{event.state.replace("_", " ")}
										</span>
									)}
									<time dateTime={event.inserted_at}>
										{dateTime(event.inserted_at)}
									</time>
								</span>
							</>
						);
						return href ? (
							<a className="activityrow" href={href} key={event.id}>
								{content}
							</a>
						) : (
							<div className="activityrow" key={event.id}>
								{content}
							</div>
						);
					})}
				</div>
			) : (
				<Empty title="No repository activity">
					Submitted changes and evaluations will appear here.
				</Empty>
			)}
		</>
	);
}

function CloneCommands({
	repo,
	user,
	site,
}: {
	repo: Repository;
	user: User | null;
	site?: Site;
}) {
	const https = `${window.location.origin}/repositories/${repo.id}.git`;
	const ssh =
		user && site?.ssh_port
			? `ssh://${user.username}@${window.location.hostname}:${site.ssh_port}/repositories/${repo.id}.git`
			: null;
	return (
		<details className="clonecommands">
			<summary>
				<Terminal size={15} /> Clone repository
			</summary>
			<div>
				<label>
					HTTPS
					<code>{https}</code>
				</label>
				{ssh && (
					<label>
						SSH
						<code>{ssh}</code>
					</label>
				)}
			</div>
		</details>
	);
}

function History({ repo }: { repo: Repository }) {
	const resource = useResource<{ changesets: Change[] }>(
		`/repositories/${repo.id}/history`,
	);
	return (
		<>
			<Alert>{resource.error}</Alert>
			{resource.loading ? (
				<p className="muted">Loading history…</p>
			) : resource.value?.changesets.length ? (
				<div className="panel history">
					{resource.value.changesets.map((change) => (
						<div className="historyrow" key={change.id}>
							<GitCommitHorizontal size={18} />
							<div className="grow">
								<a href={`/repositories/${repo.id}?revision=${change.id}`}>
									{change.message}
								</a>
								<small>
									{change.author.name} committed {date(change.inserted_at)}
									{change.source ? " • rebased on landing" : ""}
								</small>
							</div>
							<code>{short(change.id)}</code>
						</div>
					))}
				</div>
			) : (
				<Empty title="No landed changes">
					Submit a change, approve it, and land it to start this repository’s
					history.
				</Empty>
			)}
		</>
	);
}

function Files({
	repo,
	query,
	own,
	edit,
}: {
	repo: Repository;
	query: URLSearchParams;
	own: boolean;
	edit: (file: { path: string; content: string }) => void;
}) {
	const directory = query.get("path") || "";
	const file = query.get("file");
	const search = query.get("search") || "";
	const revision = query.get("revision") || "main";
	const args = new URLSearchParams({ revision, path: directory });
	const resource = useResource<Tree>(
		file || search ? null : `/repositories/${repo.id}/tree?${args}`,
	);
	const content = useResource<FileContent>(
		file
			? `/repositories/${repo.id}/file?${new URLSearchParams({ revision, path: file, preview: "true" })}`
			: null,
	);
	const results = useResource<{
		matches: { path: string; line: number; text: string; hash: string }[];
		truncated: boolean;
	}>(
		search
			? `/repositories/${repo.id}/search?${new URLSearchParams({ revision, query: search })}`
			: null,
	);
	const link = (path: string, selected?: string) =>
		`/repositories/${repo.id}?${new URLSearchParams({ path, revision, ...(selected ? { file: selected } : {}) })}`;
	const path = file || directory;
	const segments = path.split("/").filter(Boolean);
	return (
		<>
			<div className="filetoolbar">
				<span className="branch">
					<GitBranch size={15} />
					{revision === "main" ? "main" : short(revision)}
				</span>
				<div className="filebreadcrumbs">
					<a href={link("")}>{repo.name}</a>
					{segments.map((name, index) => (
						<span key={index}>
							{" "}
							/{" "}
							{index === segments.length - 1 ? (
								name
							) : (
								<a href={link(segments.slice(0, index + 1).join("/"))}>
									{name}
								</a>
							)}
						</span>
					))}
				</div>
				<form
					className="repositorysearch"
					role="search"
					onSubmit={(event) => {
						event.preventDefault();
						const value = new FormData(event.currentTarget).get("search");
						const term = typeof value === "string" ? value.trim() : "";
						if (term)
							go(
								`/repositories/${repo.id}?${new URLSearchParams({ revision, search: term })}`,
							);
					}}
				>
					<SearchIcon size={14} aria-hidden="true" />
					<input
						key={search}
						name="search"
						aria-label="Search repository code"
						placeholder="Search code"
						defaultValue={search}
						maxLength={200}
					/>
				</form>
				<button
					className="iconbutton"
					aria-label="Refresh files"
					onClick={() =>
						file
							? content.reload()
							: search
								? results.reload()
								: resource.reload()
					}
				>
					<RefreshCw size={15} />
				</button>
			</div>
			<Alert>{resource.error || content.error || results.error}</Alert>
			{search ? (
				results.value ? (
					results.value.matches.length ? (
						<div className="panel searchresults">
							<div className="panelheading">
								<span>
									{results.value.matches.length} result
									{results.value.matches.length === 1 ? "" : "s"} for “{search}”
								</span>
								<a href={link("")}>Clear search</a>
							</div>
							{results.value.matches.map((match) => (
								<a
									className="searchresult"
									href={link(
										match.path.split("/").slice(0, -1).join("/"),
										match.path,
									)}
									key={`${match.path}:${match.line}`}
								>
									<strong>{match.path}</strong>
									<span>Line {match.line}</span>
									<code>{match.text || " "}</code>
								</a>
							))}
							{results.value.truncated && (
								<p className="padded muted">Showing the first 100 matches.</p>
							)}
						</div>
					) : (
						<Empty title="No matching code">
							No lines in this revision contain “{search}”.{" "}
							<a href={link("")}>Clear search</a>
						</Empty>
					)
				) : (
					results.loading && <p className="muted">Searching code…</p>
				)
			) : file ? (
				content.value ? (
					<div className="panel fileviewer">
						<div className="panelheading">
							<span>{content.value.size.toLocaleString()} bytes</span>
							<div className="row">
								<a
									href={`/api/repositories/${repo.id}/file?${new URLSearchParams({ path: file, revision, raw: "true" })}`}
								>
									Download
								</a>
								{own &&
									content.value.encoding === "utf8" &&
									!content.value.truncated &&
									revision === "main" && (
										<button
											className="small"
											onClick={() =>
												edit({ path: file, content: content.value!.content })
											}
										>
											Edit file
										</button>
									)}
							</div>
						</div>
						{content.value.truncated && (
							<p className="padded muted">
								Large file preview. Download to view the complete file.
							</p>
						)}
						{content.value.encoding === "utf8" ? (
							<SyntaxBlock content={content.value.content} path={file} />
						) : (
							<Empty title="Binary file">
								Download this file to view its contents.
							</Empty>
						)}
					</div>
				) : (
					content.loading && <p className="muted">Loading file…</p>
				)
			) : resource.value ? (
				resource.value.entries.length ? (
					<div className="panel filetable">
						{directory && (
							<a
								className="fileentry"
								href={link(directory.split("/").slice(0, -1).join("/"))}
							>
								<Folder size={17} />
								<span>..</span>
							</a>
						)}
						{resource.value.entries.map((entry) => {
							const path = [directory, entry.name].filter(Boolean).join("/");
							return (
								<a
									className="fileentry"
									href={
										entry.type === "tree" ? link(path) : link(directory, path)
									}
									key={entry.name}
								>
									{entry.type === "tree" ? (
										<Folder size={17} className="folder" />
									) : (
										<FileCode2 size={17} />
									)}
									<span className="grow">{entry.name}</span>
									<span className="muted">
										{entry.type === "tree" ? "Directory" : "File"}
									</span>
								</a>
							);
						})}
					</div>
				) : own ? (
					<EmptyRepositorySetup repo={repo} />
				) : (
					<Empty title="This repository is empty">
						The owner hasn’t landed any files yet.
					</Empty>
				)
			) : (
				resource.loading && <p className="muted">Loading files…</p>
			)}
		</>
	);
}

function CopyCommand({ value, label }: { value: string; label: string }) {
	const [copied, setCopied] = useState(false);
	return (
		<div className="commandblock">
			<pre>
				<code>{value}</code>
			</pre>
			<button
				type="button"
				className="iconbutton"
				aria-label={copied ? "Copied" : label}
				onClick={() => {
					void navigator.clipboard.writeText(value).then(() => {
						setCopied(true);
						window.setTimeout(() => setCopied(false), 1800);
					});
				}}
			>
				{copied ? <Check size={16} /> : <Copy size={16} />}
			</button>
		</div>
	);
}

function EmptyRepositorySetup({ repo }: { repo: Repository }) {
	const remote = `${window.location.origin}/repositories/${repo.id}.git`;
	const fresh = `echo "# ${repo.name}" >> README.md\ngit init\ngit add README.md\ngit commit -m "Initial commit"\ngit branch -M main\ngit remote add origin ${remote}\ngit push -u origin main`;
	const existing = `git remote add origin ${remote}\ngit branch -M main\ngit push -u origin main`;
	return (
		<div className="emptysetup panel">
			<div className="emptysetupintro">
				<div>
					<h2>Start this repository</h2>
					<p className="muted">
						Create a first commit locally, push an existing repository, or
						import code from another host.
					</p>
				</div>
				<a className="button" href="/import">
					Import code
				</a>
			</div>
			<section>
				<h3>Create a new repository on the command line</h3>
				<CopyCommand value={fresh} label="Copy new repository commands" />
			</section>
			<section>
				<h3>Push an existing repository from the command line</h3>
				<CopyCommand
					value={existing}
					label="Copy existing repository commands"
				/>
			</section>
			<p className="muted emptysetuphint">
				Prefer the browser? Use <strong>New change</strong> above to add your
				first files.
			</p>
		</div>
	);
}
