import { useState } from "react";
import { send, useResource } from "../../api";
import { Alert } from "../../components/common";
import { ConfirmIdentity, SettingsForm, Events } from "../../components/settings";
import type { User, AuditEvent, InstanceSettings } from "../../types";

export function Administration({ user }: { user: User }) {
	const [tab, setTab] = useState("instance");
	const resource = useResource<InstanceSettings>(user.admin || user.owner ? "/admin" : null);
	if (!user.admin && !user.owner) return <Alert>Administrator access required.</Alert>;
	const settings = resource.value;
	return (
		<>
			<h2>Administration</h2>
			<Overview />
			<div className="settingssubnav">
				<button onClick={() => setTab("instance")} className={tab === "instance" ? "selected" : ""}>
					Instance
				</button>
				<button onClick={() => setTab("users")} className={tab === "users" ? "selected" : ""}>
					Users
				</button>
				<button onClick={() => setTab("audit")} className={tab === "audit" ? "selected" : ""}>
					Audit log
				</button>
			</div>
			<Alert>{resource.error}</Alert>
			{tab === "users" ? (
				<Users user={user} />
			) : tab === "audit" ? (
				<Audit />
			) : (
				settings && (
					<>
						<SettingsForm
							onSave={async (values) => {
								await send(
									"/admin",
									{
										...values,
										file_bytes: Math.round(Number(values.file_bytes) * 1048576),
										project_storage_bytes: Math.round(
											Number(values.project_storage_bytes) * 1073741824,
										),
										account_storage_bytes: Math.round(
											Number(values.account_storage_bytes) * 1073741824,
										),
										git_hosts: String(values.git_hosts || "")
											.split(/[\n,]/)
											.map((host) => host.trim())
											.filter(Boolean),
									},
									"PATCH",
								);
								window.dispatchEvent(
									new CustomEvent("flurry:settings", {
										detail: { name: String(values.name) },
									}),
								);
							}}
						>
							<label>
								Instance name
								<input name="name" defaultValue={settings.name} maxLength={60} required />
							</label>
							<label className="check">
								<input name="registration" type="checkbox" defaultChecked={settings.registration} />
								Allow new accounts to register
							</label>
							<label className="check">
								<input
									name="require_signin"
									type="checkbox"
									defaultChecked={settings.require_signin}
								/>
								Require sign-in to browse the instance
							</label>
							<label className="check">
								<input name="allow_public" type="checkbox" defaultChecked={settings.allow_public} />
								Allow repositories to be made public
							</label>
							<label>
								Default repository visibility
								<select name="default_visibility" defaultValue={settings.default_visibility}>
									<option value="private">Private</option>
									<option value="public">Public</option>
								</select>
							</label>
							<label>
								Allowed Git hosts
								<textarea
									name="git_hosts"
									rows={4}
									defaultValue={settings.git_hosts.join("\n")}
									readOnly={settings.git_hosts_locked}
								/>
								<small>
									{settings.git_hosts_locked
										? "Controlled by FLURRY_GIT_HOSTS in the server environment."
										: "One public HTTPS hostname per line. Existing links cannot transfer from a host removed from this list."}
								</small>
							</label>
							<fieldset className="settingsgroup">
								<legend>Storage limits</legend>
								<p className="muted">
									Limits apply uniformly to repository owners. Use zero for unlimited retained
									storage.
								</p>
								<label>
									Maximum file size (MiB)
									<input
										name="file_bytes"
										type="number"
										min={1}
										max={1024}
										step={1}
										defaultValue={settings.limits.file_bytes / 1048576}
										required
									/>
								</label>
								<label>
									Per-project retained storage (GiB)
									<input
										name="project_storage_bytes"
										type="number"
										min={0}
										step={0.25}
										defaultValue={settings.limits.project_storage_bytes / 1073741824}
										required
									/>
								</label>
								<label>
									Per-account retained storage (GiB)
									<input
										name="account_storage_bytes"
										type="number"
										min={0}
										step={0.25}
										defaultValue={settings.limits.account_storage_bytes / 1073741824}
										required
									/>
								</label>
							</fieldset>
							<ConfirmIdentity user={user} />
						</SettingsForm>
						<h3 className="settingstitle">Service status</h3>
						<div className="panel">
							{Object.entries({
								"Git executable": settings.diagnostics.git_available ? "Available" : "Missing",
								"Secure session cookies": settings.diagnostics.secure_cookies
									? "Enabled"
									: "Disabled — local HTTP only",
								"Authenticator encryption": settings.diagnostics.two_factor_available
									? "Configured"
									: "Set FLURRY_SECRET_KEY",
								"Email delivery": settings.diagnostics.mail_configured
									? "Configured"
									: "Queued locally; set FLURRY_SENDMAIL_PATH to deliver",
								"OAuth provider connections": "Not implemented; use per-transfer Git tokens",
								"SSH hosting": settings.diagnostics.ssh_hosting ? "Configured" : "Not configured",
								Webhooks: "Available",
								"CI runners": "Not implemented",
								Storage: settings.diagnostics.storage,
								Backups: settings.diagnostics.backup,
							}).map(([label, value]) => (
								<div className="settingrow" key={label}>
									<strong>{label}</strong>
									<span className="muted">{value}</span>
								</div>
							))}
						</div>
					</>
				)
			)}
		</>
	);
}

function Users({ user }: { user: User }) {
	const resource = useResource<{
		users: {
			id: string;
			username: string;
			name: string;
			admin: boolean;
			owner: boolean;
			disabled: boolean;
		}[];
	}>("/admin/users");
	return (
		<>
			<p className="muted">
				The first account owns the instance and cannot be demoted or disabled. Additional
				administrators can manage access and instance policy.
			</p>
			<Alert>{resource.error}</Alert>
			{resource.value?.users.map((target) => (
				<details className="panel userdetails" key={target.id}>
					<summary>
						{target.name}{" "}
						<span className="muted">
							@{target.username}
							{target.owner ? " · instance owner" : target.admin ? " · administrator" : ""}
							{target.disabled ? " · disabled" : ""}
						</span>
					</summary>
					<SettingsForm
						label="Update account access"
						onSave={async (values) => {
							await send(`/admin/users/${target.id}`, values, "PATCH");
							resource.reload();
							window.dispatchEvent(new Event("flurry:settings"));
						}}
					>
						<label className="check">
							<input
								name="admin"
								type="checkbox"
								defaultChecked={target.admin}
								disabled={target.owner}
							/>
							Administrator
						</label>
						<label className="check">
							<input
								name="disabled"
								type="checkbox"
								defaultChecked={target.disabled}
								disabled={target.owner || target.id === user.id}
							/>
							Disable sign-in and revoke this user’s sessions and tokens
						</label>
						<ConfirmIdentity user={user} />
					</SettingsForm>
				</details>
			))}
		</>
	);
}

function Audit() {
	const resource = useResource<{ events: AuditEvent[] }>("/admin/audit");
	return (
		<>
			<Alert>{resource.error}</Alert>
			{resource.value && <Events events={resource.value.events} />}
		</>
	);
}

function Overview() {
	const resource = useResource<{
		users: number;
		repositories: number;
		owner: boolean;
	}>("/admin/overview");
	return (
		<>
			<Alert>{resource.error}</Alert>
			{resource.value && (
				<div className="adminstats">
					<div>
						<strong>{resource.value.users}</strong>
						<span>Accounts</span>
					</div>
					<div>
						<strong>{resource.value.repositories}</strong>
						<span>Retained repositories</span>
					</div>
					<div>
						<strong>{resource.value.owner ? "Owner" : "Admin"}</strong>
						<span>Your instance role</span>
					</div>
				</div>
			)}
		</>
	);
}
