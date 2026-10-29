import type { ReactNode } from "react";
import { FolderGit2, LockKeyhole, Globe2 } from "lucide-react";
import { date } from "../navigation";
import type { Repository } from "../types";

export function Alert({ children }: { children: ReactNode }) {
	return children ? (
		<p className="alert" role="alert">
			{children}
		</p>
	) : null;
}
export function Empty({
	title,
	children,
}: {
	title: string;
	children: ReactNode;
}) {
	return (
		<div className="empty">
			<h3>{title}</h3>
			<p>{children}</p>
		</div>
	);
}
export function Avatar({
	name,
	large = false,
}: {
	name: string;
	large?: boolean;
}) {
	return (
		<span className={`avatar ${large ? "large" : ""}`} aria-hidden="true">
			{name
				.split(" ")
				.map((s) => s[0])
				.slice(0, 2)
				.join("")
				.toUpperCase()}
		</span>
	);
}
export function Visibility({ value }: { value: string }) {
	return (
		<span className="badge">
			{value === "private" ? <LockKeyhole size={11} /> : <Globe2 size={11} />}
			{value}
		</span>
	);
}
export function Repositories({ repositories }: { repositories: Repository[] }) {
	if (!repositories.length)
		return (
			<Empty title="No repositories yet">
				Repositories will appear here when they’re created.
			</Empty>
		);
	return (
		<div className="repolist">
			{repositories.map((repo) => (
				<article className="reporow" key={repo.id}>
					<FolderGit2 size={20} className="muted" />
					<div className="grow">
						<div className="row">
							<a className="reponame" href={`/repositories/${repo.id}`}>
								{repo.owner.username} / <strong>{repo.name}</strong>
							</a>
							<Visibility value={repo.visibility} />
						</div>
						{repo.description && <p>{repo.description}</p>}
						<small className="muted">Created {date(repo.inserted_at)}</small>
					</div>
				</article>
			))}
		</div>
	);
}
