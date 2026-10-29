import { useState } from "react";
import { send, useAction, useResource } from "../../api";
import { Alert } from "../../components/common";
import { ConfirmIdentity, SettingsForm } from "../../components/settings";
import type { User } from "../../types";

type Agent = {
	id: string;
	name: string;
	username: string;
	token_prefix: string;
	active: boolean;
	expires_at: string;
	last_used_at: string | null;
};

export function Agents({ user }: { user: User }) {
	const resource = useResource<{ agents: Agent[] }>("/settings/agents");
	const [secret, setSecret] = useState("");
	const action = useAction();

	const mutate = (operation: () => Promise<{ token?: string }>) =>
		void action.run(async () => {
			const result = await operation();
			if (result.token) setSecret(result.token);
			resource.reload();
		});

	return (
		<>
			<h2>Agent accounts</h2>
			<p className="muted">
				Create a distinct identity for an automated worker. Agents cannot sign in
				to the browser or manage permissions; add them to repositories or teams
				just like any other member.
			</p>
			<Alert>{resource.error || action.error}</Alert>
			{secret && (
				<div className="settingsnote" role="status">
					<strong>Copy this credential now. It will not be shown again.</strong>
					<textarea aria-label="New agent credential" readOnly value={secret} rows={2} />
					<div className="row">
						<button type="button" className="small" onClick={() => void navigator.clipboard.writeText(secret)}>
							Copy credential
						</button>
						<button type="button" className="small" onClick={() => setSecret("")}>
							I saved it
						</button>
					</div>
				</div>
			)}
			<div className="panel">
				{resource.value?.agents.length ? resource.value.agents.map((agent) => (
					<div className="settingrow agentrow" key={agent.id}>
						<div className="grow">
							<strong>{agent.name} <span className="muted">@{agent.username}</span></strong>
							<small>
								{agent.active ? "Active" : "Revoked"} · {agent.token_prefix}… · expires {new Date(agent.expires_at).toLocaleDateString()}
								{agent.last_used_at ? ` · last used ${new Date(agent.last_used_at).toLocaleString()}` : " · never used"}
							</small>
						</div>
						<details className="agentactions">
							<summary>Manage</summary>
							<form onSubmit={(event) => {
								event.preventDefault();
								const values: Record<string, unknown> = Object.fromEntries(new FormData(event.currentTarget));
								values.days = Number(values.days);
								mutate(() => send(`/settings/agents/${agent.id}/rotate`, values));
							}}>
								<label>Expires in days<input name="days" type="number" min={1} max={365} defaultValue={90} required /></label>
								<ConfirmIdentity user={user} />
								<button className="primary" disabled={action.busy}>Rotate credential</button>
								<button type="button" className="dangerbutton" disabled={action.busy || !agent.active} onClick={(event) => {
									const form = event.currentTarget.form!;
									const values = Object.fromEntries(new FormData(form));
									mutate(() => send(`/settings/agents/${agent.id}/revoke`, values));
								}}>Revoke access</button>
							</form>
						</details>
					</div>
				)) : <p className="padded muted">No agent accounts yet.</p>}
			</div>
			<h3 className="settingstitle">Create an agent account</h3>
			<SettingsForm label="Create agent" notice="" onSave={async (values, form) => {
				const result = await send<{ token: string }>("/settings/agents", values);
				setSecret(result.token);
				form.reset();
				resource.reload();
			}}>
				<label>Display name<input name="name" maxLength={80} placeholder="Release worker" required /></label>
				<label>Username<input name="username" maxLength={40} pattern="[a-z0-9][a-z0-9.]*" placeholder="release.bot" required /></label>
				<label>Credential expires in days<input name="days" type="number" min={1} max={365} defaultValue={90} required /></label>
				<ConfirmIdentity user={user} />
			</SettingsForm>
		</>
	);
}
