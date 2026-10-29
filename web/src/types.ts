export type User = {
	id: string;
	username: string;
	name: string;
	bio: string;
	location: string;
	website: string;
	joined_at: string;
	account_type?: "human" | "agent";
	email?: string;
	email_verified?: boolean;
	admin?: boolean;
	owner?: boolean;
	private_profile?: boolean;
	hide_activity?: boolean;
	two_factor?: boolean;
	preferences?: {
		theme?: string;
		default_visibility?: string;
		wrap_code?: boolean;
	};
};
export type Site = {
	name: string;
	registration: boolean;
	require_signin: boolean;
	allow_public: boolean;
	default_visibility: string;
	ssh_port?: number | null;
};
export type Session = { ready: boolean; user: User | null; site?: Site };
export type Passkey = {
	id: string;
	name: string;
	transports: string[];
	backed_up: boolean;
	last_used_at: string | null;
	inserted_at: string;
};
export type Repository = {
	id: string;
	name: string;
	description: string;
	visibility: "public" | "private";
	owner: Pick<User, "id" | "name" | "username">;
	head: string | null;
	inserted_at: string;
	archived?: boolean;
	allow_self_approval?: boolean;
	review_trigger?: "manual" | "review_opened" | "every_revision";
	review_profiles?: string[];
	review_status_context?: string | null;
	role?: "owner" | "read" | "write" | "maintain" | null;
};
export type Change = {
	id: string;
	parent: string | null;
	source: string | null;
	author: { id: string; name: string };
	message: string;
	files: number;
	inserted_at: string;
};
export type FileContent = {
	encoding: "utf8" | "base64";
	truncated?: boolean;
	content: string;
	size: number;
	path: string;
	hash: string;
	revision: string;
};
export type Diff = {
	path: string;
	kind: string;
	before: FileContent | null;
	after: FileContent | null;
	lines: { kind: "eq" | "ins" | "del"; text: string }[] | null;
	symbols?: {
		language: string;
		changed: { name: string; kind: string; line: number; change: string }[];
	} | null;
};

export type AutomationProvenance = {
	id: string;
	changeset_id: string;
	actor: { id: string; name: string };
	name: string;
	version: string | null;
	trigger: string;
	base_revision: string | null;
	external_id: string | null;
	metadata: Record<string, unknown>;
	inserted_at: string;
};

export type Evaluation = {
	id: string;
	changeset_id: string;
	creator: { id: string; name: string };
	context: string;
	state: "success" | "failure" | "error";
	summary: string;
	score: number | null;
	pass: number;
	fail: number;
	duration_ms: number | null;
	metrics: Record<string, unknown>;
	target_url: string | null;
	external_id: string | null;
	inserted_at: string;
};

export type ReviewRun = {
	id: string;
	review_id: string;
	revision: string;
	creator: Pick<User, "id" | "name" | "username" | "account_type">;
	trigger: "manual" | "review_opened" | "revision";
	profiles: string[];
	state: "requested" | "running" | "completed" | "failed" | "cancelled";
	summary: string;
	status_context: string | null;
	external_id: string | null;
	started_at: string | null;
	completed_at: string | null;
	inserted_at: string;
	updated_at: string;
};

export type ReviewFindingEvent = {
	id: string;
	action: "verified" | "resolved" | "dismissed" | "reopened" | "superseded" | "not_reproduced";
	note: string;
	revision: string;
	actor: Pick<User, "id" | "name" | "username" | "account_type">;
	inserted_at: string;
};

export type ReviewFinding = {
	id: string;
	run_id: string;
	revision: string;
	current: boolean;
	reporter: Pick<User, "id" | "name" | "username" | "account_type">;
	fingerprint: string;
	category: string;
	severity: "blocker" | "high" | "medium" | "low" | "info";
	classification: "introduced" | "preexisting";
	title: string;
	body: string;
	evidence: string;
	path: string | null;
	side: "before" | "after" | null;
	line: number | null;
	verified: boolean;
	state: "open" | "resolved" | "dismissed" | "superseded" | "not_reproduced";
	events: ReviewFindingEvent[];
	inserted_at: string;
};

export type ActivityEvent = {
	id: string;
	type: string;
	title: string;
	detail: string;
	inserted_at: string;
	actor: { id: string; name: string } | null;
	changeset_id: string | null;
	review_id: string | null;
	state: string | null;
};
export type Review = {
	id: string;
	status: "open" | "approved" | "landed";
	changeset: Change;
	landed_id: string | null;
	inserted_at: string;
	updated_at: string;
};
export type ReviewDetail = Review & {
	diff: Diff[];
	comments: { id: string; author: string; body: string; inserted_at: string }[];
	automation: AutomationProvenance | null;
	evaluations: Evaluation[];
	review_intelligence: { runs: ReviewRun[]; findings: ReviewFinding[] };
};
export type Profile = User & {
	repositories: Repository[];
	activity: {
		id: string;
		message: string;
		repository_id: string;
		inserted_at: string;
	}[];
};
export type Tree = {
	revision: string | null;
	path: string;
	entries: { name: string; type: "tree" | "blob"; hash: string }[];
};

export type Source = {
	url: string;
	branch: string | null;
	status: "ready" | "running" | "failed";
	operation: "import" | "pull" | "push" | null;
	error: string | null;
	message: string | null;
	commit: string | null;
	review_id: string | null;
	synced_at: string | null;
	connection_id: string | null;
};
export type SourceProvider = { id: string; name: string; host: string };
export type SourceConnection = {
	id: string;
	provider: string;
	host: string;
	account: string;
	expires_at: string | null;
	inserted_at: string;
};
export type SourceRepository = {
	id: string;
	name: string;
	full_name: string;
	description: string;
	url: string;
	branch: string | null;
	private: boolean;
};
export type AuditEvent = {
	id: number;
	event: string;
	inserted_at: string;
	details: Record<string, unknown>;
};
export type InstanceSettings = Site & {
	git_hosts: string[];
	git_hosts_locked: boolean;
	limits: {
		file_bytes: number;
		project_storage_bytes: number;
		account_storage_bytes: number;
	};
	diagnostics: {
		version: string;
		git_available: boolean;
		secure_cookies: boolean;
		two_factor_available: boolean;
		mail_configured: boolean;
		oauth_configured: boolean;
		ssh_hosting: boolean;
		ci_available: boolean;
		storage: string;
		backup: string;
	};
};

export type SnippetFile = {
	id: string;
	name: string;
	content: string;
	bytes: number;
};

export type SnippetRevision = {
	id: string;
	version: number;
	message: string;
	inserted_at: string;
	author?: Pick<User, "id" | "name" | "username">;
};

export type Snippet = {
	id: string;
	slug: string;
	title: string;
	description: string;
	visibility: "public" | "unlisted" | "private";
	version: number;
	author: Pick<User, "id" | "name" | "username">;
	owner: boolean;
	starred: boolean;
	stars: number;
	inserted_at: string;
	updated_at: string;
	files?: SnippetFile[];
	revision?: SnippetRevision;
	revisions?: SnippetRevision[];
	forked_from?: string | null;
};
