import { useEffect, useRef, useState } from "react";
import {
	ArrowDownToLine,
	ArrowUpFromLine,
	ExternalLink,
	Link2,
	X,
} from "lucide-react";
import { request, send, useAction } from "../api";
import { Alert } from "./common";
import { short } from "../navigation";
import type { Repository, Source } from "../types";

export function SourceLink({
	repo,
	own,
	changed,
}: {
	repo: Repository;
	own: boolean;
	changed: () => void;
}) {
	const [source, setSource] = useState<Source | null>(null);
	const [error, setError] = useState("");
	const [operation, setOperation] = useState<"import" | "pull" | "push" | null>(
		null,
	);
	const completed = useRef(changed);
	completed.current = changed;
	useEffect(() => {
		const controller = new AbortController();
		let timeout: ReturnType<typeof setTimeout>;
		let running = false;
		async function load() {
			try {
				const data = await request<{ source: Source | null }>(
					`/repositories/${repo.id}/source`,
					{ signal: controller.signal },
				);
				if (controller.signal.aborted) return;
				setSource(data.source);
				if (
					(running && data.source?.status !== "running") ||
					(!repo.head && data.source?.status === "ready" && data.source.commit)
				)
					completed.current();
				running = data.source?.status === "running";
				if (running) timeout = setTimeout(load, 1500);
			} catch (error) {
				if (!controller.signal.aborted)
					setError(
						error instanceof Error
							? error.message
							: "Could not load linked source",
					);
			}
		}
		void load();
		return () => {
			controller.abort();
			clearTimeout(timeout);
		};
	}, [repo.id, repo.head, operation]);
	if (!source) return <Alert>{error}</Alert>;
	return (
		<>
			<div className="sourcepanel">
				<div className="sourcetitle">
					<Link2 size={15} />
					<strong>Linked source</strong>
					<a
						href={source.url.replace(/\.git$/, "")}
						target="_blank"
						rel="noopener noreferrer"
					>
						{new URL(source.url).host}
						<ExternalLink size={12} />
					</a>
					<span className="muted">
						{source.branch || "Default branch"}
						{source.commit && (
							<>
								{" "}
								· <code>{short(source.commit)}</code>
							</>
						)}
					</span>
				</div>
				{source.status === "running" ? (
					<p className="muted" role="status">
						{source.operation === "import"
							? "Importing files…"
							: source.operation === "push"
								? "Pushing landed changes…"
								: "Checking for upstream updates…"}
					</p>
				) : (
					<>
						{source.message && (
							<p className="muted" role="status">
								{source.message}
							</p>
						)}
						<Alert>{source.error || error}</Alert>
						{source.review_id ? (
							<a
								className="button small"
								href={`/repositories/${repo.id}/reviews/${source.review_id}`}
							>
								Review upstream updates
							</a>
						) : (
							own &&
							!repo.archived && (
								<div className="row">
									{source.commit ? (
										<>
											<button
												className="small"
												onClick={() => setOperation("pull")}
											>
												<ArrowDownToLine size={13} />
												Pull updates
											</button>
											<button
												className="small"
												onClick={() => setOperation("push")}
												disabled={!repo.head}
											>
												<ArrowUpFromLine size={13} />
												Push to source
											</button>
										</>
									) : (
										<button
											className="small"
											onClick={() => setOperation("import")}
										>
											Retry import
										</button>
									)}
								</div>
							)
						)}
					</>
				)}
			</div>
			{operation && (
				<Transfer
					repo={repo}
					source={source}
					operation={operation}
					close={() => setOperation(null)}
					started={(next) => {
						setSource(next);
						setOperation(null);
					}}
				/>
			)}
		</>
	);
}

function Transfer({
	repo,
	source,
	operation,
	close,
	started,
}: {
	repo: Repository;
	source: Source;
	operation: "import" | "pull" | "push";
	close: () => void;
	started: (source: Source) => void;
}) {
	const dialog = useRef<HTMLDialogElement>(null);
	const action = useAction();
	useEffect(() => {
		dialog.current?.showModal();
	}, []);
	const label =
		operation === "push"
			? "Push to source"
			: operation === "pull"
				? "Pull updates"
				: "Retry import";
	return (
		<dialog
			ref={dialog}
			className="composedialog transferdialog"
			onCancel={(event) => {
				if (action.busy) event.preventDefault();
				else close();
			}}
		>
			<div className="dialogheading">
				<h2>{label}</h2>
				<button
					className="iconbutton"
					onClick={close}
					disabled={action.busy}
					aria-label="Close"
				>
					<X size={18} />
				</button>
			</div>
			<p className="sourceurl">{source.url}</p>
			<p>
				{operation === "push" ? (
					<>
						Update <strong>{source.branch}</strong> with landed Flurry revision{" "}
						<code>{short(repo.head)}</code>. This creates a Git commit and
						preserves upstream history. Unlanded reviews are excluded.
					</>
				) : operation === "pull" ? (
					"Upstream file changes will become a Flurry review. Your main branch stays unchanged until you land it."
				) : (
					"Import the branch’s current files into this empty repository."
				)}
			</p>
			<form
				className="form"
				onSubmit={(event) => {
					event.preventDefault();
					const form = event.currentTarget;
					const values = Object.fromEntries(new FormData(form));
					void action.run(async () => {
						const result = await send<{ source: Source }>(
							`/repositories/${repo.id}/source/${operation}`,
							{ ...values, head: repo.head },
						);
						form.reset();
						started(result.source);
					});
				}}
			>
				<label>
					Git username <span className="muted">(optional)</span>
					<input
						name="username"
						placeholder="git"
						autoComplete="off"
						maxLength={200}
					/>
				</label>
				<label>
					Access token{" "}
					<span className="muted">
						(
						{operation === "push"
							? "write access required"
							: "optional for public repositories"}
						)
					</span>
					<input
						name="token"
						type="password"
						autoComplete="off"
						maxLength={4096}
					/>
					<small>
						Used for this transfer only. Your Git host’s branch protection rules
						still apply.
					</small>
				</label>
				<Alert>{action.error}</Alert>
				<div className="dialogfooter">
					<button type="button" onClick={close} disabled={action.busy}>
						Cancel
					</button>
					<button className="primary" disabled={action.busy}>
						{action.busy ? "Starting…" : label}
					</button>
				</div>
			</form>
		</dialog>
	);
}
