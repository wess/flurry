import { useState } from "react";
import { send, useResource, useAction } from "../../api";
import { Alert } from "../../components/common";
import {
	ConfirmIdentity,
	SettingsForm,
	Events,
} from "../../components/settings";
import { go } from "../../navigation";
import type { Repository, User, Source, AuditEvent } from "../../types";

export function RepositorySettings({
	repo,
	user,
	changed,
}: {
	repo: Repository;
	user: User | null;
	changed: () => void;
}) {
	const [tab, setTab] = useState("general");
	const action = useAction();
	if (!user || repo.owner.id !== user.id)
		return <Alert>Repository owner access required.</Alert>;
	const base = `/repositories/${repo.id}`;
	return (
		<>
			<div className="settingssubnav">
				{[
					["general", "General"],
					["members", "Collaborators"],
					["reviews", "Automated review"],
					["source", "Linked source"],
					["audit", "Activity"],
				].map(([value, label]) => (
					<button
						key={value}
						className={value === tab ? "selected" : ""}
						onClick={() => setTab(value!)}
					>
						{label}
					</button>
				))}
			</div>
			<div className="repositorysettings" key={tab}>
				{tab === "members" ? (
					<Members repo={repo} />
				) : tab === "reviews" ? (
					<ReviewAutomation repo={repo} changed={changed} />
				) : tab === "source" ? (
					<Linked repo={repo} user={user} changed={changed} />
				) : tab === "audit" ? (
					<RepositoryAudit repo={repo} />
				) : (
					<>
						<h2>General settings</h2>
						<SettingsForm
							onSave={async (values) => {
								await send(base, values, "PATCH");
								changed();
							}}
						>
							<label>
								Repository name
								<input
									name="name"
									required
									maxLength={80}
									pattern="[a-z0-9][a-z0-9.]*"
									defaultValue={repo.name}
								/>
							</label>
							<label>
								Description
								<input
									name="description"
									maxLength={500}
									defaultValue={repo.description}
								/>
							</label>
							<label>
								Visibility
								<select name="visibility" defaultValue={repo.visibility}>
									<option value="private">Private</option>
									<option value="public">Public</option>
								</select>
								<small>
									Making a repository public publishes all its files, history,
									and reviews.
								</small>
							</label>
							<label className="check">
								<input
									name="allow_self_approval"
									type="checkbox"
									defaultChecked={repo.allow_self_approval}
								/>
								Allow authors to approve their own changes
							</label>
							<p className="muted">
								When disabled, another maintainer must approve each change. Main
								always requires an approved review; there is no direct-write
								bypass.
							</p>
							<ConfirmIdentity
								user={user}
								required={false}
								label="Current password (required for visibility changes)"
							/>
						</SettingsForm>
						<div className="settingsnote">
							<h3>
								{repo.archived ? "Reopen repository" : "Archive repository"}
							</h3>
							<p>
								{repo.archived
									? "Reopening allows code changes, reviews, and source transfers again."
									: "Archived repositories stay readable. Code changes, reviews, and source transfers are blocked."}
							</p>
							<Alert>{action.error}</Alert>
							<button
								disabled={action.busy}
								onClick={() =>
									void action.run(async () => {
										await send(`${base}/lifecycle`, {
											action: repo.archived ? "unarchive" : "archive",
										});
										changed();
									})
								}
							>
								{repo.archived ? "Reopen repository" : "Archive repository"}
							</button>
						</div>
						<details className="panel danger">
							<summary>Remove repository</summary>
							<p>
								Hide this repository from browsing and stop writes. History and
								objects are retained; you can restore it from account settings.
							</p>
							<SettingsForm
								label="Remove repository"
								notice=""
								onSave={async (values) => {
									await send(`${base}/lifecycle`, {
										...values,
										action: "remove",
									});
									go("/settings/removed");
								}}
							>
								<label>
									Type repository name to confirm
									<input
										name="confirm"
										required
										autoComplete="off"
										placeholder={repo.name}
									/>
								</label>
								<ConfirmIdentity user={user} />
							</SettingsForm>
						</details>
					</>
				)}
			</div>
		</>
	);
}

const reviewProfiles = [
	["correctness", "Correctness", "Logic errors and invalid state transitions"],
	["security", "Security", "Authorization, data exposure, and unsafe boundaries"],
	["regression", "Regression", "Previously supported behavior that may break"],
	["edge_case", "Edge cases", "Boundary inputs, failures, and concurrency"],
	["contract", "Contracts", "API, storage, and compatibility guarantees"],
] as const;

function ReviewAutomation({ repo, changed }: { repo: Repository; changed: () => void }) {
	return (
		<>
			<h2>Automated review</h2>
			<p className="muted">
				Flurry records and dispatches revision-bound review requests. External workers inspect code and publish structured findings; this server does not execute repository code.
			</p>
			<SettingsForm onSave={async (values) => {
				await send(`/repositories/${repo.id}`, {
					review_trigger: values.review_trigger,
					review_status_context: values.review_status_context,
					review_profiles: reviewProfiles.filter(([value]) => values[`profile_${value}`]).map(([value]) => value),
				}, "PATCH");
				changed();
			}}>
				<label>
					Request reviews
					<select name="review_trigger" defaultValue={repo.review_trigger || "manual"}>
						<option value="manual">Only when requested</option>
						<option value="review_opened">When a review opens</option>
						<option value="every_revision">When a review opens and after every revision</option>
					</select>
				</label>
				<fieldset className="settingsgroup reviewprofiles">
					<legend>Specialists</legend>
					{reviewProfiles.map(([value, label, detail]) => (
						<label className="check" key={value}>
							<input name={`profile_${value}`} type="checkbox" defaultChecked={(repo.review_profiles || ["correctness", "security"]).includes(value)} />
							<span><strong>{label}</strong><small>{detail}</small></span>
						</label>
					))}
				</fieldset>
				<label>
					Optional status context
					<input name="review_status_context" maxLength={100} defaultValue={repo.review_status_context || ""} placeholder="review/verified-findings" />
					<small>Completed runs publish success or failure. Add this context to required statuses only when it should block landing.</small>
				</label>
			</SettingsForm>
			<div className="settingsnote">
				<strong>Human decisions remain separate.</strong>
				<p>Automated findings never approve or land a change. A different account must verify a finding, and only a human maintainer can resolve or dismiss it.</p>
			</div>
		</>
	);
}

function Members({ repo }: { repo: Repository }) {
	const resource = useResource<{
		members: { username: string; name: string; role: string }[];
	}>(`/repositories/${repo.id}/members`);
	return (
		<>
			<h2>Collaborators</h2>
			<p className="muted">
				Read can browse private code. Write can submit changes. Maintain can
				approve and land. Only the owner manages settings and external source
				transfers.
			</p>
			<Alert>{resource.error}</Alert>
			<div className="panel">
				{resource.value?.members.length ? (
					resource.value.members.map((member) => (
						<div className="settingrow" key={member.username}>
							<strong>{member.username}</strong>
							<span className="muted">{member.role}</span>
						</div>
					))
				) : (
					<p className="padded muted">Only the owner has access.</p>
				)}
			</div>
			<h3 className="settingstitle">Add or update an existing user</h3>
			<SettingsForm
				label="Update collaborator"
				onSave={async (values, form) => {
					await send(`/repositories/${repo.id}/members`, values);
					form.reset();
					resource.reload();
				}}
			>
				<label>
					Username
					<input name="username" required maxLength={40} />
				</label>
				<label>
					Permission
					<select name="role">
						<option value="read">Read</option>
						<option value="write">Write</option>
						<option value="maintain">Maintain</option>
						<option value="remove">Remove access</option>
					</select>
				</label>
			</SettingsForm>
		</>
	);
}

function Linked({
	repo,
	user,
	changed,
}: {
	repo: Repository;
	user: User;
	changed: () => void;
}) {
	const resource = useResource<{ source: Source | null }>(
		`/repositories/${repo.id}/source`,
	);
	const source = resource.value?.source;
	return (
		<>
			<h2>Linked source</h2>
			<Alert>{resource.error}</Alert>
			{source ? (
				<>
					<p>
						<a href={source.url} target="_blank" rel="noopener noreferrer">
							{source.url}
						</a>
					</p>
					<p className="muted">
						Branch: {source.branch || "Default branch"}. Source credentials are
						entered for each transfer and are not stored. Pulls become reviews;
						pushes require explicit confirmation on the repository page.
					</p>
					<p>
						To switch repositories or branches, import the new source
						separately. This keeps the shared baseline and Git history intact.
					</p>
					<details className="panel danger">
						<summary>Unlink source</summary>
						<p>
							Keep all native Flurry files and history. This does not delete or
							change the upstream repository.
						</p>
						<SettingsForm
							label="Unlink source"
							onSave={async (values) => {
								await send(`/repositories/${repo.id}/source/unlink`, values);
								resource.reload();
								changed();
							}}
						>
							<ConfirmIdentity user={user} />
						</SettingsForm>
					</details>
				</>
			) : (
				<p className="muted">
					No source is linked. <a href="/import">Import a repository</a> to
					create a linked copy.
				</p>
			)}
		</>
	);
}

function RepositoryAudit({ repo }: { repo: Repository }) {
	const resource = useResource<{ events: AuditEvent[] }>(
		`/repositories/${repo.id}/audit`,
	);
	return (
		<>
			<h2>Repository activity</h2>
			<Alert>{resource.error}</Alert>
			{resource.value && <Events events={resource.value.events} />}
		</>
	);
}
