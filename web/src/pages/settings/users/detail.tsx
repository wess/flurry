import type { ReactNode } from "react";
import { useEffect, useId, useRef } from "react";
import { X } from "lucide-react";
import { role, size } from "./account";
import type { AccountDetail } from "./account";
import { useResource } from "../../../api";
import { Alert } from "../../../components/common";
import { dateTime, profilePath } from "../../../navigation";

// read-only account record for administrators. the server never selects
// credentials or authenticator material into it, so there is nothing to hide here.
export function Detail({ id, close }: { id: string; close: () => void }) {
	const dialog = useRef<HTMLDialogElement>(null);
	const title = useId();
	const resource = useResource<{ user: AccountDetail }>(`/admin/users/${id}`);
	useEffect(() => {
		const node = dialog.current;
		node?.showModal();
		// closing before removal hands focus back to the link that opened it
		return () => node?.close();
	}, []);
	const account = resource.value?.user;
	return (
		<dialog
			ref={dialog}
			className="userdialog"
			aria-labelledby={title}
			onCancel={close}
			onClick={(event) => {
				const box = event.currentTarget.getBoundingClientRect();
				const outside =
					event.clientX < box.left ||
					event.clientX > box.right ||
					event.clientY < box.top ||
					event.clientY > box.bottom;
				if (outside) close();
			}}
		>
			<div className="dialogheading">
				<h2 id={title}>{account ? account.name : "Account details"}</h2>
				<button className="iconbutton" aria-label="Close" onClick={close}>
					<X size={18} />
				</button>
			</div>
			<Alert>{resource.error}</Alert>
			{!account && !resource.error && <p className="muted">Loading account…</p>}
			{account && (
				<>
					<p className="muted">
						@{account.username} · <a href={profilePath(account.username)}>Open profile</a>
					</p>
					<h3>Account</h3>
					<dl className="userfacts">
						<Fact label="Email">
							{account.email}{" "}
							<span className="badge">
								{account.email_verified ? "verified" : "not verified"}
							</span>
						</Fact>
						<Fact label="Role">{capital(role(account) || "member")}</Fact>
						<Fact label="Status">{account.disabled ? "Sign-in disabled" : "Active"}</Fact>
						<Fact label="Account type">
							{account.account_type === "agent" ? "Agent" : "Person"}
						</Fact>
						<Fact label="Joined">{dateTime(account.joined_at)}</Fact>
						<Fact label="Account ID">
							<code>{account.id}</code>
						</Fact>
					</dl>
					<h3>Sign-in security</h3>
					<dl className="userfacts">
						<Fact label="Two-factor authentication">
							{account.two_factor ? "On" : "Off"}
						</Fact>
						<Fact label="Passkeys">{account.passkeys}</Fact>
						<Fact label="Active sessions">{account.sessions}</Fact>
						<Fact label="Access tokens">{account.tokens}</Fact>
					</dl>
					<h3>Usage</h3>
					<dl className="userfacts">
						<Fact label="Repositories">{account.repositories}</Fact>
						<Fact label="Storage used">{size(account.storage_bytes)}</Fact>
					</dl>
					<h3>Profile</h3>
					<dl className="userfacts">
						<Fact label="Visibility">{account.private_profile ? "Private" : "Public"}</Fact>
						<Fact label="Activity">{account.hide_activity ? "Hidden" : "Shown"}</Fact>
						{account.location && <Fact label="Location">{account.location}</Fact>}
						{account.website && <Fact label="Website">{account.website}</Fact>}
						{account.bio && <Fact label="Bio">{account.bio}</Fact>}
					</dl>
				</>
			)}
		</dialog>
	);
}

const capital = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

function Fact({ label, children }: { label: string; children: ReactNode }) {
	return (
		<div>
			<dt>{label}</dt>
			<dd>{children}</dd>
		</div>
	);
}
