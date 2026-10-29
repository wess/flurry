import { useState } from "react";
import { Plus, Trash2, X } from "lucide-react";
import { request, send, useAction } from "../../api";
import { Alert, Empty } from "../../components/common";
import { go, snippetPath } from "../../navigation";
import type { Snippet, User } from "../../types";

export function SnippetEditor({ user, snippet }: { user: User | null; snippet?: Snippet }) {
	const action = useAction();
	const [title, setTitle] = useState(snippet?.title || "");
	const [description, setDescription] = useState(snippet?.description || "");
	const [visibility, setVisibility] = useState<Snippet["visibility"]>(
		snippet?.visibility || "unlisted",
	);
	const [message, setMessage] = useState("");
	const [files, setFiles] = useState(
		snippet?.files?.map(({ name, content }) => ({ name, content })) || [
			{ name: "snippet.ts", content: "" },
		],
	);
	if (!user)
		return (
			<Empty title="Sign in to create snippets">
				<a href="/login">Sign in</a> to continue.
			</Empty>
		);

	const updateFile = (
		index: number,
		values: Partial<{ name: string; content: string }>,
	) =>
		setFiles((current) =>
			current.map((file, i) => (i === index ? { ...file, ...values } : file)),
		);

	return (
		<section className="snippets">
			<a className="backlink" href={snippet ? snippetPath(snippet.slug) : snippetPath()}>
				Cancel
			</a>
			<h1>{snippet ? "Edit snippet" : "New snippet"}</h1>
			<form
				className="snippeteditor"
				onSubmit={(event) => {
					event.preventDefault();
					void action.run(async () => {
						const body = {
							title,
							description,
							visibility,
							message,
							files,
							...(snippet ? { version: snippet.version } : {}),
						};
						const next = snippet
							? await send<Snippet>("/snippets/" + snippet.slug, body, "PATCH")
							: await send<Snippet>("/snippets", body);
						go(snippetPath(next.slug));
					});
				}}
			>
				<div className="panel form snippetmeta">
					<label>
						Title
						<input required maxLength={200} value={title} onChange={(event) => setTitle(event.target.value)} />
					</label>
					<label>
						Description <span className="muted">(optional)</span>
						<textarea rows={2} maxLength={2000} value={description} onChange={(event) => setDescription(event.target.value)} />
					</label>
					<label>
						Visibility
						<select value={visibility} onChange={(event) => setVisibility(event.target.value as Snippet["visibility"])}>
							<option value="public">Public · appears in discovery</option>
							<option value="unlisted">Unlisted · anyone with the link</option>
							<option value="private">Private · only you</option>
						</select>
					</label>
					{snippet && (
						<label>
							Revision note <span className="muted">(optional)</span>
							<input maxLength={500} value={message} onChange={(event) => setMessage(event.target.value)} />
						</label>
					)}
				</div>
				<div className="snippeteditfiles">
					{files.map((file, index) => (
						<div className="panel snippeteditfile" key={index}>
							<div className="panelheading">
								<input aria-label={"File " + (index + 1) + " name"} required maxLength={1024} value={file.name} onChange={(event) => updateFile(index, { name: event.target.value })} />
								{files.length > 1 && (
									<button type="button" className="iconbutton" aria-label={"Remove " + file.name} onClick={() => setFiles((current) => current.filter((_, i) => i !== index))}>
										<X size={15} />
									</button>
								)}
							</div>
							<textarea aria-label={file.name + " content"} required spellCheck={false} value={file.content} onChange={(event) => updateFile(index, { content: event.target.value })} />
						</div>
					))}
					{files.length < 20 && (
						<button type="button" className="small" onClick={() => setFiles((current) => [...current, { name: "snippet" + (current.length + 1) + ".txt", content: "" }])}>
							<Plus size={14} /> Add file
						</button>
					)}
				</div>
				<Alert>{action.error}</Alert>
				<div className="snippetsubmit">
					<button className="primary" disabled={action.busy}>
						{action.busy ? "Saving…" : snippet ? "Save revision" : "Create snippet"}
					</button>
				</div>
			</form>
			{snippet && (
				<details className="danger">
					<summary><Trash2 size={14} /> Delete snippet</summary>
					<p>Delete this snippet and every revision. This cannot be undone.</p>
					<button className="small" onClick={() => void action.run(async () => {
						await request("/snippets/" + snippet.slug, { method: "DELETE" });
						go(snippetPath());
					})}>
						Delete permanently
					</button>
				</details>
			)}
		</section>
	);
}
