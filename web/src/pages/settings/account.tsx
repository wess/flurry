import { send, useResource } from "../../api";
import { ConfirmIdentity, SettingsForm } from "../../components/settings";
import type { User } from "../../types";

export function Account({
	user,
	updated,
}: {
	user: User;
	updated: (user: User) => void;
}) {
	return (
		<>
			<h2>Account</h2>
			<p className="muted">
				Change your sign-in email or password. This signs out other sessions and
				revokes API tokens.
			</p>
			<SettingsForm
				onSave={async (values, form) => {
					const result = await send<{ user: User }>(
						"/settings/credentials",
						values,
						"PATCH",
					);
					form.reset();
					updated(result.user);
				}}
			>
				<label>
					Sign-in email
					<input
						name="email"
						type="email"
						required
						defaultValue={user.email}
						maxLength={200}
					/>
				</label>
				<label>
					New password <span className="muted">(leave empty to keep it)</span>
					<input
						name="new_password"
						type="password"
						autoComplete="new-password"
						minLength={12}
						maxLength={1024}
					/>
				</label>
				<ConfirmIdentity user={user} />
			</SettingsForm>
			<div className="settingsnote">
				<h3>Email delivery and recovery</h3>
				<p>
					Email verification, email notifications, and password-reset delivery
					are not configured. Changing this email updates your login only.
				</p>
				<p>
					Account deletion and permanent repository purging are not available
					while history retention is in place.
				</p>
			</div>
		</>
	);
}

export function Preferences({
	user,
	updated,
}: {
	user: User;
	updated: (user: User) => void;
}) {
	return (
		<>
			<h2>Preferences & privacy</h2>
			<SettingsForm
				onSave={async (values) => {
					const result = await send<{ user: User }>(
						"/settings/preferences",
						values,
						"PATCH",
					);
					updated(result.user);
				}}
			>
				<label>
					Appearance
					<select
						name="theme"
						defaultValue={user.preferences?.theme || "light"}
					>
						<option value="light">Light</option>
						<option value="dark">Dark</option>
						<option value="system">System</option>
					</select>
				</label>
				<label>
					Default repository visibility
					<select
						name="default_visibility"
						defaultValue={user.preferences?.default_visibility || "private"}
					>
						<option value="private">Private</option>
						<option value="public">Public</option>
					</select>
					<small>The instance policy can restrict public repositories.</small>
				</label>
				<label className="check">
					<input
						type="checkbox"
						name="wrap_code"
						defaultChecked={user.preferences?.wrap_code || false}
					/>
					Wrap long lines in file viewers
				</label>
				<label className="check">
					<input
						type="checkbox"
						name="private_profile"
						defaultChecked={user.private_profile}
					/>
					Make my profile visible only to me
				</label>
				<label className="check">
					<input
						type="checkbox"
						name="hide_activity"
						defaultChecked={user.hide_activity}
					/>
					Hide recent profile activity from other people
				</label>
				<p className="muted">
					Repository visibility and collaborator access are managed separately.
					Your sign-in email is always hidden on your profile.
				</p>
			</SettingsForm>
		</>
	);
}
