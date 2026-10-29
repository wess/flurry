import { useEffect, useState } from "react";

export const go = (path: string) => {
	const url = new URL(path, window.location.href);
	if (url.origin !== window.location.origin) {
		window.location.assign(url);
		return;
	}
	window.history.pushState(null, "", `${url.pathname}${url.search}${url.hash}`);
	window.dispatchEvent(new PopStateEvent("popstate"));
};
const reserved = new Set([
	"admin",
	"docs",
	"explore",
	"forgot-password",
	"import",
	"login",
	"new",
	"notifications",
	"organizations",
	"privacy",
	"repositories",
	"reset-password",
	"settings",
	"signup",
	"snippets",
	"terms",
	"users",
	"verify-email",
]);
export const profilePath = (username: string) =>
	reserved.has(username) ? `/users/${username}` : `/${username}`;
export const isSnippetHost = () => window.location.hostname.startsWith("snip.");
export const snippetOrigin = () =>
	window.location.hostname === "flurry.codes"
		? "https://snip.flurry.codes"
		: isSnippetHost()
			? window.location.origin
			: "/snippets";
export const mainOrigin = () =>
	isSnippetHost()
		? `${window.location.protocol}//${window.location.hostname.slice(5)}${window.location.port ? `:${window.location.port}` : ""}`
		: window.location.origin;
export const snippetPath = (slug = "", version?: number) => {
	const suffix = slug ? `/${slug}` : "";
	const query = version ? `?version=${version}` : "";
	return isSnippetHost() ? `${suffix || "/"}${query}` : `/snippets${suffix}${query}`;
};
export const publicProfilePath = (username: string) =>
	isSnippetHost() ? `${mainOrigin()}${profilePath(username)}` : profilePath(username);
export const short = (id: string | null) => id?.slice(0, 10) || "Empty";
export const date = (value: string) =>
	new Date(value).toLocaleDateString(undefined, {
		month: "short",
		day: "numeric",
		year: "numeric",
	});
export const dateTime = (value: string) =>
	new Date(value).toLocaleString(undefined, {
		month: "short",
		day: "numeric",
		year: "numeric",
		hour: "numeric",
		minute: "2-digit",
	});

export function useRoute() {
	const route = () => {
		if (window.location.hash.startsWith("#/")) {
			const legacy = window.location.hash.slice(1);
			window.history.replaceState(null, "", legacy);
		}
		const path = window.location.pathname;
		if (isSnippetHost()) {
			const page = path.split("/").filter(Boolean)[0];
			if (
				["forgot-password", "login", "reset-password", "signup", "verify-email"].includes(
					page || "",
				)
			)
				return `${path}${window.location.search}`;
			return path === "/"
				? `/snippets${window.location.search}`
				: `/snippets${path}${window.location.search}`;
		}
		if (
			["/terms", "/privacy"].includes(path) ||
			path === "/docs" ||
			path.startsWith("/docs/")
		)
			return `${path}${window.location.search}`;
		const match = path.match(/^\/([a-z0-9][a-z0-9.]*)\/?$/);
		const username = match?.[1];
		return username && !reserved.has(username)
			? `/users/${username}${window.location.search}`
			: `${path}${window.location.search}`;
	};
	const [location, setLocation] = useState(route);
	useEffect(() => {
		const update = () => setLocation(route());
		const click = (event: MouseEvent) => {
			if (
				event.defaultPrevented ||
				event.button !== 0 ||
				event.metaKey ||
				event.ctrlKey ||
				event.shiftKey
			)
				return;
			const anchor = (event.target as Element | null)?.closest("a");
			if (
				!anchor ||
				anchor.target ||
				anchor.download ||
				anchor.getAttribute("href")?.startsWith("#")
			)
				return;
			const url = new URL(anchor.href, window.location.href);
			if (
				url.origin !== window.location.origin ||
				url.pathname.startsWith("/api/") ||
				/\.(?:git|json|svg|txt)$/.test(url.pathname)
			)
				return;
			event.preventDefault();
			go(`${url.pathname}${url.search}${url.hash}`);
		};
		window.addEventListener("popstate", update);
		document.addEventListener("click", click);
		return () => {
			window.removeEventListener("popstate", update);
			document.removeEventListener("click", click);
		};
	}, []);
	const [path, search = ""] = location.split("?");
	return {
		parts: (path || "/").split("/").filter(Boolean).map(decodeURIComponent),
		query: new URLSearchParams(search),
	};
}
