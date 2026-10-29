import { useState } from "react";
import { request, send, useAction, useResource } from "../../api";
import { Alert } from "../../components/common";
import { ConfirmIdentity, SettingsForm } from "../../components/settings";
import type { User, Repository } from "../../types";

export function Sessions() {
	const resource = useResource<{
		sessions: {
			id: string;
			label: string;
			current: boolean;
			inserted_at: string;
			expires_at: string;
		}[];
	}>("/settings/sessions");
	const action = useAction();
	return (
		<>
			<h2>Sessions</h2>
			<p className="muted">
				Review signed-in sessions and revoke access you no longer use.
			</p>
			<Alert>{resource.error || action.error}</Alert>
			<div className="panel">
				{resource.value?.sessions.map((session) => (
					<div className="settingrow" key={session.id}>
						<div className="grow">
							<strong>
								{session.current ? "This session" : session.label}
							</strong>
							<small>
								Started {new Date(session.inserted_at).toLocaleString()} ·
								expires {new Date(session.expires_at).toLocaleDateString()}
							</small>
						</div>
						{!session.current && (
							<button
								disabled={action.busy}
								onClick={() =>
									void action.run(async () => {
										await request(`/settings/sessions/${session.id}`, {
											method: "DELETE",
										});
										resource.reload();
									})
								}
							>
								Revoke
							</button>
						)}
					</div>
				))}
			</div>
			<button
				className="settingsbutton"
				disabled={action.busy}
				onClick={() =>
					void action.run(async () => {
						await send("/settings/sessions/others");
						resource.reload();
					})
				}
			>
				Sign out other sessions
			</button>
		</>
	);
}

export function Tokens({ user }: { user: User }) {
	const resource = useResource<{
		tokens: {
			id: string;
			name: string;
			access: string;
			repository_id: string | null;
			expires_at: string;
		}[];
	}>("/settings/tokens");
	const repos = useResource<{ repositories: Repository[] }>("/repositories");
	const [secret, setSecret] = useState("");
	const action = useAction();
	return (
		<>
			<h2>Access tokens</h2>
			<p className="muted">
				Use a separate, expiring token for each client. Read-only tokens cannot
				change code; tokens cannot manage account, source, or instance settings.
			</p>
			<Alert>{resource.error || action.error}</Alert>
			{secret && (
				<div className="settingsnote">
					<strong>Copy this token now. It will not be shown again.</strong>
					<textarea
						aria-label="New access token"
						readOnly
						value={secret}
						rows={2}
					/>
					<button className="small" onClick={() => setSecret("")}>
						I saved the token
					</button>
				</div>
			)}
			<div className="panel">
				{resource.value?.tokens.length ? (
					resource.value.tokens.map((token) => (
						<div className="settingrow" key={token.id}>
							<div className="grow">
								<strong>{token.name}</strong>
								<small>
									{token.access} ·{" "}
									{token.repository_id
										? repos.value?.repositories.find(
												(r) => r.id === token.repository_id,
											)?.name || "Selected repository"
										: "All accessible repositories"}{" "}
									· expires {new Date(token.expires_at).toLocaleDateString()}
								</small>
							</div>
							<button
								disabled={action.busy}
								onClick={() =>
									void action.run(async () => {
										await request(`/settings/tokens/${token.id}`, {
											method: "DELETE",
										});
										resource.reload();
									})
								}
							>
								Revoke
							</button>
						</div>
					))
				) : (
					<p className="padded muted">No API tokens.</p>
				)}
			</div>
			<h3 className="settingstitle">Create a token</h3>
			<SettingsForm
				label="Create token"
				notice=""
				onSave={async (values, form) => {
					const result = await send<{ token: string }>(
						"/settings/tokens",
						values,
					);
					setSecret(result.token);
					form.reset();
					resource.reload();
				}}
			>
				<label>
					Token name
					<input
						name="name"
						required
						maxLength={80}
						placeholder="Laptop client"
					/>
				</label>
				<label>
					Access
					<select name="access">
						<option value="read">Read only</option>
						<option value="write">Read and write code</option>
					</select>
				</label>
				<label>
					Repository scope
					<select name="repository_id">
						<option value="">All accessible repositories</option>
						{repos.value?.repositories.map((repo) => (
							<option key={repo.id} value={repo.id}>
								{repo.owner.username}/{repo.name}
							</option>
						))}
					</select>
				</label>
				<label>
					Expires in days
					<input
						type="number"
						name="days"
						min={1}
						max={365}
						defaultValue={30}
						required
					/>
				</label>
				<ConfirmIdentity user={user} />
			</SettingsForm>
		</>
	);
}
