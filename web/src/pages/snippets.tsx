import { useState } from "react";
import { Copy, FileCode2, GitFork, History, Plus, Star } from "lucide-react";
import { send, useAction, useResource } from "../api";
import { Alert, Empty } from "../components/common";
import { SyntaxBlock, syntaxLanguage } from "../components/syntax";
import { date, dateTime, go, publicProfilePath, snippetPath } from "../navigation";
import type { Snippet, SnippetFile, User } from "../types";
import { SnippetEditor } from "./snippets/editor";
import { Visibility } from "./snippets/shared";

export function SnippetsPage({
	user,
	slug,
	section,
	version,
}: {
	user: User | null;
	slug?: string;
	section?: string;
	version?: string | null;
}) {
	if (slug === "new") return <SnippetEditor user={user} />;
	if (slug)
		return (
			<SnippetView
				user={user}
				slug={slug}
				edit={section === "edit"}
				version={version}
			/>
		);
	return <SnippetIndex user={user} />;
}

function SnippetIndex({ user }: { user: User | null }) {
	const [mine, setMine] = useState(false);
	const [query, setQuery] = useState("");
	const [search, setSearch] = useState("");
	const params = new URLSearchParams();
	if (mine) params.set("mine", "true");
	if (search) params.set("query", search);
	const resource = useResource<{ snippets: Snippet[] }>("/snippets?" + params);
	const snippets = resource.value?.snippets || [];

	return (
		<section className="snippets">
			<div className="snippetmast">
				<div>
					<h1>Snippets</h1>
					<p>Small pieces of code with durable links and revision history.</p>
				</div>
				{user ? (
					<a className="button primary" href={snippetPath("new")}>
						<Plus size={15} /> New snippet
					</a>
				) : (
					<a className="button primary" href="/login">
						Sign in to create
					</a>
				)}
			</div>
			<div className="snippettools">
				<form
					className="snippetsearch"
					onSubmit={(event) => {
						event.preventDefault();
						setSearch(query.trim());
					}}
				>
					<input
						aria-label="Search snippets"
						placeholder="Search snippets"
						value={query}
						onChange={(event) => setQuery(event.target.value)}
					/>
					<button className="small">Search</button>
				</form>
				{user && (
					<div className="snippetfilters" aria-label="Snippet scope">
						<button
							className={"small " + (!mine ? "selected" : "")}
							onClick={() => setMine(false)}
						>
							Public
						</button>
						<button
							className={"small " + (mine ? "selected" : "")}
							onClick={() => setMine(true)}
						>
							Yours
						</button>
					</div>
				)}
			</div>
			<Alert>{resource.error}</Alert>
			{resource.loading ? (
				<p className="muted">Loading snippets…</p>
			) : snippets.length ? (
				<div className="panel snippetlist">
					{snippets.map((snippet) => (
						<SnippetRow key={snippet.id} snippet={snippet} />
					))}
				</div>
			) : (
				<Empty title={mine ? "No snippets yet" : "No public snippets found"}>
					{mine
						? "Create a snippet to keep a small piece of code close."
						: "Try a different search."}
				</Empty>
			)}
		</section>
	);
}

function SnippetRow({ snippet }: { snippet: Snippet }) {
	return (
		<a className="snippetrow" href={snippetPath(snippet.slug)}>
			<FileCode2 size={18} />
			<span>
				<strong>{snippet.title}</strong>
				<small>
					{snippet.author.username} · updated {date(snippet.updated_at)}
				</small>
			</span>
			<span className="snippetrowmeta">
				{snippet.visibility !== "public" && <Visibility value={snippet.visibility} />}
				<Star size={13} /> {snippet.stars}
			</span>
		</a>
	);
}

function SnippetView({
	user,
	slug,
	edit,
	version,
}: {
	user: User | null;
	slug: string;
	edit: boolean;
	version?: string | null;
}) {
	const path =
		"/snippets/" +
		encodeURIComponent(slug) +
		(version ? "?version=" + encodeURIComponent(version) : "");
	const resource = useResource<Snippet>(path);
	const action = useAction();
	const snippet = resource.value;
	if (!snippet) return <Alert>{resource.error || "Loading snippet…"}</Alert>;
	if (edit) return <SnippetEditor user={user} snippet={snippet} />;
	const current = !version || Number(version) === snippet.version;

	return (
		<section className="snippets snippetdetail">
			<a className="backlink" href={snippetPath()}>
				All snippets
			</a>
			<div className="snippetheading">
				<div>
					<h1>{snippet.title}</h1>
					<p>
						<a href={publicProfilePath(snippet.author.username)}>
							{snippet.author.username}
						</a>
						{" · "}
						{dateTime(snippet.revision?.inserted_at || snippet.updated_at)}
						{" · "}
						<Visibility value={snippet.visibility} />
					</p>
				</div>
				<div className="snippetactions">
					{user && (
						<button
							className="small"
							disabled={action.busy}
							onClick={() =>
								void action.run(async () => {
									await send("/snippets/" + slug + "/star", {
										enabled: !snippet.starred,
									});
									resource.reload();
								})
							}
						>
							<Star size={14} fill={snippet.starred ? "currentColor" : "none"} />
							{snippet.stars}
						</button>
					)}
					{user && (
						<button
							className="small"
							disabled={action.busy}
							onClick={() =>
								void action.run(async () => {
									const fork = await send<Snippet>("/snippets/" + slug + "/fork");
									go(snippetPath(fork.slug));
								})
							}
						>
							<GitFork size={14} /> Fork
						</button>
					)}
					{snippet.owner && current && (
						<a className="button small" href={snippetPath(slug + "/edit")}>
							Edit
						</a>
					)}
				</div>
			</div>
			{snippet.description && <p className="snippetdescription">{snippet.description}</p>}
			{snippet.forked_from && (
				<p className="snippetfork">
					<GitFork size={14} /> Forked from{" "}
					<a href={snippetPath(snippet.forked_from)}>{snippet.forked_from}</a>
				</p>
			)}
			<Alert>{action.error}</Alert>
			{snippet.files?.map((file) => (
				<SnippetFileView
					key={file.id}
					slug={slug}
					file={file}
					version={snippet.revision?.version}
				/>
			))}
			<section className="snippethistory">
				<h2>
					<History size={17} /> Revision history
				</h2>
				<div className="panel">
					{snippet.revisions?.map((revision) => (
						<a
							className={
								revision.version === snippet.revision?.version ? "selected" : ""
							}
							href={snippetPath(slug, revision.version)}
							key={revision.id}
						>
							<strong>Revision {revision.version}</strong>
							<span>
								{revision.message ||
									(revision.version === 1 ? "Created snippet" : "Updated snippet")}
							</span>
							<small>{dateTime(revision.inserted_at)}</small>
						</a>
					))}
				</div>
			</section>
		</section>
	);
}

function SnippetFileView({
	slug,
	file,
	version,
}: {
	slug: string;
	file: SnippetFile;
	version?: number;
}) {
	const raw =
		"/api/snippets/" +
		slug +
		"/raw/" +
		file.name +
		(version ? "?version=" + version : "");
	return (
		<article className="panel snippetfile">
			<div className="panelheading">
				<div>
					<strong>{file.name}</strong>
					<span>{syntaxLanguage(file.name)}</span>
				</div>
				<div className="row">
					<button
						className="small"
						onClick={() => void navigator.clipboard.writeText(file.content)}
					>
						<Copy size={13} /> Copy
					</button>
					<a className="button small" href={raw}>
						Raw
					</a>
				</div>
			</div>
			<SyntaxBlock content={file.content} path={file.name} />
		</article>
	);
}

