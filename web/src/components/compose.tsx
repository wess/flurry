import { useEffect, useRef, useState } from "react";
import { Plus, Trash2, X } from "lucide-react";
import { send, useAction } from "../api";
import { go, short } from "../navigation";
import { Alert } from "./common";
import type { Repository } from "../types";

type Edit = { path: string; content: string; deleted: boolean };

export function Compose({
	repo,
	initial,
	close,
}: {
	repo: Repository;
	initial?: { path: string; content: string };
	close: () => void;
}) {
	const dialog = useRef<HTMLDialogElement>(null);
	const [files, setFiles] = useState<Edit[]>([
		{
			path: initial?.path || "",
			content: initial?.content || "",
			deleted: false,
		},
	]);
	const [message, setMessage] = useState("");
	const action = useAction();
	useEffect(() => {
		dialog.current?.showModal();
	}, []);
	const update = (i: number, values: Partial<Edit>) =>
		setFiles(
			files.map((file, index) => (index === i ? { ...file, ...values } : file)),
		);
	return (
		<dialog
			ref={dialog}
			className="composedialog"
			onCancel={(event) => {
				if (action.busy) event.preventDefault();
				else close();
			}}
		>
			<div className="dialogheading">
				<h2>New change</h2>
				<button
					disabled={action.busy}
					className="iconbutton"
					aria-label="Close"
					onClick={close}
				>
					<X size={18} />
				</button>
			</div>
			<p className="muted">
				Based on <code>{short(repo.head)}</code>. Files stay off main until this
				change is approved and landed.
			</p>
			<form
				className="form"
				onSubmit={(event) => {
					event.preventDefault();
					void action.run(async () => {
						const result = await send<{ review_id: string }>(
							`/repositories/${repo.id}/changesets`,
							{
								base: repo.head,
								message,
								files: files.map((file) => ({
									path: file.path,
									content: file.deleted ? null : file.content,
								})),
							},
						);
						close();
						go(`/repositories/${repo.id}/reviews/${result.review_id}`);
					});
				}}
			>
				<label>
					Change message
					<input
						autoFocus
						required
						maxLength={2000}
						value={message}
						onChange={(e) => setMessage(e.target.value)}
						placeholder="Describe what changed"
					/>
				</label>
				{files.map((file, i) => (
					<div className="editor" key={i}>
						<div className="row">
							<label className="grow">
								File path
								<input
									required
									aria-label={`File path ${i + 1}`}
									value={file.path}
									onChange={(e) => update(i, { path: e.target.value })}
									placeholder="readme.md"
								/>
							</label>
							{files.length > 1 && (
								<button
									type="button"
									aria-label={`Remove file ${i + 1}`}
									className="iconbutton"
									onClick={() =>
										setFiles(files.filter((_, index) => index !== i))
									}
								>
									<Trash2 size={16} />
								</button>
							)}
						</div>
						<label className="check">
							<input
								type="checkbox"
								checked={file.deleted}
								onChange={(e) => update(i, { deleted: e.target.checked })}
							/>
							Delete this file
						</label>
						{!file.deleted && (
							<label>
								Contents
								<textarea
									className="codeinput"
									aria-label={`File contents ${i + 1}`}
									rows={10}
									spellCheck={false}
									value={file.content}
									onChange={(e) => update(i, { content: e.target.value })}
								/>
							</label>
						)}
					</div>
				))}
				<button
					type="button"
					className="small addfile"
					disabled={files.length >= 100}
					onClick={() =>
						setFiles([...files, { path: "", content: "", deleted: false }])
					}
				>
					<Plus size={14} />
					Add file
				</button>
				<Alert>{action.error}</Alert>
				<div className="dialogfooter">
					<button type="button" disabled={action.busy} onClick={close}>
						Cancel
					</button>
					<button className="primary" disabled={action.busy}>
						{action.busy ? "Submitting…" : "Submit for review"}
					</button>
				</div>
			</form>
		</dialog>
	);
}
