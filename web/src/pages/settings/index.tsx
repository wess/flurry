import { useResource, send, useAction } from "../../api";
import { Alert } from "../../components/common";
import { Events } from "../../components/settings";
import { EditProfile } from "../profile";
import { Account, Preferences } from "./account";
import { Sessions, Tokens } from "./access";
import { Agents } from "./agents";
import { Factor } from "./factor";
import { Administration } from "./instance";
import type { User, AuditEvent } from "../../types";

export function SettingsPage({
	user,
	section = "profile",
	updated,
}: {
	user: User | null;
	section?: string;
	updated: (user: User) => void;
}) {
	if (!user)
		return (
			<p>
				<a href="/login">Sign in</a> to manage settings.
			</p>
		);
	const links = [
		["profile", "Profile"],
		["account", "Account"],
		["security", "Authentication"],
		["sessions", "Sessions"],
		["tokens", "Access tokens"],
		["agents", "Agent accounts"],
		["preferences", "Preferences & privacy"],
		["removed", "Removed repositories"],
		["audit", "Security log"],
	];
	if (user.admin || user.owner) links.push(["instance", "Administration"]);
	let content;
	switch (section) {
		case "account":
			content = <Account user={user} updated={updated} />;
			break;
		case "security":
			content = <Factor user={user} updated={updated} />;
			break;
		case "sessions":
			content = <Sessions />;
			break;
		case "tokens":
			content = <Tokens user={user} />;
			break;
		case "agents":
			content = <Agents user={user} />;
			break;
		case "preferences":
			content = <Preferences user={user} updated={updated} />;
			break;
		case "removed":
			content = <Removed />;
			break;
		case "audit":
			content = <SecurityLog />;
			break;
		case "instance":
			content = <Administration user={user} />;
			break;
		default:
			content = <EditProfile user={user} updated={updated} />;
	}
	return (
		<section>
			<h1 className="settingsheading">Settings</h1>
			<div className="settingslayout">
				<nav className="settingsnav" aria-label="Settings sections">
					{links.map(([path, label]) => (
						<a
							className={path === section ? "active" : ""}
							href={path === "instance" ? "/admin" : `/settings/${path}`}
							key={path}
						>
							{label}
						</a>
					))}
				</nav>
				<div className="settingscontent" key={section}>
					{content}
				</div>
			</div>
		</section>
	);
}

function Removed() {
	const resource = useResource<{
		repositories: { id: string; name: string; deleted_at: string }[];
	}>("/settings/removed");
	const action = useAction();
	return (
		<>
			<h2>Removed repositories</h2>
			<p className="muted">
				Removed repositories retain their history. Restoring keeps them private
				and archived until you reopen them.
			</p>
			<Alert>{resource.error || action.error}</Alert>
			<div className="panel">
				{resource.value?.repositories.length ? (
					resource.value.repositories.map((repo) => (
						<div className="settingrow" key={repo.id}>
							<strong className="grow">{repo.name}</strong>
							<button
								onClick={() =>
									void action.run(async () => {
										await send(`/settings/removed/${repo.id}/restore`);
										resource.reload();
									})
								}
								disabled={action.busy}
							>
								Restore
							</button>
						</div>
					))
				) : (
					<p className="padded muted">No removed repositories.</p>
				)}
			</div>
		</>
	);
}

function SecurityLog() {
	const resource = useResource<{ events: AuditEvent[] }>("/settings/audit");
	return (
		<>
			<h2>Security log</h2>
			<p className="muted">
				Recent account and permission changes. Secrets are excluded.
			</p>
			<Alert>{resource.error}</Alert>
			{resource.value && <Events events={resource.value.events} />}
		</>
	);
}
