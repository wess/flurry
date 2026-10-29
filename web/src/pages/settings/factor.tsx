import { useState } from "react";
import { send, useResource } from "../../api";
import { Alert } from "../../components/common";
import { ConfirmIdentity, SettingsForm } from "../../components/settings";
import type { User } from "../../types";
import { Passkeys } from "./passkeys";

export function Factor({
	user,
	updated,
}: {
	user: User;
	updated: (user: User) => void;
}) {
	const resource = useResource<{ two_factor_available: boolean }>(
		"/settings/account",
	);
	const [setup, setSetup] = useState<{ secret: string; uri: string } | null>(null);
	const [codes, setCodes] = useState<string[]>([]);
	return (
		<>
			<Passkeys user={user} updated={updated} />
			<hr className="settingsdivider" />
			<h2>Two-factor authentication</h2>
			<p className="muted">
				Use a time-based authenticator app in addition to your password.
			</p>
			<Alert>{resource.error}</Alert>
			{codes.length > 0 && (
				<div className="settingsnote">
					<strong>Save your recovery codes now.</strong>
					<p>Each code can be used once in place of an authenticator code.</p>
					<textarea
						aria-label="Recovery codes"
						readOnly
						value={codes.join("\n")}
						rows={10}
					/>
					<button onClick={() => setCodes([])}>
						I saved my recovery codes
					</button>
				</div>
			)}
			{user.two_factor ? (
				<>
					<p className="success">Two-factor authentication is enabled.</p>
					<p>
						Authenticator codes cannot be reused. If you just signed in, wait
						for your app’s next code before confirming another security change.
					</p>
					<SettingsForm
						label="Disable two-factor authentication"
						onSave={async (values, form) => {
							const result = await send<{ user: User }>(
								"/settings/twofactor/disable",
								values,
							);
							form.reset();
							updated(result.user);
							setSetup(null);
						}}
					>
						<ConfirmIdentity user={user} />
					</SettingsForm>
					<SettingsForm
						label="Replace recovery codes"
						notice=""
						onSave={async (values, form) => {
							const result = await send<{ user: User; recovery_codes: string[] }>(
								"/settings/twofactor/recovery-codes",
								values,
							);
							form.reset();
							updated(result.user);
							setCodes(result.recovery_codes);
						}}
					>
						<p>Replacing recovery codes invalidates every code from the previous set.</p>
						<ConfirmIdentity user={user} />
					</SettingsForm>
				</>
			) : resource.value && !resource.value.two_factor_available ? (
				<div className="settingsnote">
					The administrator must configure <code>FLURRY_SECRET_KEY</code> to
					encrypt authenticator secrets before two-factor authentication can be
					enabled.
				</div>
			) : setup ? (
				<>
					<div className="settingsnote">
						<p>
							Add this setup key to your authenticator app as a time-based
							account named Flurry.
						</p>
						<code className="setupkey">{setup.secret}</code>
						<a className="button small" href={setup.uri}>Open authenticator app</a>
					</div>
					<SettingsForm
						label="Enable two-factor authentication"
						notice=""
						onSave={async (values, form) => {
							const result = await send<{
								user: User;
								recovery_codes: string[];
							}>("/settings/twofactor/enable", values);
							form.reset();
							setCodes(result.recovery_codes);
							setSetup(null);
							updated(result.user);
						}}
					>
						<ConfirmIdentity user={user} />
						<label>
							Code from authenticator
							<input
								name="code"
								required
								inputMode="numeric"
								autoComplete="one-time-code"
								pattern="[0-9]{6}"
							/>
						</label>
					</SettingsForm>
				</>
			) : (
				<SettingsForm
					label="Set up authenticator"
					notice=""
					onSave={async (values, form) => {
						const result = await send<{ secret: string; uri: string }>(
							"/settings/twofactor/prepare",
							values,
						);
						form.reset();
						setSetup(result);
					}}
				>
					<ConfirmIdentity user={user} />
				</SettingsForm>
			)}
		</>
	);
}
