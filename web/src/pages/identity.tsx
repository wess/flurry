import { useState } from "react";
import { send, useAction, useResource } from "../api";
import { Alert, Empty } from "../components/common";
import { date } from "../navigation";
import type { User } from "../types";

export function ResetRequest() {
	const [email, setEmail] = useState("");
	const [sent, setSent] = useState(false);
	const action = useAction();
	return (
		<section className="authpage">
			<h1>Reset your password</h1>
			<p className="muted">
				We’ll send a one-hour recovery link if the address belongs to an
				account.
			</p>
			{sent ? (
				<div className="panel">
					<p>Check your email for the recovery link.</p>
					<a href="/login">Return to sign in</a>
				</div>
			) : (
				<form
					className="panel form"
					onSubmit={(event) => {
						event.preventDefault();
						void action.run(async () => {
							await send("/password/reset-request", { email });
							setSent(true);
						});
					}}
				>
					<label>
						Email
						<input
							required
							type="email"
							autoComplete="email"
							value={email}
							onChange={(event) => setEmail(event.target.value)}
						/>
					</label>
					<Alert>{action.error}</Alert>
					<button className="primary" disabled={action.busy}>
						Send recovery link
					</button>
				</form>
			)}
		</section>
	);
}

export function ResetPassword({ token }: { token: string }) {
	const [password, setPassword] = useState("");
	const [complete, setComplete] = useState(false);
	const action = useAction();
	return (
		<section className="authpage">
			<h1>Choose a new password</h1>
			{complete ? (
				<div className="panel">
					<p>
						Your password has been changed and existing sessions were signed
						out.
					</p>
					<a href="/login">Sign in</a>
				</div>
			) : (
				<form
					className="panel form"
					onSubmit={(event) => {
						event.preventDefault();
						void action.run(async () => {
							await send("/password/reset", { token, password });
							setComplete(true);
						});
					}}
				>
					<label>
						New password
						<input
							required
							type="password"
							minLength={12}
							autoComplete="new-password"
							value={password}
							onChange={(event) => setPassword(event.target.value)}
						/>
						<small>At least 12 characters.</small>
					</label>
					<Alert>
						{action.error ||
							(!token ? "This recovery link is incomplete." : "")}
					</Alert>
					<button className="primary" disabled={action.busy || !token}>
						Change password
					</button>
				</form>
			)}
		</section>
	);
}

export function VerifyEmail({
	token,
	verified,
}: {
	token: string;
	verified: (user: User) => void;
}) {
	const [complete, setComplete] = useState(false);
	const action = useAction();
	return (
		<section className="authpage">
			<h1>Verify your email</h1>
			<div className="panel form">
				{complete ? (
					<p>Your email address is verified.</p>
				) : (
					<p>Confirm this address for account recovery and notifications.</p>
				)}
				<Alert>
					{action.error ||
						(!token ? "This verification link is incomplete." : "")}
				</Alert>
				{!complete && (
					<button
						className="primary"
						disabled={action.busy || !token}
						onClick={() =>
							void action.run(async () => {
								const result = await send<{ user: User }>("/email/verify", {
									token,
								});
								verified(result.user);
								setComplete(true);
							})
						}
					>
						Verify email
					</button>
				)}
				{complete && <a href="/">Continue to repositories</a>}
			</div>
		</section>
	);
}

type Notice = {
	id: string;
	title: string;
	body: string;
	url?: string;
	read_at?: string;
	inserted_at: string;
	actor?: { name: string; username: string };
};

export function Notifications() {
	const resource = useResource<{ notifications: Notice[]; unread: number }>(
		"/notifications",
	);
	const action = useAction();
	if (resource.loading) return <p>Loading notifications…</p>;
	return (
		<section>
			<div className="pageheading row">
				<div className="grow">
					<h1>Notifications</h1>
					<p className="muted">{resource.value?.unread || 0} unread</p>
				</div>
				<button
					disabled={action.busy || !resource.value?.unread}
					onClick={() =>
						void action.run(async () => {
							await send("/notifications/read-all");
							resource.reload();
						})
					}
				>
					Mark all read
				</button>
			</div>
			<Alert>{resource.error || action.error}</Alert>
			{!resource.value?.notifications.length ? (
				<Empty title="You’re all caught up">
					Repository activity addressed to you will appear here.
				</Empty>
			) : (
				<div className="panel notificationlist">
					{resource.value.notifications.map((notice) => (
						<article
							key={notice.id}
							className={notice.read_at ? "notification read" : "notification"}
						>
							<div className="grow">
								<h2>
									{notice.url ? (
										<a href={notice.url}>{notice.title}</a>
									) : (
										notice.title
									)}
								</h2>
								{notice.body && <p>{notice.body}</p>}
								<small className="muted">
									{notice.actor ? `${notice.actor.name} · ` : ""}
									{date(notice.inserted_at)}
								</small>
							</div>
							{!notice.read_at && (
								<button
									className="small"
									onClick={() =>
										void action.run(async () => {
											await send(`/notifications/${notice.id}/read`);
											resource.reload();
										})
									}
								>
									Mark read
								</button>
							)}
						</article>
					))}
				</div>
			)}
		</section>
	);
}
