import { Snowflake, Plus, LogOut, Settings, Bell } from "lucide-react";
import { Avatar } from "./common";
import {
	isSnippetHost,
	mainOrigin,
	publicProfilePath,
	snippetOrigin,
	snippetPath,
} from "../navigation";
import type { User, Site } from "../types";

export function Header({
	user,
	logout,
	site,
}: {
	user: User | null;
	logout: () => void;
	site?: Site;
}) {
	const snippets = isSnippetHost();
	return (
		<header className="header">
			<div className="headerinner">
				<a className="brand" href="/">
					<Snowflake size={25} strokeWidth={1.8} />
					<span className="brandname">
						{site?.name || "Flurry"}
						{snippets && <small>Snip</small>}
					</span>
				</a>
				<nav aria-label="Main navigation">
					{snippets ? (
						<>
							<a href="/">Snippets</a>
							<a href={mainOrigin()}>Source</a>
							<a href={`${mainOrigin()}/docs`}>Docs</a>
						</>
					) : (
						<>
							{user && <a href="/">Repositories</a>}
							{user && <a href="/organizations">Teams</a>}
							<a href="/explore">Explore</a>
							<a href={snippetOrigin()}>Snippets</a>
							<a href="/docs">Docs</a>
						</>
					)}
				</nav>
				<div className="headeractions">
					{user ? (
						<>
							<a
								className="iconbutton"
								href={snippets ? `${mainOrigin()}/notifications` : "/notifications"}
								aria-label="Notifications"
							>
								<Bell size={17} />
							</a>
							<a
								className="iconbutton"
								href={snippets ? snippetPath("new") : "/new"}
								aria-label={snippets ? "New snippet" : "New repository"}
							>
								<Plus size={18} />
							</a>
							<a className="profilelink" href={publicProfilePath(user.username)}>
								<Avatar name={user.name} />
								<span>{user.username}</span>
							</a>
							<a
								className="iconbutton"
								href={snippets ? `${mainOrigin()}/settings/profile` : "/settings/profile"}
								aria-label="Settings"
							>
								<Settings size={17} />
							</a>
							<button
								className="iconbutton"
								onClick={logout}
								aria-label="Sign out"
							>
								<LogOut size={16} />
							</button>
						</>
					) : (
						<>
							<a href="/login">Sign in</a>
							{site?.registration !== false && (
								<a className="button small" href="/signup">
									Create account
								</a>
							)}
						</>
					)}
				</div>
			</div>
		</header>
	);
}
