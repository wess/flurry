import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { AtlasProvider } from "@wess/atlas-ui/provider/index.tsx";
import "@mantine/core/styles.css";
import "./style/index.css";
import { request, send, useAction } from "./api";
import {
	go,
	isSnippetHost,
	mainOrigin,
	profilePath,
	snippetPath,
	useRoute,
} from "./navigation";
import { Header } from "./components/header";
import { Alert } from "./components/common";
import { AuthPage } from "./pages/auth";
import { Landing } from "./pages/landing";
import { Legal } from "./pages/legal";
import { Docs } from "./pages/docs";
import { docsTopics } from "./pages/docs-data";
import { Administration } from "./pages/settings/instance";
import { Home, NewRepository } from "./pages/home";
import { ImportRepository } from "./pages/import";
import { ProfilePage } from "./pages/profile";
import { SettingsPage } from "./pages/settings";
import { RepositoryPage } from "./pages/repository";
import { Organizations } from "./pages/organizations";
import { SnippetsPage } from "./pages/snippets";
import { Notifications, ResetPassword, ResetRequest, VerifyEmail } from "./pages/identity";
import type { Session, User } from "./types";

const metadata = {
	home: {
		title: "Flurry — Source control with Git at the edge",
		description:
			"Flurry is a self-hosted, Git-compatible source-control engine built on immutable changesets, content-addressed files, and server-side review.",
		path: "/",
	},
	terms: {
		title: "Instance terms — Flurry",
		description: "How service terms belong to the independent operator of each Flurry instance.",
		path: "/terms",
	},
	privacy: {
		title: "Instance privacy — Flurry",
		description:
			"What data Flurry stores and which privacy responsibilities belong to an instance operator.",
		path: "/privacy",
	},
	docs: {
		title: "Flurry documentation — Git, fsc, API, MCP, and automation",
		description:
			"Learn Flurry in the browser and with Git or fsc, then build secure integrations with the HTTP API, webhooks, automation records, and MCP server.",
		path: "/docs",
	},
	snippets: {
		title: "Snippets — Flurry",
		description: "Share small pieces of code with durable links and revision history.",
		path: "/",
	},
} as const;

const setMeta = (selector: string, content: string) => {
	const element = document.head.querySelector<HTMLMetaElement>(selector);
	if (element) element.content = content;
};

function App() {
	const [session, setSession] = useState<Session | null>(null);
	const [error, setError] = useState("");
	const action = useAction();
	const { parts, query } = useRoute();
	useEffect(() => {
		void request<Session>("/session")
			.then(setSession)
			.catch((error) => setError(error.message));
	}, []);
	useEffect(() => {
		const refresh = (event: Event) => {
			const name = (event as CustomEvent<{ name?: string }>).detail?.name;
			if (name) {
				setSession((previous) =>
					previous?.site?.name === name
						? previous
						: { ...previous!, site: { ...previous!.site!, name } },
				);
				return;
			}
			void request<Session>("/session")
				.then(setSession)
				.catch(() => {});
		};
		window.addEventListener("flurry:settings", refresh);
		return () => window.removeEventListener("flurry:settings", refresh);
	}, []);
	useEffect(() => {
		const route = parts[0] || "home";
		const topic =
			route === "docs" && parts[1] ? docsTopics.find(([slug]) => slug === parts[1]) : null;
		const value = topic
			? {
					title: `${topic[1]} — Flurry documentation`,
					description: topic[2],
					path: `/docs/${topic[0]}`,
				}
			: route === "users" && parts[1]
				? {
						title: `${parts[1]} — Flurry`,
						description: `View ${parts[1]} on Flurry.`,
						path: profilePath(parts[1]),
					}
				: metadata[route as keyof typeof metadata];
		const publicPage = Boolean(value);
		const title = value?.title || (route === "users" ? `${parts[1]} · Flurry` : "Flurry");
		const description = value?.description || "A self-hosted source-control service.";
		document.title = title;
		setMeta('meta[name="description"]', description);
		setMeta('meta[name="robots"]', publicPage ? "index, follow" : "noindex, nofollow");
		setMeta('meta[property="og:title"]', title);
		setMeta('meta[property="og:description"]', description);
		setMeta('meta[name="twitter:title"]', title);
		setMeta('meta[name="twitter:description"]', description);

		let canonical = document.head.querySelector<HTMLLinkElement>('link[rel="canonical"]');
		if (publicPage) {
			canonical ||= document.head.appendChild(document.createElement("link"));
			canonical.rel = "canonical";
			canonical.href = `${window.location.origin}${value.path}`;
			setMeta('meta[property="og:url"]', canonical.href);
		} else {
			canonical?.remove();
		}
	}, [parts.join("/")]);
	useEffect(() => {
		const preferences = session?.user?.preferences;
		const media = window.matchMedia("(prefers-color-scheme: dark)");
		const apply = () => {
			const theme = preferences?.theme || "system";
			document.documentElement.dataset.theme =
				theme === "dark" || (theme === "system" && media.matches) ? "dark" : "light";
			document.body.classList.toggle("wrapcode", Boolean(preferences?.wrap_code));
		};
		apply();
		media.addEventListener("change", apply);
		return () => media.removeEventListener("change", apply);
	}, [session?.user?.preferences]);
	if (!session)
		return (
			<main className="shell">
				<Alert>{error || "Connecting to Flurry…"}</Alert>
			</main>
		);
	const signedIn = (user: User) => {
		setSession((previous) => ({ ...previous, ready: true, user }));
		go(isSnippetHost() ? snippetPath() : profilePath(user.username));
	};
	const logout = () =>
		void action.run(async () => {
			await request("/session", { method: "DELETE" });
			setSession((previous) => ({ ...previous, ready: true, user: null }));
			go("/login");
		});
	const [page, id, section, review] = parts;
	let content;
	if (page === "login" || page === "signup")
		content = (
			<AuthPage
				key={page}
				signup={page === "signup"}
				ready={session.ready}
				registration={session.site?.registration}
				signedIn={signedIn}
			/>
		);
	else if (page === "forgot-password") content = <ResetRequest />;
	else if (page === "reset-password") content = <ResetPassword token={query.get("token") || ""} />;
	else if (page === "verify-email")
		content = (
			<VerifyEmail
				token={query.get("token") || ""}
				verified={(user) => setSession((previous) => ({ ...previous!, user }))}
			/>
		);
	else if (page === "notifications")
		content = session.user ? <Notifications /> : <p>Sign in to see notifications.</p>;
	else if (page === "users" && id)
		content = <ProfilePage key={`${id}:${session.user?.name}`} username={id} user={session.user} />;
	else if (page === "terms" || page === "privacy") content = <Legal policy={page} />;
	else if (page === "docs") content = <Docs topic={id} />;
	else if (page === "admin")
		content = session.user ? (
			<Administration user={session.user} />
		) : (
			<p>Sign in to administer this instance.</p>
		);
	else if (!page && !session.user) content = <Landing site={session.site} />;
	else if (page === "settings")
		content = (
			<SettingsPage
				user={session.user}
				section={id}
				updated={(user) => setSession((previous) => ({ ...previous, ready: true, user }))}
			/>
		);
	else if (page === "new") content = <NewRepository user={session.user} site={session.site} />;
	else if (page === "import")
		content = <ImportRepository user={session.user} site={session.site} />;
	else if (page === "organizations")
		content = session.user ? <Organizations user={session.user} id={id} /> : <p>Sign in to manage teams.</p>;
	else if (page === "snippets")
		content = (
			<SnippetsPage
				key={[id, section, query.get("version")].join(":")}
				user={session.user}
				slug={id}
				section={section}
				version={query.get("version")}
			/>
		);
	else if (page === "repositories" && id)
		content = (
			<RepositoryPage
				key={id}
				id={id}
				section={section}
				review={review}
				query={query}
				user={session.user}
				site={session.site}
			/>
		);
	else if (!page || page === "explore")
		content = (
			<Home key={`${page}:${session.user?.id}`} user={session.user} explore={page === "explore"} />
		);
	else
		content = (
			<p>
				Page not found. <a href="/">Go to repositories</a>.
			</p>
		);
	return (
		<>
			<Header user={session.user} logout={logout} site={session.site} />
			<main className={page === "docs" ? "shell docsshell" : "shell"}>
				<Alert>{action.error}</Alert>
				{session.user && session.user.email_verified === false && page !== "verify-email" && (
					<div className="alert">
						Verify your email to keep account recovery available.{" "}
						<button
							className="small"
							onClick={() =>
								void action.run(async () => {
									await send("/email/verification");
								})
							}
						>
							Send verification
						</button>
					</div>
				)}
				{content}
			</main>
			<footer>
				{isSnippetHost() ? "Flurry Snip" : "Flurry"}{" "}
				<span>{isSnippetHost() ? "Small code, durable links." : "Source control, kept simple."}</span>
				<a href={isSnippetHost() ? mainOrigin() + "/docs" : "/docs"}>Docs</a>
				<a href={isSnippetHost() ? mainOrigin() + "/terms" : "/terms"}>Terms</a>
				<a href={isSnippetHost() ? mainOrigin() + "/privacy" : "/privacy"}>Privacy</a>
				<span>0.1.3</span>
			</footer>
		</>
	);
}

createRoot(document.getElementById("root")!).render(
	<React.StrictMode>
		<AtlasProvider
			theme={{
				primaryColor: "blue",
				fontFamily: "system-ui, sans-serif",
				defaultRadius: "sm",
			}}
		>
			<App />
		</AtlasProvider>
	</React.StrictMode>,
);
