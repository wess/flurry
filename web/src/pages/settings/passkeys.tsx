import { KeyRound, Trash2 } from "lucide-react";
import { request, send, useAction, useResource } from "../../api";
import { Alert } from "../../components/common";
import { ConfirmIdentity, SettingsForm } from "../../components/settings";
import { createPasskey } from "../../passkeys";
import { dateTime } from "../../navigation";
import type { Passkey, User } from "../../types";

export function Passkeys({ user, updated }: { user: User; updated: (user: User) => void }) {
	const resource = useResource<{ passkeys: Passkey[] }>("/settings/passkeys");
	const action = useAction();
	return (
		<section className="passkeysettings">
			<h2>Passkeys</h2>
			<p className="muted">
				Sign in with your device unlock, fingerprint, face, or hardware security key. Add more than one so a lost device does not lock you out.
			</p>
			<Alert>{resource.error || action.error}</Alert>
			{resource.value?.passkeys.length ? (
				<div className="panel passkeylist">
					{resource.value.passkeys.map((passkey) => (
						<div className="settingrow" key={passkey.id}>
							<KeyRound size={17} />
							<div className="grow">
								<strong>{passkey.name}</strong>
								<small>
									Added {dateTime(passkey.inserted_at)}
									{passkey.last_used_at ? ` · Last used ${dateTime(passkey.last_used_at)}` : ""}
									{passkey.backed_up ? " · Synced" : ""}
								</small>
							</div>
							<details className="passkeymanage">
								<summary className="button small">Manage</summary>
								<SettingsForm
									label="Rename passkey"
									notice="Renamed"
									onSave={async (values) => {
										await send(`/settings/passkeys/${passkey.id}`, values, "PATCH");
										resource.reload();
									}}
								>
									<label>
										Name
										<input name="name" required maxLength={80} defaultValue={passkey.name} />
									</label>
								</SettingsForm>
								<SettingsForm
									label="Remove passkey"
									notice=""
									onSave={async (values) => {
										const result = await request<{ user: User }>(`/settings/passkeys/${passkey.id}`, {
											method: "DELETE",
											body: JSON.stringify(values),
										});
										updated(result.user);
										resource.reload();
									}}
								>
									<ConfirmIdentity user={user} />
									<span className="dangerlabel"><Trash2 size={14} /> This passkey will stop working immediately.</span>
								</SettingsForm>
							</details>
						</div>
					))}
				</div>
			) : (
				<p className="settingsnote">No passkeys are registered yet.</p>
			)}
			<SettingsForm
				label="Add passkey"
				notice="Passkey added"
				onSave={async (values, form) => {
					const result = await createPasskey(values);
					form.reset();
					updated(result.user);
					resource.reload();
				}}
			>
				<label>
					Passkey name
					<input name="name" required maxLength={80} placeholder="Personal laptop" />
				</label>
				<ConfirmIdentity user={user} />
			</SettingsForm>
		</section>
	);
}
