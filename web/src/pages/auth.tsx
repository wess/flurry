import { useState } from "react";
import { KeyRound } from "lucide-react";
import { send, useAction } from "../api";
import { Alert } from "../components/common";
import { signInWithPasskey } from "../passkeys";
import type { User } from "../types";

export function AuthPage({
	signup,
	ready,
	registration,
	signedIn,
}: {
	signup: boolean;
	ready: boolean;
	registration?: boolean;
	signedIn: (user: User) => void;
}) {
	const [values, setValues] = useState({
		name: "",
		username: "",
		email: "",
		login: "",
		password: "",
		code: "",
	});
	const action = useAction();
	const passkeyAction = useAction();
	if (signup && ready && registration === false)
		return (
			<section className="authpage">
				<h1>Registration is closed</h1>
				<p>Contact this instance’s administrator for access.</p>
				<a href="/login">Sign in</a>
			</section>
		);
	return (
		<section className="authpage">
			<h1>{signup ? "Create your account" : "Sign in to Flurry"}</h1>
			<p className="muted">
				{signup
					? "A home for your code and the changes ahead."
					: "Your repositories, right where you left them."}
			</p>
			{!signup && (
				<>
					<button
						type="button"
						className="passkeysignin"
						disabled={passkeyAction.busy}
						onClick={() => void passkeyAction.run(async () => {
							const result = await signInWithPasskey();
							signedIn(result.user);
						})}
					>
						<KeyRound size={16} /> {passkeyAction.busy ? "Waiting for passkey…" : "Sign in with a passkey"}
					</button>
					<Alert>{passkeyAction.error}</Alert>
					<div className="authdivider"><span>or use your password</span></div>
				</>
			)}
			<form
				className="panel form"
				onSubmit={(event) => {
					event.preventDefault();
					void action.run(async () => {
						const data = await send<{ user: User }>(
							signup ? (ready ? "/signup" : "/setup") : "/login",
							values,
						);
						signedIn(data.user);
					});
				}}
			>
				{signup && (
					<>
						<label>
							Display name
							<input
								required
								maxLength={80}
								autoComplete="name"
								value={values.name}
								onChange={(e) => setValues({ ...values, name: e.target.value })}
							/>
						</label>
						<label>
							Username
							<input
								required
								maxLength={40}
								pattern="[a-z0-9][a-z0-9.]*"
								autoComplete="username"
								value={values.username}
								onChange={(e) =>
									setValues({ ...values, username: e.target.value })
								}
							/>
							<small>Lowercase letters, numbers, and dots.</small>
						</label>
					</>
				)}
				{signup ? (
					<label>
						Email
						<input
							required
							type="email"
							autoComplete="email"
							value={values.email}
							onChange={(e) => setValues({ ...values, email: e.target.value })}
						/>
					</label>
				) : (
					<label>
						Username or email
						<input
							required
							autoComplete="username"
							value={values.login}
							onChange={(e) => setValues({ ...values, login: e.target.value })}
						/>
					</label>
				)}
				<label>
					Password
					<input
						required
						type="password"
						minLength={signup ? 12 : 1}
						autoComplete={signup ? "new-password" : "current-password"}
						value={values.password}
						onChange={(e) => setValues({ ...values, password: e.target.value })}
					/>
					{signup && <small>At least 12 characters.</small>}
				</label>
				{!signup && (
					<label>
						Authenticator or recovery code{" "}
						<span className="muted">(if enabled)</span>
						<input
							autoComplete="one-time-code"
							maxLength={100}
							value={values.code}
							onChange={(e) => setValues({ ...values, code: e.target.value })}
						/>
					</label>
				)}
				<Alert>{action.error}</Alert>
				<button disabled={action.busy} className="primary">
					{action.busy ? "Please wait…" : signup ? "Create account" : "Sign in"}
				</button>
			</form>
			<p className="center">
				<a href={signup ? "/login" : "/signup"}>
					{signup
						? "Already have an account? Sign in"
						: "New here? Create an account"}
				</a>
			</p>
			{!signup && (
				<p className="center">
					<a href="/forgot-password">Forgot your password?</a>
				</p>
			)}
		</section>
	);
}
