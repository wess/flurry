import { useEffect, useRef, useState } from "react";
import { role } from "./account";
import type { Account } from "./account";
import { Detail } from "./detail";
import { send, useResource } from "../../../api";
import { Alert } from "../../../components/common";
import { ConfirmAdmin, SettingsForm } from "../../../components/settings";
import { go } from "../../../navigation";
import type { User } from "../../../types";

const list = (text: string, offset = 0) => {
	const params = new URLSearchParams();
	if (text) params.set("q", text);
	if (offset) params.set("offset", String(offset));
	const search = params.toString();
	return `/admin/users${search ? `?${search}` : ""}`;
};

// the search text, page, and open account all live in the address, so reload
// and back/forward return to the same place.
export function Users({
	user,
	selected,
	query,
}: {
	user: User;
	selected?: string;
	query?: URLSearchParams;
}) {
	const q = query?.get("q") || "";
	const offset = Math.max(0, Math.floor(Number(query?.get("offset")) || 0));
	const resource = useResource<{ users: Account[]; total: number; limit: number }>(
		list(q, offset),
		true,
	);
	const [term, setTerm] = useState(q);
	// what this box last wrote to the address; anything else came from navigation
	const sent = useRef(q);
	useEffect(() => {
		if (q === sent.current) return;
		sent.current = q;
		setTerm(q);
	}, [q]);
	useEffect(() => {
		const text = term.trim();
		if (text === sent.current) return;
		const timer = setTimeout(() => {
			sent.current = text;
			go(list(text), true);
		}, 250);
		return () => clearTimeout(timer);
	}, [term]);
	const users = resource.value?.users ?? [];
	const total = resource.value?.total ?? 0;
	const limit = resource.value?.limit ?? 50;
	const suffix = list(q, offset).slice("/admin/users".length);
	return (
		<>
			<p className="muted">
				The first account founded the instance and cannot be demoted or disabled. Owners
				can add or remove other owners. Administrators manage account access and instance
				policy.
			</p>
			<label className="usersearch">
				Find an account
				<input
					type="search"
					value={term}
					onChange={(event) => setTerm(event.target.value)}
					placeholder="Name, username, or email"
					maxLength={100}
				/>
			</label>
			<Alert>{resource.error}</Alert>
			{resource.value && (
				<p className="muted usercount" role="status">
					{users.length === 0
						? q
							? `No accounts match “${q}”.`
							: "No accounts on this page."
						: `${offset + 1}–${offset + users.length} of ${total} ${total === 1 ? "account" : "accounts"}`}
				</p>
			)}
			{users.map((target) => (
				<div className="panel userdetails userentry" key={target.id}>
					<details>
						<summary>
							{target.name}{" "}
							<span className="muted">
								@{target.username}
								{role(target) && ` · ${role(target)}`}
								{target.disabled ? " · disabled" : ""}
							</span>
						</summary>
						<SettingsForm
							label="Update account access"
							onSave={async (values) => {
								await send(`/admin/users/${target.id}`, values, "PATCH");
								resource.reload();
								window.dispatchEvent(new Event("flurry:settings"));
							}}
						>
							{/* keyed on the saved value so a box follows what the server decided */}
							{user.owner && (
								<label className="check">
									<input
										key={`owner${target.owner}`}
										name="owner"
										type="checkbox"
										defaultChecked={target.owner}
										disabled={target.founder || target.id === user.id}
									/>
									Owner
								</label>
							)}
							<label className="check">
								<input
									key={`admin${target.admin}`}
									name="admin"
									type="checkbox"
									defaultChecked={target.admin}
									disabled={target.owner}
								/>
								Administrator
							</label>
							<label className="check">
								<input
									key={`disabled${target.disabled}`}
									name="disabled"
									type="checkbox"
									defaultChecked={target.disabled}
									disabled={target.owner || target.id === user.id}
								/>
								Disable sign-in and revoke this user’s sessions and tokens
							</label>
							{target.owner && !target.founder && (
								<small className="muted">
									Owners are always administrators. An owner removes owner access before
									this account can be demoted or disabled.
								</small>
							)}
							<ConfirmAdmin user={user} />
						</SettingsForm>
					</details>
					<a
						className="userview"
						href={`/admin/users/${target.id}${suffix}`}
						aria-label={`View details for @${target.username}`}
					>
						View details
					</a>
				</div>
			))}
			{total > limit && (
				<div className="row userpager">
					<button
						disabled={offset === 0}
						onClick={() => go(list(q, Math.max(0, offset - limit)))}
					>
						Previous
					</button>
					<button
						disabled={offset + limit >= total}
						onClick={() => go(list(q, offset + limit))}
					>
						Next
					</button>
				</div>
			)}
			{selected && (
				<Detail key={selected} id={selected} close={() => go(list(q, offset))} />
			)}
		</>
	);
}
