type Policy = "terms" | "privacy";

const policies = {
	terms: {
		title: "Instance terms",
		summary:
			"Each Flurry instance is independently operated. Its administrator is responsible for publishing the terms that apply to its users.",
		sections: [
			[
				"Operator responsibility",
				"The Flurry open-source project does not operate this instance or enter into an agreement on its administrator’s behalf. Ask the instance administrator which terms apply before creating an account or storing data.",
			],
			[
				"Your repositories and content",
				"You retain whatever rights you hold in source code and other content you submit. You are responsible for having permission to upload and share it, and for keeping an independent copy of important repository data.",
			],
			[
				"Acceptable use",
				"Do not break the law, infringe rights, distribute malware, probe systems without authorization, bypass access controls, impersonate others, or deliberately degrade the instance for other users.",
			],
			[
				"Software license",
				"The Flurry software is provided under the Apache License 2.0. That license governs the software itself; it does not create service terms between an instance operator and its users.",
			],
		],
	},
	privacy: {
		title: "Instance privacy",
		summary:
			"Flurry stores the data needed for source hosting. The administrator of this instance controls how that data is operated and retained.",
		sections: [
			[
				"Data handled by Flurry",
				"The software stores account identity and security settings, sessions, repositories, files, changes, reviews, issues, organization records, audit events, webhook deliveries, notifications, and mail-delivery state.",
			],
			[
				"Operator responsibility",
				"The Flurry open-source project does not receive data from this instance merely because it runs Flurry. The instance administrator chooses its infrastructure, email delivery, backups, retention, access policy, and any external processors.",
			],
			[
				"Cookies and security",
				"Flurry uses an HTTP-only session cookie for sign-in. Users can review sessions, revoke access tokens, manage passkeys, enable authenticator two-factor authentication, and manage recovery codes from account settings.",
			],
			[
				"Access and deletion",
				"Use the in-product controls to update profile settings, revoke credentials, change repository visibility, and remove repositories. Contact the instance administrator for requests that are not available in the product.",
			],
		],
	},
} as const;

export function Legal({ policy }: { policy: Policy }) {
	const content = policies[policy];
	const other = policy === "terms" ? "privacy" : "terms";
	return (
		<article className="legal">
			<header className="legalheading">
				<div>
					<h1>{content.title}</h1>
					<p>{content.summary}</p>
				</div>
				<nav aria-label={`${content.title} sections`}>
					<strong>On this page</strong>
					{content.sections.map(([title]) => (
						<button
							key={title}
							type="button"
							className="legallink"
							onClick={() =>
								document
									.getElementById(`${policy}-${slug(title)}`)
									?.scrollIntoView({ behavior: "smooth" })
							}
						>
							{title}
						</button>
					))}
				</nav>
			</header>
			<div className="legalbody">
				{content.sections.map(([title, body]) => (
					<section key={title} id={`${policy}-${slug(title)}`}>
						<h2>{title}</h2>
						<p>{body}</p>
					</section>
				))}
			</div>
			<p className="legalalternate">
				Also read <a href={`/${other}`}>{policies[other].title}</a>.
			</p>
		</article>
	);
}

function slug(value: string) {
	return value
		.toLowerCase()
		.replaceAll(/[^a-z0-9]+/g, "-")
		.replaceAll(/(^-|-$)/g, "");
}
