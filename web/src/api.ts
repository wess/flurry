import { useEffect, useState } from "react";

export async function request<T>(
	path: string,
	options: RequestInit = {},
): Promise<T> {
	const response = await fetch(`/api${path}`, {
		credentials: "same-origin",
		...options,
		headers: { "Content-Type": "application/json", ...options.headers },
	});
	const data = await response.json();
	if (!response.ok) {
		const paths = data.details?.paths;
		throw new Error(
			data.error + (paths?.length ? `: ${paths.join(", ")}` : ""),
		);
	}
	return data as T;
}

export function send<T>(path: string, body: unknown = {}, method = "POST") {
	return request<T>(path, { method, body: JSON.stringify(body) });
}

export function useResource<T>(path: string | null, retain = false) {
	const [value, setValue] = useState<T | null>(null);
	const [error, setError] = useState("");
	const [version, setVersion] = useState(0);
	const [loading, setLoading] = useState(true);
	useEffect(() => {
		const controller = new AbortController();
		if (!retain) setValue(null);
		setError("");
		setLoading(Boolean(path));
		if (path)
			request<T>(path, { signal: controller.signal })
				.then(setValue)
				.catch((error: Error) => {
					if (!controller.signal.aborted) setError(error.message);
				})
				.finally(() => {
					if (!controller.signal.aborted) setLoading(false);
				});
		return () => controller.abort();
	}, [path, version, retain]);
	return { value, error, loading, reload: () => setVersion((v) => v + 1) };
}

export function useAction() {
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState("");
	async function run(action: () => Promise<void>) {
		setBusy(true);
		setError("");
		try {
			await action();
		} catch (error) {
			setError(error instanceof Error ? error.message : "Request failed");
		} finally {
			setBusy(false);
		}
	}
	return { busy, error, run };
}
