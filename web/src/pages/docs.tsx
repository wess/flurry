import { Check, Copy, ExternalLink } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { snippetOrigin } from "../navigation";
import { docsTopics, endpointGroups } from "./docs-data";

const lines = (...value: string[]) => value.join("\n");
const instanceUrl = window.location.origin;

function CodeBlock({ children, label = "Example" }: { children: string; label?: string }) {
	const [copied, setCopied] = useState(false);
	const copy = async () => {
		await navigator.clipboard.writeText(children);
		setCopied(true);
		window.setTimeout(() => setCopied(false), 1400);
	};
	return (
		<div className="docscode">
			<div className="docscodebar">
				<span>{label}</span>
				<button type="button" onClick={() => void copy()} aria-label="Copy code">
					{copied ? <Check size={14} /> : <Copy size={14} />}
					{copied ? "Copied" : "Copy"}
				</button>
			</div>
			<pre tabIndex={0}>
				<code>{children}</code>
			</pre>
		</div>
	);
}

function Callout({ title, children }: { title: string; children: ReactNode }) {
	return (
		<aside className="docscallout">
			<strong>{title}</strong>
			<div>{children}</div>
		</aside>
	);
}

function PageHeader({ title, children }: { title: string; children: ReactNode }) {
	return (
		<header className="docsheading">
			<h1>{title}</h1>
			<p>{children}</p>
		</header>
	);
}

function Overview() {
	return (
		<>
			<PageHeader title="Build with Flurry">
				Use Flurry in the browser, through Git, with the native <code>fsc</code> client, over HTTP,
				or from an MCP-capable development tool. Every path reaches the same repository history and
				review policy.
			</PageHeader>
			<section>
				<h2>Pick a path</h2>
				<div className="docspaths">
					<a href="/docs/getting-started">
						<strong>Start in the browser</strong>
						<span>Create or import a repository, invite collaborators, and review work.</span>
					</a>
					<a href="/docs/git">
						<strong>Use Git</strong>
						<span>Clone, fetch, branch, and push with standard HTTPS Git transport.</span>
					</a>
					<a href="/docs/fsc">
						<strong>Work with fsc</strong>
						<span>Stage and commit offline, then publish immutable revisions.</span>
					</a>
					<a href="/docs/snippets">
						<strong>Share a snippet</strong>
						<span>Publish a small multi-file sample with revisions, forks, raw URLs, and syntax highlighting.</span>
					</a>
					<a href="/docs/api">
						<strong>Build an integration</strong>
						<span>Use scoped tokens, JSON endpoints, idempotency, statuses, and webhooks.</span>
					</a>
					<a href="/docs/mcp">
						<strong>Connect an agent</strong>
						<span>Expose a bounded local stdio tool surface with read-only defaults.</span>
					</a>
					<a href="/docs/security">
						<strong>Harden an integration</strong>
						<span>Keep credentials narrow, verify deliveries, and handle untrusted content.</span>
					</a>
				</div>
			</section>
			<section>
				<h2>The model in one minute</h2>
				<p>
					Flurry stores immutable changesets and content-addressed files. A submitted change opens a
					review; it does not quietly move <code>main</code>. Landing rechecks access, approvals,
					required status contexts, protected paths, and the current head before advancing the
					branch atomically.
				</p>
				<ol className="docssteps">
					<li>
						<strong>Work locally.</strong>
						<span>Edit, build, test, and experiment without a server round trip.</span>
					</li>
					<li>
						<strong>Publish a revision.</strong>
						<span>
							Git or fsc sends objects and an explicit parent; API submissions can use an
							idempotency key.
						</span>
					</li>
					<li>
						<strong>Record evidence.</strong>
						<span>
							People review the diff while external systems publish current statuses and immutable
							evaluation attempts.
						</span>
					</li>
					<li>
						<strong>Land deliberately.</strong>
						<span>Flurry advances shared history only after policy succeeds.</span>
					</li>
				</ol>
			</section>
			<Callout title="What Flurry does not run">
				Flurry does not execute repository code. Builds, tests, deployments, and agents run in
				infrastructure you control and report bounded results back.
			</Callout>
		</>
	);
}

function GettingStarted() {
	return (
		<>
			<PageHeader title="Getting started">
				Create a repository, publish work, and land the first reviewed change.
			</PageHeader>
			<section>
				<h2>1. Create your account</h2>
				<p>
					Choose <a href="/signup">Create account</a>. On a new self-hosted instance, the first
					account becomes the instance owner. Verify your email so recovery remains available, then
					add passkeys and an authenticator under <strong>Settings → Authentication</strong>.
				</p>
			</section>
			<section>
				<h2>2. Create or import a repository</h2>
				<p>
					Choose <strong>New repository</strong>, select a personal or organization owner, enter a
					lowercase name, and choose visibility. You can initialize a README, ignore rules, and an
					Apache 2.0 license, or leave the project empty. To bring existing work, choose{" "}
					<strong>Import a repository</strong>.
				</p>
				<Callout title="Public imports need no connection">
					Paste an allowed HTTPS clone URL. Connect a source account only when you need to browse
					private repositories or perform later authenticated transfers.
				</Callout>
			</section>
			<section>
				<h2>3. Clone and publish</h2>
				<CodeBlock label="Git">
					{lines(
						`git clone ${instanceUrl}/repositories/REPOSITORY_ID.git`,
						"cd project",
						"git switch -c feature/first-change",
						"# edit files",
						"git add .",
						'git commit -m "Document the project"',
						"git push -u origin feature/first-change",
					)}
				</CodeBlock>
				<p>
					A topic branch can advance directly when repository policy permits it. Pushing protected{" "}
					<code>main</code> creates a review instead of reporting an unlanded commit as the remote
					head.
				</p>
			</section>
			<section>
				<h2>4. Review and land</h2>
				<p>
					Open <strong>Reviews</strong>, inspect the revision-anchored diff, leave comments, request
					reviewers, and record a decision. When approvals and required checks pass, choose{" "}
					<strong>Land change</strong>. Fetch or pull after landing before starting the next series
					on <code>main</code>.
				</p>
			</section>
		</>
	);
}

function Repositories() {
	return (
		<>
			<PageHeader title="Repositories">
				Repository identity, visibility, import, collaboration, lifecycle, and retained storage.
			</PageHeader>
			<section>
				<h2>Create a project</h2>
				<p>
					Repository names use lowercase letters, numbers, and periods, begin with a letter or
					number, and are unique under their owner. Repositories are private by default unless your
					preference or instance policy says otherwise.
				</p>
				<CodeBlock label="API">
					{lines(
						`curl --fail-with-body ${instanceUrl}/api/repositories \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  --data \'{"name":"weather.service","description":"Forecast service","visibility":"private"}\'',
					)}
				</CodeBlock>
				<p>
					A repository-scoped token cannot create repositories. Use a write token that covers all
					accessible repositories or create the repository in the browser.
				</p>
			</section>
			<section>
				<h2>Import and linked sources</h2>
				<p>
					Imports run asynchronously and preserve reachable history for the selected branch. Pull
					compares the upstream snapshot with the last shared snapshot and opens a review for
					compatible incoming work. Push exports one selected, landed <code>main</code> revision
					using an exact commit lease; concurrent upstream changes are rejected instead of
					overwritten.
				</p>
				<CodeBlock label="Public import">
					{lines(
						`curl --fail-with-body ${instanceUrl}/api/imports \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  --data \'{"url":"https://example.net/acme/weather.git","branch":"main","name":"weather","visibility":"private"}\'',
					)}
				</CodeBlock>
			</section>
			<section>
				<h2>Ownership and lifecycle</h2>
				<ul>
					<li>
						<strong>Collaborators</strong> receive read, write, maintain, or owner-level
						capabilities according to repository policy.
					</li>
					<li>
						<strong>Organizations and teams</strong> provide reusable membership and repository
						grants. Organization members can be members, administrators, or owners; team
						members can be members or maintainers.
					</li>
					<li>
						<strong>Agent accounts</strong> give each automated worker its own identity and
						expiring credential. Agents receive access only through collaborator or team grants.
					</li>
					<li>
						<strong>Transfer</strong> requires an explicit request and acceptance; it does not
						silently change ownership.
					</li>
					<li>
						<strong>Archive</strong> makes a project read-only. <strong>Remove</strong> hides it
						until an owner restores it from settings.
					</li>
				</ul>
			</section>
			<section>
				<h2>Storage accounting</h2>
				<p>
					Instance administrators can set a maximum file size and optional per-project and
					per-account retained-storage limits. Public and private repository counts are unlimited.
					Limits apply uniformly, including to organization projects, and never remove existing
					history when a threshold is lowered.
				</p>
			</section>
		</>
	);
}

function GitGuide() {
	return (
		<>
			<PageHeader title="Git workflows">
				Use standard Git over HTTPS for supported repository history and Git LFS objects.
			</PageHeader>
			<section>
				<h2>Clone and authenticate</h2>
				<CodeBlock>
					{lines(
						`git clone ${instanceUrl}/repositories/REPOSITORY_ID.git`,
						"# username: your Flurry username",
						"# password: an expiring Flurry API token",
					)}
				</CodeBlock>
				<p>
					Public repositories can be cloned without a credential. For private access, use an
					expiring token as the HTTPS password. A read token can clone and fetch; a write token plus
					repository access is required to push.
				</p>
			</section>
			<section>
				<h2>Branch and push</h2>
				<CodeBlock>
					{lines(
						"git switch -c feature/search",
						"git add .",
						'git commit -m "Add repository search"',
						"git push -u origin feature/search",
						"",
						"# pushing main opens a review when main is protected",
						"git switch main",
						"git push origin main",
					)}
				</CodeBlock>
				<p>
					Push one branch or tag at a time. Topic branches may be deleted, while published tags and{" "}
					<code>main</code> are permanent. Forced ref replacement and atomic multi-ref pushes are
					refused explicitly.
				</p>
			</section>
			<section>
				<h2>Supported history</h2>
				<p>
					Flurry preserves supported commit and annotated-tag identities, author and committer
					metadata, merge parents, signed bytes, and executable modes. It supports ordinary commits
					and two-parent merges. Symlinks, submodules, octopus merges, nested annotated tags,
					SHA-256 Git repositories, and replacing published tags are not supported.
				</p>
			</section>
			<section>
				<h2>Git LFS</h2>
				<p>
					The HTTPS endpoint supports LFS batch transfer, upload/download, locks, lock verification,
					and unlock. LFS objects count toward storage and file-size limits. Keep your remote URL in
					the form shown on the repository page so Git discovers <code>/info/lfs</code> correctly.
				</p>
			</section>
		</>
	);
}

function FscGuide() {
	return (
		<>
			<PageHeader title="The fsc client">
				Stage exact bytes, commit without a network connection, and work with Flurry reviews
				directly.
			</PageHeader>
			<Callout title="Current distribution status">
				The client is a development build. Build it from the Flurry source tree with Rust 1.89 or
				newer; signed public installers are not published yet.
			</Callout>
			<section>
				<h2>Build and authenticate</h2>
				<CodeBlock>
					{lines(
						"cargo install --path cli --locked",
						`export FLURRY_URL=${instanceUrl}`,
						"",
						"# create an expiring token in Settings → Access tokens, then:",
						"printf '%s' \"$FLURRY_TOKEN\" | fsc auth login --token-stdin",
						"fsc auth status",
					)}
				</CodeBlock>
				<p>
					Saved credentials use the operating system credential store. There is no plaintext
					credential-file fallback. You may provide <code>FLURRY_TOKEN</code> and{" "}
					<code>FLURRY_URL</code> together for ephemeral environments.
				</p>
			</section>
			<section>
				<h2>Daily workflow</h2>
				<CodeBlock>
					{lines(
						"fsc repo list",
						"fsc clone REPOSITORY_ID project",
						"cd project",
						"fsc switch -c feature",
						"fsc add .",
						"fsc diff --staged",
						'fsc commit -m "Describe the change"',
						"fsc push",
						"",
						"fsc review list",
						"fsc review show REVIEW_ID",
						'fsc review comment REVIEW_ID -m "Ready for review"',
						"fsc review approve REVIEW_ID",
						"fsc review land REVIEW_ID",
						"fsc pull",
					)}
				</CodeBlock>
			</section>
			<section>
				<h2>Working-copy guarantees</h2>
				<ul>
					<li>
						<code>fsc add</code> snapshots exact staged bytes; later edits remain unstaged.
					</li>
					<li>
						Root and nested <code>.gitignore</code> and <code>.flurryignore</code> files use Git
						ignore patterns.
					</li>
					<li>
						Updates reject symlinks, traversal, reserved paths, unsafe aliases, and untracked
						collisions.
					</li>
					<li>
						Temporary files, atomic renames, a working-copy lock, and a durable journal protect
						updates.
					</li>
					<li>
						<code>fsc recover</code> finishes an interrupted update without discarding unexpected
						edits.
					</li>
				</ul>
			</section>
			<section>
				<h2>Merge and sparse boundaries</h2>
				<p>
					Native merge handles disjoint files and bounded, non-overlapping text edits. Conflicts
					leave working files untouched. Sparse clones preserve paths outside the selected prefix,
					but merging requires a full checkout. Stash, rebase, cherry-pick, interactive conflict
					markers, and octopus merges are not native client features in this release.
				</p>
			</section>
		</>
	);
}

function ReviewsGuide() {
	return (
		<>
			<PageHeader title="Reviews and policy">
				A review points to an immutable revision, so the diff being approved cannot change
				underneath a reviewer.
			</PageHeader>
			<section>
				<h2>Submit a changeset</h2>
				<CodeBlock label="API">
					{lines(
						`curl --fail-with-body ${instanceUrl}/api/repositories/$REPOSITORY/changesets \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  -H "Idempotency-Key: build-1842-publish" \\',
						'  --data \'{"base":"CURRENT_MAIN_SHA256_OR_NULL","message":"Document the API","files":[{"path":"docs/api.md","content":"# API\\n"},{"path":"old.txt","content":null}]}\'',
					)}
				</CodeBlock>
				<p>
					Every submission names its base explicitly; use JSON <code>null</code> only for an empty
					repository. A file accepts UTF-8 <code>content</code>, Base64 <code>base64</code>, or{" "}
					<code>content: null</code> for deletion. One request changes at most 100 paths. Reusing an
					idempotency key with the same payload returns the original result; a different payload
					returns <code>409</code>.
				</p>
			</section>
			<section>
				<h2>Decisions and revisions</h2>
				<p>
					Comments remain anchored to the review record. Approval and change-request decisions apply
					to the current revision. Moving a review to another changeset invalidates stale decisions,
					ensuring reviewers approve the exact work that may land.
				</p>
			</section>
			<section>
				<h2>Landing checks</h2>
				<ul>
					<li>Actor still has permission to land.</li>
					<li>Required approval count and independent-review rules are satisfied.</li>
					<li>Code owners and protected-path rules are satisfied.</li>
					<li>Required status contexts report success.</li>
					<li>The repository is writable and the current head is compatible.</li>
				</ul>
				<p>
					A compatible stale change is rebased into a new immutable changeset that retains its
					reviewed source. A conflict leaves <code>main</code> unchanged.
				</p>
			</section>
		</>
	);
}

function AutomationGuide() {
	return (
		<>
			<PageHeader title="Automation">
				Run work in your own environment and publish bounded, inspectable evidence to a revision.
			</PageHeader>
			<section>
				<h2>Current statuses</h2>
				<p>
					A status context answers “what is the latest result?” Updating the same context replaces
					its current state. Repository policy can require named contexts before landing.
				</p>
				<CodeBlock>
					{lines(
						"curl --fail-with-body -X PUT \\",
						`  ${instanceUrl}/api/repositories/$REPOSITORY/changesets/$REVISION/statuses \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  --data \'{"context":"ci/tests","state":"success","description":"428 tests passed","target_url":"https://ci.example.net/runs/1842"}\'',
					)}
				</CodeBlock>
				<p>
					States are <code>pending</code>, <code>success</code>, <code>failure</code>, or{" "}
					<code>error</code>. Target URLs must use HTTPS.
				</p>
			</section>
			<section>
				<h2>Structured automated review</h2>
				<p>
					A review run requests one or more specialists for an exact revision. External workers
					analyze code in their own environment and publish bounded findings; Flurry stores the
					request, evidence, identity, and disposition history without executing repository code.
				</p>
				<ul>
					<li>Findings use stable fingerprints so they can carry forward across revisions.</li>
					<li>A different authenticated account must verify a finding.</li>
					<li>Only a human maintainer can resolve, dismiss, or reopen one.</li>
					<li>Completing a comprehensive run records findings not reproduced on the new revision without impersonating a human disposition.</li>
					<li>An optional status context reports failure only for open, verified, introduced blocker or high-severity findings.</li>
				</ul>
				<CodeBlock label="Request a run and publish a finding">
					{lines(
						'RUN=$(curl --fail-with-body -X POST \\',
						`  ${instanceUrl}/api/repositories/$REPOSITORY/reviews/$REVIEW/runs \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						`  --data '{"profiles":["correctness","security"],"status_context":"review/findings"}' | jq -r .id)`,
						"",
						'curl --fail-with-body -X POST \\',
						`  ${instanceUrl}/api/repositories/$REPOSITORY/reviews/$REVIEW/runs/$RUN/findings \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						`  --data '{"fingerprint":"ownership:account-lookup","category":"security","severity":"high","classification":"introduced","title":"Account lookup does not enforce ownership","body":"The changed lookup accepts an unscoped identifier.","evidence":"The changed call path reaches the store without an ownership predicate.","path":"lib/account.ex","side":"after","line":2}'`,
					)}
				</CodeBlock>
				<p>
					Use a different authenticated account to POST <code>verified</code> to the finding
					action endpoint. Complete the run with <code>state: completed</code> and set{" "}
					<code>reconcile: true</code> only when the worker inspected the complete requested
					profile set for that revision.
				</p>
				<Callout title="Evidence, not hidden reasoning">
					Publish a concise reproduction, failing invariant, or observed call path. Do not store raw
					model reasoning, prompts, credentials, or unrelated repository content as finding evidence.
				</Callout>
			</section>
			<section>
				<h2>Immutable evaluations</h2>
				<p>
					An evaluation answers “what happened over time?” Each POST appends a new attempt rather
					than overwriting an earlier result.
				</p>
				<CodeBlock>
					{lines(
						"curl --fail-with-body \\",
						`  ${instanceUrl}/api/repositories/$REPOSITORY/changesets/$REVISION/evaluations \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  --data \'{"context":"quality/unit","state":"success","summary":"Unit suite passed","score":1,"pass":428,"fail":0,"duration_ms":18420,"metrics":{"coverage":91.4},"external_id":"run-1842","target_url":"https://ci.example.net/runs/1842"}\'',
					)}
				</CodeBlock>
				<p>
					Metadata is limited to 16 KiB and rejects keys that look like credentials, secrets,
					tokens, passwords, or prompts. Store only durable result metadata, never logs or
					credentials.
				</p>
			</section>
			<section>
				<h2>Signed webhooks</h2>
				<p>
					Create a webhook with an HTTPS URL and an event list, or <code>["*"]</code>. The creation
					response returns a secret once. Deliveries include the event, repository, normalized
					payload, delivery ID, timestamp, and HMAC signature.
				</p>
				<CodeBlock label="Signature verification">
					{lines(
						'expected = hex(hmac_sha256(secret, timestamp + "." + raw_body))',
						"provided = X-Flurry-Signature  # sha256= + expected",
						"",
						"# reject stale timestamps, compare in constant time,",
						"# and deduplicate on X-Flurry-Delivery",
					)}
				</CodeBlock>
				<p>
					Flurry retries bounded failures with backoff and records delivery state, response status,
					and a bounded response excerpt for inspection.
				</p>
			</section>
		</>
	);
}

function SnippetsGuide() {
	return (
		<>
			<PageHeader title="Snippets">
				Share small pieces of code on the <a href={snippetOrigin()}>snippet surface</a>{" "}
				without turning them into full repositories.
			</PageHeader>
			<section>
				<h2>Create and share</h2>
				<p>
					A snippet contains one to twenty UTF-8 files. Each file may be up to 256 KiB and the
					complete snippet may be up to 1 MiB. Choose public visibility for discovery, unlisted
					for a durable link, or private for your account only.
				</p>
				<ul>
					<li>Updates append immutable revisions instead of rewriting old files.</li>
					<li>Raw file URLs can be used by scripts and command-line tools.</li>
					<li>Forking creates an unlisted copy with its origin recorded.</li>
					<li>Syntax highlighting follows file names and never executes snippet content.</li>
				</ul>
			</section>
			<section>
				<h2>API example</h2>
				<CodeBlock>
					{lines(
						`curl --fail-with-body ${instanceUrl}/api/snippets \\`,
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Content-Type: application/json" \\',
						'  --data \'{"title":"Request verifier","visibility":"unlisted","files":[{"name":"request.ts","content":"export const verify = () => true;\\n"}]}\'',
					)}
				</CodeBlock>
				<p>
					Use an unrestricted write token for snippet automation. Repository-restricted tokens
					cannot access snippets. Public and unlisted reads require no credential; private reads
					require the owning account.
				</p>
			</section>
		</>
	);
}

function McpGuide() {
	return (
		<>
			<PageHeader title="MCP server">
				Connect MCP-capable development tools to a fixed, bounded Flurry tool surface over local
				stdio.
			</PageHeader>
			<section>
				<h2>Configure a client</h2>
				<p>
					Create a short-lived, repository-scoped read token in <strong>Settings → Access tokens</strong>,
					save it with <code>fsc auth login --token-stdin</code>, then point the client at the
					absolute executable path.
				</p>
				<CodeBlock label="MCP client configuration">
					{lines(
						"{",
						'  "mcpServers": {',
						'    "flurry": {',
						'      "command": "/absolute/path/to/fsc",',
						`      "args": ["--server", "${instanceUrl}", "mcp"]`,
						"    }",
						"  }",
						"}",
					)}
				</CodeBlock>
			</section>
			<section>
				<h2>Read-only tools</h2>
				<div className="docstablewrap">
					<table>
						<thead>
							<tr>
								<th>Tool</th>
								<th>Purpose</th>
							</tr>
						</thead>
						<tbody>
							<tr>
								<td>
									<code>list_repositories</code>
								</td>
								<td>List repositories visible to the token.</td>
							</tr>
							<tr>
								<td>
									<code>get_repository</code>
								</td>
								<td>Read metadata, policy, role, and current main revision.</td>
							</tr>
							<tr>
								<td>
									<code>list_reviews</code>
								</td>
								<td>List recent reviews for one repository.</td>
							</tr>
							<tr>
								<td>
									<code>get_review</code>
								</td>
								<td>Read a bounded diff, decisions, comments, provenance, evaluations, review runs, and findings.</td>
							</tr>
							<tr>
								<td>
									<code>repository_activity</code>
								</td>
								<td>Read the authorized repository timeline.</td>
							</tr>
							<tr>
								<td>
									<code>read_file</code>
								</td>
								<td>Read a bounded 20 KiB file preview at a revision.</td>
							</tr>
							<tr>
								<td>
									<code>search_repository</code>
								</td>
								<td>Search bounded source text or repository paths.</td>
							</tr>
						</tbody>
					</table>
				</div>
			</section>
			<section>
				<h2>Optional additive writes</h2>
				<p>
					Start <code>fsc mcp --allow-writes</code> only when the client needs additive review
					operations. Alongside comments and evaluations, tools can request a review run, publish
					structured findings, independently verify them, and complete the run. The flag does not add
					approval, landing, deletion, settings, credentials, or arbitrary repository mutation.
					Server-side token scope and repository policy still apply.
				</p>
			</section>
			<section>
				<h2>Trust boundary</h2>
				<ul>
					<li>
						The server opens no listening socket and accepts no shell command, arbitrary API path,
						or filesystem path.
					</li>
					<li>Requests are limited to 1 MiB and results to 2 MiB.</li>
					<li>Redirects and ambient proxies are disabled; remote servers require HTTPS.</li>
					<li>
						Repository files, diffs, comments, and other user-authored values are returned as
						untrusted data, not instructions.
					</li>
				</ul>
			</section>
		</>
	);
}

function ApiGuide() {
	return (
		<>
			<PageHeader title="HTTP API">
				Build repository, review, collaboration, and automation integrations against the same
				policy-enforced surface used by Flurry clients.
			</PageHeader>
			<div className="docsactions">
				<a className="button primary" href="/openapi.json">
					Download OpenAPI 3.1
				</a>
				<a className="button" href={`${instanceUrl}/api/health`}>
					Check API health <ExternalLink size={14} />
				</a>
			</div>
			<section>
				<h2>Base URL and authentication</h2>
				<CodeBlock>
					{lines(
						`BASE_URL=${instanceUrl}/api`,
						'curl --fail-with-body "$BASE_URL/repositories" \\',
						'  -H "Authorization: Bearer $FLURRY_TOKEN" \\',
						'  -H "Accept: application/json"',
					)}
				</CodeBlock>
				<p>
					Create tokens in <strong>Settings → Access tokens</strong>. A token begins with <code>flr_</code>
					, is shown once, expires in 1–365 days, and has read or write access. It may be restricted
					to one repository. Browser session cookies are HTTP-only, SameSite Strict, and intended
					for the same-origin web app—not external integrations.
				</p>
				<Callout title="Token boundary">
					API tokens can read repositories and perform permitted code and review automation. They
					cannot manage account or instance settings, source connections, repository lifecycle, or
					collaborators. Those operations require a browser session.
				</Callout>
				<p>
					For a durable automated identity, create an agent under <strong>Settings → Agent
					accounts</strong>. Its one-time <code>fla_</code> credential can perform assigned
					repository work, but cannot sign in to the browser, create repositories, or manage
					settings and permissions. Rotate or revoke it from the owning user’s settings.
				</p>
			</section>
			<section>
				<h2>Requests and responses</h2>
				<ul>
					<li>
						Send JSON objects with <code>Content-Type: application/json</code>.
					</li>
					<li>
						Most JSON request bodies are limited to 1 MiB. Changeset and push limits expand to
						bounded server ceilings under the instance file-size and retained-storage policy.
					</li>
					<li>
						JSON responses use <code>Cache-Control: no-store</code>.
					</li>
					<li>
						Successful creation generally returns <code>201</code>; asynchronous imports and source
						transfers return <code>202</code>.
					</li>
					<li>
						Authenticated API traffic is limited per account. A <code>429</code> response means
						retry after a short delay with jitter.
					</li>
				</ul>
				<CodeBlock label="Error response">
					{lines("{", '  "error": "Human-readable problem",', '  "details": null', "}")}
				</CodeBlock>
				<p>
					Handle <code>400</code> validation failures, <code>401</code> missing or invalid
					credentials, <code>403</code> policy failures, <code>404</code> unavailable resources,{" "}
					<code>409</code> state conflicts, <code>413</code> file-size or payload limits, and{" "}
					<code>429</code> rate limiting. Do not branch on the prose message.
				</p>
			</section>
			<section>
				<h2>Idempotency and concurrency</h2>
				<p>
					Supply one <code>Idempotency-Key</code> header when submitting a changeset. Persist the
					key with your job before sending the request and reuse it after an ambiguous timeout.
					Source pushes also require the exact currently landed head, and native client pushes
					expose durable request receipts.
				</p>
			</section>
			<section>
				<h2>Endpoint reference</h2>
				<p>
					Paths below are relative to <code>{instanceUrl}/api</code>. The downloadable specification
					contains common parameters, schemas, security declarations, and examples for integration
					tooling.
				</p>
				{endpointGroups.map(([name, access, endpoints]) => (
					<details className="docsendpoints" key={name}>
						<summary>
							<span>{name}</span>
							<small>
								{endpoints.length} endpoints · {access}
							</small>
						</summary>
						<div className="docstablewrap">
							<table>
								<tbody>
									{endpoints.map(([method = "GET", path = "", description = ""]) => (
										<tr key={`${method}:${path}`}>
											<td>
												<span className={`method method-${method.toLowerCase()}`}>{method}</span>
											</td>
											<td>
												<code>{path}</code>
											</td>
											<td>{description}</td>
										</tr>
									))}
								</tbody>
							</table>
						</div>
					</details>
				))}
			</section>
		</>
	);
}

function SecurityGuide() {
	return (
		<>
			<PageHeader title="Security for clients and integrations">
				Protect account access, use narrow authority, and treat source-controlled content as
				untrusted input.
			</PageHeader>
			<section>
				<h2>Account authentication</h2>
				<p>
					Passkeys provide passwordless sign-in with device-based user verification. Add at least
					two under <strong>Settings → Authentication</strong> so losing one device does not remove
					access. Flurry also supports password sign-in with time-based authenticator codes and
					single-use recovery codes.
				</p>
				<ul>
					<li>Passkey enrollment requires the current password and the active second factor.</li>
					<li>Every passkey challenge expires after five minutes and can be used only once.</li>
					<li>Passkey sign-in requires local user verification, such as a device PIN or biometric.</li>
					<li>Removing a passkey revokes existing sessions and access tokens.</li>
				</ul>
			</section>
			<section>
				<h2>Credential checklist</h2>
				<ul>
					<li>Create a separate token for every integration and environment.</li>
					<li>Prefer read-only access; add write only for a named workflow.</li>
					<li>Restrict the token to one repository whenever possible.</li>
					<li>Choose the shortest practical expiry and rotate before it lapses.</li>
					<li>
						Store tokens in a secret manager or operating-system credential store, never a
						repository, URL, log, or MCP configuration.
					</li>
					<li>Revoke a credential immediately when a machine, job, or integration is retired.</li>
				</ul>
			</section>
			<section>
				<h2>Content is data, not instruction</h2>
				<p>
					Repository files, diffs, issue text, review comments, webhook payload fields, and search
					results are user-authored. Escape them for their destination, never evaluate them as code,
					and do not let instructions found in repository content expand an agent’s permissions or
					tool surface.
				</p>
			</section>
			<section>
				<h2>Webhook verification</h2>
				<ol>
					<li>Read the raw request body before JSON parsing.</li>
					<li>Reject timestamps outside your allowed clock-skew window.</li>
					<li>
						Compute HMAC-SHA256 over <code>timestamp + "." + raw_body</code> using the one-time
						secret.
					</li>
					<li>
						Compare the resulting <code>sha256=…</code> value in constant time.
					</li>
					<li>
						Deduplicate on <code>X-Flurry-Delivery</code> before producing side effects.
					</li>
				</ol>
			</section>
			<section>
				<h2>Transport and browser boundary</h2>
				<p>
					Use HTTPS for remote servers and retain certificate validation. Non-browser clients should
					omit <code>Origin</code>; Flurry rejects cross-origin and cross-site writes to protect
					browser sessions. Do not call authenticated write endpoints directly from another web
					origin—place that integration behind your own server and use a scoped bearer token.
				</p>
			</section>
			<Callout title="Report a vulnerability">
				Send security reports privately to{" "}
				<a href="mailto:me@wess.io?subject=Flurry%20security">me@wess.io</a> with affected behavior,
				reproduction steps, and impact. Do not include live credentials.
			</Callout>
		</>
	);
}

const pages: Record<string, () => ReactNode> = {
	overview: Overview,
	"getting-started": GettingStarted,
	repositories: Repositories,
	git: GitGuide,
	fsc: FscGuide,
	reviews: ReviewsGuide,
	snippets: SnippetsGuide,
	automation: AutomationGuide,
	mcp: McpGuide,
	api: ApiGuide,
	security: SecurityGuide,
};

export function Docs({ topic = "overview" }: { topic?: string }) {
	const active = docsTopics.some(([slug]) => slug === topic) ? topic : "overview";
	const Page = pages[active]!;
	const current = docsTopics.find(([slug]) => slug === active)!;
	useEffect(() => {
		window.scrollTo(0, 0);
	}, [active]);
	return (
		<div className="docs">
			<aside className="docsnav">
				<a className="docsnavtitle" href="/docs">
					Flurry documentation
				</a>
				<nav aria-label="Documentation">
					{docsTopics.map(([slug, label]) => (
						<a
							key={slug}
							className={slug === active ? "active" : ""}
							href={slug === "overview" ? "/docs" : `/docs/${slug}`}
						>
							{label}
						</a>
					))}
				</nav>
				<div className="docsnavmeta">
					<a href="/openapi.json">OpenAPI 3.1</a>
					<a href="/llms.txt">llms.txt</a>
				</div>
			</aside>
			<article className="docscontent">
				<Page />
			</article>
			<aside className="docsonthispage" aria-label="Documentation section">
				<strong>{current[1]}</strong>
				<p>{current[2]}</p>
				<a href="/docs/api">API reference</a>
				<a href="/docs/security">Security guidance</a>
			</aside>
		</div>
	);
}
