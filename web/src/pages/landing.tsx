import {
	ArrowRight,
	Database,
	GitCompareArrows,
	Layers3,
	ShieldCheck,
	Snowflake,
} from "lucide-react";
import type { Site } from "../types";

export function Landing({ site }: { site?: Site }) {
	const name = site?.name || "Flurry";

	return (
		<div className="landing">
			<section className="landinghero">
				<div className="landingherocopy">
					<Snowflake className="landingsymbol" size={42} strokeWidth={1.45} />
					<h1>Source control with Git at the edge, not the center.</h1>
					<p>
						{name} is a native version-control engine built around immutable
						changesets, content-addressed files, and server-side review. Use its
						own client or keep using Git—the engine stays the same.
					</p>
					<div className="landingactions">
						{site?.registration !== false ? (
							<a className="button primary" href="/signup">
								Create account
							</a>
						) : (
							<a className="button primary" href="/login">
								Sign in
							</a>
						)}
						<a className="button" href="/explore">
							Explore repositories
						</a>
					</div>
					<small className="muted">Self-hosted. Public and private repositories. Apache 2.0.</small>
				</div>

				<div className="landingengine" aria-label="Flurry engine architecture">
					<div className="engineheading">
						<span>native engine</span>
						<strong>One change, carried through</strong>
					</div>
					<div className="engineflow">
						<div>
							<span>working copy</span>
							<strong>changed files</strong>
						</div>
						<ArrowRight aria-hidden="true" size={17} />
						<div>
							<span>immutable record</span>
							<strong>changeset</strong>
						</div>
						<ArrowRight aria-hidden="true" size={17} />
						<div>
							<span>shared state</span>
							<strong>review + main</strong>
						</div>
					</div>
					<div className="enginestores">
						<span>SHA-256 file objects</span>
						<span>persistent trees</span>
						<span>derived Git view</span>
					</div>
				</div>
			</section>

			<section className="landingarchitecture">
				<div className="landingsectioncopy">
					<h2>A source-control engine, not a Git wrapper</h2>
					<p>
						Git import and export live at the boundary. Inside, {name} stores
						the facts it needs directly: which paths changed, who authored the
						change, what was reviewed, and which revision main points to.
					</p>
				</div>
				<div className="architecturelayers">
					<article>
						<Database size={21} aria-hidden="true" />
						<div>
							<h3>Authoritative changesets</h3>
							<p>
								Each changeset records changed paths and parent links. Records
								are immutable; main moves only after review and policy checks
								pass.
							</p>
						</div>
					</article>
					<article>
						<Layers3 size={21} aria-hidden="true" />
						<div>
							<h3>Content once, views as needed</h3>
							<p>
								Compressed file objects are addressed by SHA-256. Directory
								trees and Git objects are derived from native history and can be
								rebuilt.
							</p>
						</div>
					</article>
					<article>
						<GitCompareArrows size={21} aria-hidden="true" />
						<div>
							<h3>Git without architectural lock-in</h3>
							<p>
								Imported commits keep their Git identities. Native history
								exports to stable Git objects, so existing tools remain useful.
							</p>
						</div>
					</article>
				</div>
			</section>

			<section className="landingcomparison">
				<div className="landingsectioncopy">
					<h2>From first commit to shared history</h2>
					<p>
						{name} keeps the working model small: record what changed, review it
						in context, then move shared state forward without rewriting the
						record.
					</p>
				</div>
				<div className="comparisontable" tabIndex={0}>
					<table>
						<thead>
							<tr>
								<th scope="col">Stage</th>
								<th scope="col">How {name} handles it</th>
							</tr>
						</thead>
						<tbody>
							<tr>
								<th scope="row">Create</th>
								<td data-label={name}>
									Start empty, initialize common project files, or import
									existing code.
								</td>
							</tr>
							<tr>
								<th scope="row">Change</th>
								<td data-label={name}>
									Keep offline native commits while shared refs remain
									server-authoritative.
								</td>
							</tr>
							<tr>
								<th scope="row">Review</th>
								<td data-label={name}>
									Anchor comments, approvals, policy, and status checks to
									immutable revisions.
								</td>
							</tr>
							<tr>
								<th scope="row">Share</th>
								<td data-label={name}>
									Land reviewed work, publish releases, and exchange history
									through Git-compatible transport.
								</td>
							</tr>
						</tbody>
					</table>
				</div>
			</section>

			<section className="landingownership">
				<ShieldCheck size={24} aria-hidden="true" />
				<div>
					<h2>Own the service and the history</h2>
					<p>
						Run the instance on your terms. Manage access, repository policies,
						organizations, storage limits, and service health from one small administration
						surface.
					</p>
				</div>
			</section>
		</div>
	);
}
