import {
	Bot,
	Check,
	CircleDot,
	ExternalLink,
	GitMerge,
	MessageSquare,
	RefreshCw,
	ShieldCheck,
	TriangleAlert,
} from "lucide-react";
import { useState } from "react";
import { send, useAction, useResource } from "../api";
import { Alert, Empty } from "../components/common";
import { SyntaxLine } from "../components/syntax";
import { date, short } from "../navigation";
import type { Repository, Review, ReviewDetail, ReviewFinding, User } from "../types";

export function ReviewsPage({ repo }: { repo: Repository }) {
	const resource = useResource<{ reviews: Review[] }>(
		`/repositories/${repo.id}/reviews`,
	);
	return (
		<>
			<div className="sectionheading">
				<h2>Changes for review</h2>
				<button className="small" onClick={resource.reload}>
					<RefreshCw size={13} />
					Refresh
				</button>
			</div>
			<Alert>{resource.error}</Alert>
			{resource.loading ? (
				<p className="muted">Loading reviews…</p>
			) : resource.value?.reviews.length ? (
				<div className="panel">
					{resource.value.reviews.map((review) => (
						<a
							className="reviewrow"
							key={review.id}
							href={`/repositories/${repo.id}/reviews/${review.id}`}
						>
							<MessageSquare size={18} />
							<div className="grow">
								<strong>{review.changeset.message}</strong>
								<small>
									{review.changeset.author.name} • {date(review.inserted_at)} •{" "}
									{review.changeset.files} file
									{review.changeset.files === 1 ? "" : "s"}
								</small>
							</div>
							<span className={`status ${review.status}`}>{review.status}</span>
						</a>
					))}
				</div>
			) : (
				<Empty title="No changes to review">
					New changes appear here before they land on main.
				</Empty>
			)}
		</>
	);
}

export function ReviewPage({
	repo,
	id,
	own,
	user,
	changed,
}: {
	repo: Repository;
	id: string;
	own: boolean;
	user: User | null;
	changed: () => void;
}) {
	const base = `/repositories/${repo.id}/reviews/${id}`;
	const resource = useResource<ReviewDetail>(base);
	const action = useAction();
	const [findingFilter, setFindingFilter] = useState<"open" | "all">("open");
	const review = resource.value;
	if (!review) return <Alert>{resource.error || "Loading review…"}</Alert>;
	const act = (name: string) =>
		void action.run(async () => {
			await send(`${base}/${name}`);
			resource.reload();
			changed();
		});
	const intelligence = review.review_intelligence;
	const findings = intelligence.findings.filter(
		(finding) => findingFilter === "all" || finding.state === "open",
	);
	const canWrite = ["owner", "write", "maintain"].includes(repo.role || "");
	const findingAction = (finding: ReviewFinding, name: string) =>
		void action.run(async () => {
			await send(`${base}/findings/${finding.id}/${name}`);
			resource.reload();
		});
	return (
		<>
			<a className="backlink" href={`/repositories/${repo.id}/reviews`}>
				All reviews
			</a>
			<div className="reviewheading">
				<div>
					<h1>{review.changeset.message}</h1>
					<p className="muted">
						{review.changeset.author.name} • {date(review.inserted_at)} •{" "}
						<code>{short(review.changeset.id)}</code>
					</p>
				</div>
				<span className={`status ${review.status}`}>{review.status}</span>
			</div>
			<Alert>{action.error}</Alert>
			{own && review.status !== "landed" && (
				<div className="reviewactions">
					<p>
						{review.status === "approved"
							? "Approved. Ready to land on main."
							: "Review the files below, then approve this change."}
					</p>
					<button
						className="primary"
						disabled={action.busy}
						onClick={() => act(review.status === "open" ? "approve" : "land")}
					>
						{review.status === "open" ? (
							<>
								<Check size={15} />
								Approve change
							</>
						) : (
							<>
								<GitMerge size={15} />
								Land change
							</>
						)}
					</button>
				</div>
			)}
			{review.status === "landed" && (
				<p className="landedmessage">
					<Check size={15} />
					Landed on main as{" "}
					<a href={`/repositories/${repo.id}?revision=${review.landed_id}`}>
						<code>{short(review.landed_id)}</code>
					</a>
				</p>
			)}
			{(review.automation || review.evaluations.length > 0) && (
				<section
					className="reviewevidence panel"
					aria-labelledby="review-evidence-title"
				>
					<div className="panelheading">
						<strong id="review-evidence-title">
							Automation and evaluations
						</strong>
						<span>
							{review.evaluations.length} attempt
							{review.evaluations.length === 1 ? "" : "s"}
						</span>
					</div>
					{review.automation && (
						<div className="provenancerow">
							<Bot size={17} aria-hidden="true" />
							<div className="grow">
								<strong>
									{review.automation.name}
									{review.automation.version
										? ` ${review.automation.version}`
										: ""}
								</strong>
								<small>
									Submitted by {review.automation.actor.name} through{" "}
									{review.automation.trigger}
								</small>
							</div>
							{review.automation.external_id && (
								<code>{review.automation.external_id}</code>
							)}
						</div>
					)}
					{review.evaluations.map((evaluation) => (
						<div className="evaluationrow" key={evaluation.id}>
							<span
								className={`evaluationmark ${evaluation.state}`}
								aria-hidden="true"
							/>
							<div className="grow">
								<strong>{evaluation.context}</strong>
								<small>
									{evaluation.summary ||
										`${evaluation.pass} passed, ${evaluation.fail} failed`}
								</small>
							</div>
							<span className="evaluationfacts">
								{evaluation.score !== null && (
									<span>Score {evaluation.score}</span>
								)}
								<span>
									{evaluation.pass} passed · {evaluation.fail} failed
								</span>
							</span>
							{evaluation.target_url && (
								<a
									href={evaluation.target_url}
									target="_blank"
									rel="noreferrer"
									aria-label={`Open ${evaluation.context} result`}
								>
									<ExternalLink size={14} />
								</a>
							)}
						</div>
					))}
				</section>
			)}
			<section className="reviewintelligence" aria-labelledby="review-intelligence-title">
				<div className="reviewintelheading">
					<div>
						<h2 id="review-intelligence-title">Automated review</h2>
						<p>Structured findings stay tied to a revision and require independent verification.</p>
					</div>
					{canWrite && review.status !== "landed" && (
						<button disabled={action.busy} onClick={() => void action.run(async () => {
							await send(`${base}/runs`);
							resource.reload();
						})}>
							<ShieldCheck size={15} />
							Request review
						</button>
					)}
				</div>
				<div className="reviewintelbar">
					<span><strong>{intelligence.findings.filter((finding) => finding.current && finding.state === "open").length}</strong> open</span>
					<span><strong>{intelligence.findings.filter((finding) => finding.verified).length}</strong> verified</span>
					<span><strong>{intelligence.runs.length}</strong> runs</span>
					<div className="grow" />
					<button className={findingFilter === "open" ? "selected small" : "small"} onClick={() => setFindingFilter("open")}>Open</button>
					<button className={findingFilter === "all" ? "selected small" : "small"} onClick={() => setFindingFilter("all")}>History</button>
				</div>
				{intelligence.runs[0] && (
					<div className="reviewrun">
						<CircleDot size={14} aria-hidden="true" />
						<span className={`status ${intelligence.runs[0].state}`}>{intelligence.runs[0].state}</span>
						<span>{intelligence.runs[0].profiles.join(" · ")}</span>
						<span className="muted">{date(intelligence.runs[0].inserted_at)}</span>
						{intelligence.runs[0].summary && <span className="runsummary">{intelligence.runs[0].summary}</span>}
					</div>
				)}
				<div className="findinglist">
					{findings.length ? findings.map((finding) => (
						<FindingRow key={finding.id} finding={finding} user={user} maintain={own} canWrite={canWrite} busy={action.busy} act={findingAction} />
					)) : (
						<p className="reviewempty">{findingFilter === "open" ? "No open findings on this review." : "No findings have been published."}</p>
					)}
				</div>
			</section>
			{review.diff.map((file) => (
				<div className="panel diff" key={file.path}>
					<div className="panelheading">
						<strong>{file.path}</strong>
						<span className={`status ${file.kind}`}>{file.kind}</span>
					</div>
					{intelligence.findings.some((finding) => finding.current && finding.path === file.path && finding.state === "open") && (
						<div className="filefindings">
							{intelligence.findings.filter((finding) => finding.current && finding.path === file.path && finding.state === "open").map((finding) => (
								<a key={finding.id} href={`#finding-${finding.id}`}>
									<TriangleAlert size={13} />
									<strong>{finding.severity}</strong>
									<span>Line {finding.line}: {finding.title}</span>
									{finding.verified && <ShieldCheck size={13} aria-label="Verified" />}
								</a>
							))}
						</div>
					)}
					{file.symbols && (
						<div
							className="symbolsummary"
							aria-label={`${file.symbols.language} symbols changed`}
						>
							<span>{file.symbols.language}</span>
							{file.symbols.changed.map((symbol) => (
								<span
									className={`symbolchip ${symbol.change}`}
									key={`${symbol.name}:${symbol.line}`}
									aria-label={`${symbol.name}, ${symbol.kind}, ${symbol.change}`}
								>
									<span className="symbolmark" aria-hidden="true">
										{symbol.change === "added"
											? "+"
											: symbol.change === "deleted"
												? "−"
												: "~"}
									</span>
									{symbol.name}
								</span>
							))}
						</div>
					)}
					{file.lines ? (
						<div className="diffcode">
							{file.lines.map((line, index) => (
								<div className={`diffline ${line.kind}`} key={index}>
									<span aria-hidden="true">
										{line.kind === "ins"
											? "+"
											: line.kind === "del"
												? "−"
												: " "}
									</span>
									<SyntaxLine content={line.text} path={file.path} />
								</div>
							))}
						</div>
					) : (
						<p className="diffnotice">
							Preview unavailable for binary or large files.{" "}
							<a
								href={`/repositories/${repo.id}?${new URLSearchParams({ file: file.path, revision: file.after ? review.changeset.id : review.changeset.parent || "main" })}`}
							>
								View file
							</a>
						</p>
					)}
				</div>
			))}
			<div className="discussion">
				<h2>Discussion</h2>
				{review.comments.map((comment) => (
					<article className="comment panel" key={comment.id}>
						<div className="panelheading">
							<strong>{comment.author}</strong>
							<small>{date(comment.inserted_at)}</small>
						</div>
						<p>{comment.body}</p>
					</article>
				))}
				{user && !repo.archived ? (
					<form
						className="form"
						onSubmit={(event) => {
							event.preventDefault();
							const form = event.currentTarget;
							const body = new FormData(form).get("body");
							void action.run(async () => {
								await send(`${base}/comments`, { body });
								form.reset();
								resource.reload();
							});
						}}
					>
						<label>
							Add a comment
							<textarea
								name="body"
								required
								rows={3}
								maxLength={10000}
								placeholder="Leave a note about this change"
							/>
						</label>
						<div>
							<button disabled={action.busy}>Comment</button>
						</div>
					</form>
				) : (
					<p>
						<a href="/login">Sign in</a> to join the discussion.
					</p>
				)}
			</div>
		</>
	);
}

function FindingRow({
	finding,
	user,
	maintain,
	canWrite,
	busy,
	act,
}: {
	finding: ReviewFinding;
	user: User | null;
	maintain: boolean;
	canWrite: boolean;
	busy: boolean;
	act: (finding: ReviewFinding, name: string) => void;
}) {
	const canVerify = canWrite && user && user.id !== finding.reporter.id && !finding.verified;
	const canDispose = maintain && user?.account_type !== "agent" && finding.current;
	return (
		<article className={`findingrow ${finding.state}`} id={`finding-${finding.id}`}>
			<div className="findingmeta">
				<span className={`findingseverity ${finding.severity}`}>{finding.severity}</span>
				<span>{finding.category.replace("_", " ")}</span>
				{finding.classification === "preexisting" && <span>pre-existing</span>}
				{!finding.current && <span>older revision</span>}
				{finding.state !== "open" && <span>{finding.state.replace("_", " ")}</span>}
				{finding.verified ? (
					<span className="verified"><ShieldCheck size={13} />verified</span>
				) : (
					<span>unverified</span>
				)}
			</div>
			<h3>{finding.title}</h3>
			<p>{finding.body}</p>
			{finding.evidence && (
				<details>
					<summary>Verification evidence</summary>
					<p>{finding.evidence}</p>
				</details>
			)}
			<div className="findingfooter">
				<span>Reported by {finding.reporter.name}</span>
				{finding.path && <code>{finding.path}:{finding.line}</code>}
				<span className="grow" />
				{canVerify && <button className="small" disabled={busy} onClick={() => act(finding, "verified")}>Verify</button>}
				{canDispose && finding.state === "open" && (
					<>
						<button className="small" disabled={busy} onClick={() => act(finding, "dismissed")}>Dismiss</button>
						<button className="small primary" disabled={busy} onClick={() => act(finding, "resolved")}>Resolve</button>
					</>
				)}
				{canDispose && ["resolved", "dismissed"].includes(finding.state) && (
					<button className="small" disabled={busy} onClick={() => act(finding, "reopened")}>Reopen</button>
				)}
			</div>
		</article>
	);
}
