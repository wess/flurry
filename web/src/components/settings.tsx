import type { ReactNode } from "react";
import { useState } from "react";
import { useAction } from "../api";
import { Alert } from "./common";
import type { User } from "../types";

export function SettingsForm({
	children,
	onSave,
	label = "Save changes",
	notice = "Saved",
}: {
	children: ReactNode;
	onSave: (
		values: Record<string, unknown>,
		form: HTMLFormElement,
	) => Promise<void>;
	label?: string;
	notice?: string;
}) {
	const action = useAction();
	const [saved, setSaved] = useState(false);
	return (
		<form
			className="form settingsform"
			onChange={() => setSaved(false)}
			onSubmit={(event) => {
				event.preventDefault();
				const form = event.currentTarget;
				const values: Record<string, unknown> = Object.fromEntries(
					new FormData(form),
				);
				for (const input of Array.from(
					form.querySelectorAll<HTMLInputElement>("input[name]"),
				)) {
					if (input.type === "checkbox") values[input.name] = input.checked;
					if (input.type === "number") values[input.name] = Number(input.value);
				}
				void action.run(async () => {
					await onSave(values, form);
					setSaved(true);
				});
			}}
		>
			{children}
			<Alert>{action.error}</Alert>
			<div className="row">
				<button className="primary" disabled={action.busy}>
					{action.busy ? "Saving…" : label}
				</button>
				{saved && notice && (
					<span className="success" role="status">
						{notice}
					</span>
				)}
			</div>
		</form>
	);
}

export function ConfirmIdentity({
	user,
	required = true,
	label = "Current password",
}: {
	user: User;
	required?: boolean;
	label?: string;
}) {
	return (
		<>
			<label>
				{label}
				<input
					name="password"
					type="password"
					autoComplete="current-password"
					required={required}
					maxLength={1024}
				/>
			</label>
			{user.two_factor && (
				<label>
					Authenticator or recovery code
					<input
						name="code"
						autoComplete="one-time-code"
						maxLength={100}
						required={required}
					/>
				</label>
			)}
		</>
	);
}

export function Events({
	events,
}: {
	events: {
		id: number;
		event: string;
		inserted_at: string;
		details: Record<string, unknown>;
	}[];
}) {
	return (
		<div className="panel">
			{events.length ? (
				events.map((event) => (
					<div className="settingrow" key={event.id}>
						<div className="grow">
							<strong>{event.event.replaceAll(".", " · ")}</strong>
							{Object.keys(event.details).length > 0 && (
								<small>
									{Object.entries(event.details)
										.map(([key, value]) => `${key}: ${String(value)}`)
										.join(" · ")}
								</small>
							)}
						</div>
						<small className="muted">
							{new Date(event.inserted_at).toLocaleString()}
						</small>
					</div>
				))
			) : (
				<p className="padded muted">No events recorded yet.</p>
			)}
		</div>
	);
}
