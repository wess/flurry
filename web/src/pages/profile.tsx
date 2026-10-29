import { MapPin, Link, CalendarDays, Settings2 } from "lucide-react";
import { send, useAction, useResource } from "../api";
import { Alert, Avatar, Empty, Repositories } from "../components/common";
import { date, go, profilePath } from "../navigation";
import type { Profile, User } from "../types";

export function ProfilePage({
	username,
	user,
}: {
	username: string;
	user: User | null;
}) {
	const resource = useResource<Profile>(
		`/profiles/${encodeURIComponent(username)}`,
	);
	const profile = resource.value;
	if (!profile) return <Alert>{resource.error || "Loading profile…"}</Alert>;
	return (
		<section className="profile">
			<aside className="profileaside">
				<Avatar name={profile.name} large />
				<h1>{profile.name}</h1>
				<p className="handle">{profile.username}</p>
				{profile.bio && <p className="bio">{profile.bio}</p>}
				{user?.id === profile.id && (
					<a className="button full" href="/settings/profile">
						<Settings2 size={14} />
						Edit profile
					</a>
				)}
				<div className="profilemeta">
					{profile.location && (
						<span>
							<MapPin size={15} />
							{profile.location}
						</span>
					)}
					{profile.website && (
						<a href={profile.website} rel="noopener noreferrer" target="_blank">
							<Link size={15} />
							{profile.website.replace(/^https?:\/\//, "")}
						</a>
					)}
					<span>
						<CalendarDays size={15} />
						Joined {date(profile.joined_at)}
					</span>
				</div>
			</aside>
			<div className="profilecontent">
				<div className="sectionheading">
					<h2>
						Repositories{" "}
						<span className="count">{profile.repositories.length}</span>
					</h2>
					{user?.id === profile.id && <a href="/new">New repository</a>}
				</div>
				<Repositories repositories={profile.repositories} />
				<h2 className="activityheading">Recent changes</h2>
				{profile.activity.length ? (
					<ul className="activity">
						{profile.activity.map((item) => (
							<li key={item.id}>
								<span className="activitydot" />
								<div>
									<a href={`/repositories/${item.repository_id}/history`}>
										{item.message}
									</a>
									<small>
										{
											profile.repositories.find(
												(repo) => repo.id === item.repository_id,
											)?.name
										}{" "}
										• {date(item.inserted_at)}
									</small>
								</div>
							</li>
						))}
					</ul>
				) : (
					<Empty title="No changes yet">
						Changes to visible repositories will appear here.
					</Empty>
				)}
			</div>
		</section>
	);
}

export function EditProfile({
	user,
	updated,
}: {
	user: User | null;
	updated: (user: User) => void;
}) {
	const action = useAction();
	if (!user)
		return (
			<p>
				<a href="/login">Sign in</a> to edit your profile.
			</p>
		);
	return (
		<section className="narrow">
			<h1>Edit profile</h1>
			<p className="muted">
				This information is visible on your public profile.
			</p>
			<form
				className="form panel"
				onSubmit={(event) => {
					event.preventDefault();
					const values = Object.fromEntries(new FormData(event.currentTarget));
					void action.run(async () => {
						const next = await send<User>("/profile", values, "PATCH");
						updated(next);
						go(profilePath(next.username));
					});
				}}
			>
				<label>
					Display name
					<input name="name" required maxLength={80} defaultValue={user.name} />
				</label>
				<label>
					Bio
					<textarea
						name="bio"
						rows={3}
						maxLength={300}
						defaultValue={user.bio}
						placeholder="A little about you"
					/>
				</label>
				<label>
					Location
					<input name="location" maxLength={100} defaultValue={user.location} />
				</label>
				<label>
					Website
					<input
						name="website"
						type="url"
						maxLength={300}
						defaultValue={user.website}
						placeholder="https://"
					/>
				</label>
				<Alert>{action.error}</Alert>
				<div className="row">
					<button disabled={action.busy} className="primary">
						{action.busy ? "Saving…" : "Save profile"}
					</button>
					<a href={profilePath(user.username)}>Cancel</a>
				</div>
			</form>
		</section>
	);
}
