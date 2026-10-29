import { useState, type ReactNode } from "react";
import { request, send, useAction, useResource } from "../api";
import { Alert } from "../components/common";
import { SettingsForm } from "../components/settings";
import { go } from "../navigation";
import type { User } from "../types";

type OrganizationListItem = { id: string; name: string; slug: string; role: "member" | "admin" | "owner" };
type Person = Pick<User, "id" | "name" | "username"> & { account_type?: "human" | "agent"; role: string };
type Team = {
	id: string;
	name: string;
	slug: string;
	members: Person[];
	repositories: { id: string; name: string; role: string }[];
};
type Organization = OrganizationListItem & {
	members: Person[];
	teams: Team[];
	repositories: { id: string; name: string; visibility: string }[];
};

export function Organizations({ user, id }: { user: User; id?: string }) {
	return id ? <OrganizationDetail user={user} id={id} /> : <OrganizationList />;
}

function OrganizationList() {
	const resource = useResource<{ organizations: OrganizationListItem[] }>("/organizations");
	return (
		<section>
			<div className="pageheading">
				<div><h1>Teams</h1><p className="muted">Group people and agent accounts, then grant repository access once.</p></div>
			</div>
			<Alert>{resource.error}</Alert>
			<div className="orglayout">
				<div className="panel orglist">
					{resource.value?.organizations.length ? resource.value.organizations.map((org) => (
						<a className="settingrow" href={`/organizations/${org.id}`} key={org.id}>
							<div className="grow"><strong>{org.name}</strong><small>{org.slug} · {org.role}</small></div>
							<span aria-hidden="true">→</span>
						</a>
					)) : <p className="padded muted">You do not belong to an organization yet.</p>}
				</div>
				<div>
					<h2>Create an organization</h2>
					<SettingsForm label="Create organization" onSave={async (values) => {
						const org = await send<OrganizationListItem>("/organizations", values);
						go(`/organizations/${org.id}`);
					}}>
						<label>Name<input name="name" maxLength={100} placeholder="Product group" required /></label>
						<label>Slug<input name="slug" maxLength={80} pattern="[a-z0-9][a-z0-9-]*" placeholder="product-group" required /></label>
					</SettingsForm>
				</div>
			</div>
		</section>
	);
}

function OrganizationDetail({ user, id }: { user: User; id: string }) {
	const resource = useResource<Organization>(`/organizations/${id}`);
	const action = useAction();
	const [openTeam, setOpenTeam] = useState<string | null>(null);
	const organization = resource.value;
	const canManage = organization?.role === "admin" || organization?.role === "owner";
	const run = (operation: () => Promise<unknown>) => void action.run(async () => { await operation(); resource.reload(); });

	return (
		<section>
			<a className="backlink" href="/organizations">← All teams</a>
			<div className="pageheading"><div><h1>{organization?.name || "Organization"}</h1><p className="muted">Members, teams, and repository access in one place.</p></div></div>
			<Alert>{resource.error || action.error}</Alert>
			{organization && <>
				<section className="orgsection">
					<div className="sectionheading"><h2>Members</h2><span className="muted">{organization.members.length}</span></div>
					<div className="panel">
						{organization.members.map((member) => <div className="settingrow" key={member.id}>
							<div className="grow"><strong>{member.name} <span className="muted">@{member.username}</span></strong><small>{member.account_type === "agent" ? "Agent account · " : ""}{member.role}</small></div>
							{canManage && member.id !== user.id && <button className="small" onClick={() => run(() => request(`/organizations/${id}/members/${member.id}`, { method: "DELETE" }))}>Remove</button>}
						</div>)}
					</div>
					{canManage && <InlineForm label="Add or update member" onSave={(values) => send(`/organizations/${id}/members`, values)} done={resource.reload}>
						<label>Username<input name="username" required /></label>
						<label>Organization role<select name="role"><option value="member">Member</option><option value="admin">Administrator</option><option value="owner">Owner</option></select></label>
					</InlineForm>}
				</section>

				<section className="orgsection">
					<div className="sectionheading"><h2>Teams</h2><span className="muted">{organization.teams.length}</span></div>
					{organization.teams.length ? organization.teams.map((team) => {
						const maintains = canManage || team.members.some((member) => member.id === user.id && member.role === "maintainer");
						return <article className="teamblock" key={team.id}>
							<button className="teamheading" type="button" aria-expanded={openTeam === team.id} onClick={() => setOpenTeam(openTeam === team.id ? null : team.id)}>
								<span><strong>{team.name}</strong><small>{team.members.length} members · {team.repositories.length} repositories</small></span><span aria-hidden="true">{openTeam === team.id ? "−" : "+"}</span>
							</button>
							{openTeam === team.id && <div className="teamdetail">
								<h3>Members</h3>
								{team.members.length ? team.members.map((member) => <div className="settingrow compact" key={member.id}><span className="grow"><strong>@{member.username}</strong><small>{member.account_type === "agent" ? "Agent · " : ""}{member.role}</small></span>{maintains && <button className="small" onClick={() => run(() => request(`/organizations/${id}/teams/${team.id}/members/${member.id}`, { method: "DELETE" }))}>Remove</button>}</div>) : <p className="muted">No members in this team.</p>}
								{maintains && <InlineForm label="Add team member" onSave={(values) => send(`/organizations/${id}/teams/${team.id}/members`, values)} done={resource.reload}><label>Organization member username<input name="username" required /></label><label>Team role<select name="role"><option value="member">Member</option><option value="maintainer">Maintainer</option></select></label></InlineForm>}
								<h3>Repository access</h3>
								{team.repositories.length ? team.repositories.map((repo) => <div className="settingrow compact" key={repo.id}><span className="grow"><strong>{repo.name}</strong><small>{repo.role}</small></span>{canManage && <button className="small" onClick={() => run(() => request(`/organizations/${id}/teams/${team.id}/repositories/${repo.id}`, { method: "DELETE" }))}>Remove</button>}</div>) : <p className="muted">No repositories assigned.</p>}
								{canManage && <InlineForm label="Grant repository access" onSave={(values) => send(`/organizations/${id}/teams/${team.id}/repositories/${values.repository}`, { role: values.role }, "PUT")} done={resource.reload}><label>Repository<select name="repository" required><option value="">Choose a repository</option>{organization.repositories.map((repo) => <option key={repo.id} value={repo.id}>{repo.name}</option>)}</select></label><label>Access<select name="role"><option value="read">Read</option><option value="write">Write</option><option value="maintain">Maintain</option></select></label></InlineForm>}
							</div>}
						</article>;
					}) : <div className="panel"><p className="padded muted">No teams yet.</p></div>}
					{canManage && <InlineForm label="Create team" onSave={(values) => send(`/organizations/${id}/teams`, values)} done={resource.reload}><label>Name<input name="name" required /></label><label>Slug<input name="slug" pattern="[a-z0-9][a-z0-9-]*" required /></label></InlineForm>}
				</section>
			</>}
		</section>
	);
}

function InlineForm({ label, onSave, done, children }: { label: string; onSave: (values: Record<string, string>) => Promise<unknown>; done: () => void; children: ReactNode }) {
	const action = useAction();
	return <details className="inlineform"><summary>{label}</summary><form className="form" onSubmit={(event) => {
		event.preventDefault();
		const form = event.currentTarget;
		const values = Object.fromEntries(new FormData(form)) as Record<string, string>;
		void action.run(async () => { await onSave(values); form.reset(); done(); });
	}}>{children}<Alert>{action.error}</Alert><button className="primary" disabled={action.busy}>{action.busy ? "Saving…" : label}</button></form></details>;
}
