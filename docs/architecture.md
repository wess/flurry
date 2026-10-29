# Architecture

## Boundaries

`lib/flurry/engine` owns source-control behavior. `lib/flurry/store` handles
content-addressed storage and persistent directory trees. `lib/flurry/http`
exposes the engine through Plug. Ecto schemas represent the database records.
The Atlas browser application uses those APIs and has no direct database access.

The implementation separates authoritative changed-file records from derived
structures. The directory tree is an eagerly computed,
rebuildable index, not the canonical changeset identity. This alpha uses a
graph with an optional second merge parent and first-parent history.

## Stored data

Postgres stores users, hashed sessions, repository ownership and visibility,
immutable changesets, ref heads, reviews, revision-anchored comments, decisions,
structured review runs, immutable findings and finding events,
organizations, role-based teams, agent identities, collaborators, webhook deliveries, revision statuses, immutable
evaluation attempts, bounded automation provenance, instance policy, and a
retained-blob quota ledger. A changeset includes its
repository, first parent, author, message, creation time, changed-path map, and
optional reviewed-source changeset. Its SHA-256 identity covers a versioned,
ordered JSON representation of those fields. Database triggers reject updates
or deletes to changesets. Authoritative data requires both the database and the
object directory.

Object keys are SHA-256 hashes of the object type, a NUL separator, and the raw
payload. Objects use zlib compression on disk. Files and trees have distinct hash
domains. Reads verify the full hash and expected type. Writes use a temporary
file, file sync, rename, and containing-directory sync before returning.
Interrupted submissions can leave unreferenced objects; garbage collection is
deliberately absent until reachability and retention rules are defined.

Trees contain sorted directory entries referring to child trees or file blobs.
Edits rewrite affected directory paths and share untouched subtrees. Flat,
extremely wide directories still require rewriting their entry list; a sharded
manifest format is needed before claiming repository-size-independent costs.
`manifests` maps a changeset to its root tree and can be rebuilt from the parent
and changed-path map. File object loss cannot be repaired from metadata alone.

## Submission and landing

Submission validates an explicit base and portable paths, stores file blobs, creates a
derived tree, and transactionally inserts the changeset, manifest, and review.
It does not move main. Optional idempotency keys return the original change and review for
an identical retry and reject reuse with different content.

Landing locks the review, then the repository's main ref row, in a transaction.
It requires approval and verifies that the base is on main's first-parent chain.
Each changed path is compared between the submitted base and current main.
Changed paths conflict conservatively at file granularity. Directory/file
collisions also reject the operation. Compatible changes are applied to current
main. If rebasing was necessary, a new immutable changeset records the reviewed
source ID and original author. Updating the ref and marking the review landed
commit in the same database transaction. A repeated land request returns the
recorded landing without producing a second change.

The per-ref lock serializes landing on one branch; other repositories can land
independently. Tree reads and rebasing currently happen while holding that lock.
The initial tests exercise concurrent writers through separate DB connections,
but they do not establish sustained throughput or distributed-system behavior.
Submission currently shares the main-ref lock with other repository mutations; narrowing that
critical section remains performance work.

## Access and browser behavior

Writes require a browser session, scoped API token, or explicitly authorized agent
credential, except registration and login.
Repository ownership and collaborator roles gate
mutation. Public visibility permits read access; private repositories return 404
to other users. Profile activity is filtered to
repositories visible to the viewer. Object reads go through an authorized
repository, revision, and path rather than exposing a global hash endpoint.
Snippet reads follow the same visibility rule: public and unlisted snippets are
readable by link, while private snippets resolve only for their owner. Snippet
revisions and files are immutable database records; edits append a revision.

Passwords use salted PBKDF2-HMAC-SHA256 with 210,000 iterations. Only hashes of
random session, API-token, and agent-credential digests are stored. Agent
credentials use a separate prefix and can never resolve to a browser session.
Authenticator secrets use AES-GCM encryption
with the configured server key; recovery codes are hashed. Browser cookies are HttpOnly and SameSite
Strict. A deployment may scope the cookie to a parent domain so first-party
subdomains share a session. The API also accepts bearer tokens. Authentication attempts are limited
per source IP in the running application process. Cross-origin writes are
rejected unless their exact HTTPS origin appears in the operator's allowlist.
The owner controls registration, sign-in requirements, and public-repository policy.

Passkeys use discoverable WebAuthn credentials with user verification required
for both registration and authentication. The server stores public keys and
credential identifiers, never authenticator private material. Five-minute
challenges are bound to the relying-party origin and identifier, consumed before
verification, and cannot be replayed. Opaque UUID bytes serve as user handles;
usernames and email addresses are not written into that field. Nonzero signature
counters must increase, while counterless synchronized passkeys remain supported.

Text diffs are bounded by combined bytes and line counts to avoid an unbounded
Myers diff workload. Larger or binary files use a download/view fallback.
The SPA fetches data on navigation or explicit refresh; there is no live browser event
transport yet. Outbound webhook deliveries use a persisted queue with signed requests,
bounded retries, stale-claim recovery, and dead-letter state.

## Automation and derived review context

Automation provenance is an optional immutable record attached to a submitted changeset.
It records the authenticated actor, tool name and version, trigger, external identifier,
base revision, and bounded structured metadata. Metadata keys resembling prompts, secrets,
credentials, passwords, or tokens are rejected. Provenance is deliberately outside the
changeset hash so adding integration context does not alter source identity.

Evaluation runs are append-only completed attempts tied to one repository revision. They
retain outcome, score, pass/fail counts, duration, summary, target URL, and bounded metrics.
Mutable revision statuses remain the policy-facing latest result; evaluation attempts serve
history and comparison. The repository activity endpoint derives a read model from changes,
reviews, decisions, statuses, evaluations, and finding events rather than becoming another
source of truth.

Structured review runs coordinate external specialist workers without executing repository
code on the server. Findings are immutable and revision-bound. Stable fingerprints connect
the same issue across revisions; append-only events record verification, resolution,
dismissal, reopening, and supersession. Verification requires a different authenticated
identity from the reporter, while disposition remains a human-maintainer decision. An
optional status context can translate completed, verified findings into existing landing policy.
Comprehensive runs record a separate `not_reproduced` observation instead of silently resolving
a finding on a maintainer's behalf.

Syntax summaries are computed from bounded textual review diffs. They are rebuildable hints
for declarations touched in supported languages and do not participate in changeset identity,
landing, conflict resolution, or authorization. Flurry never sends repository content to a
model and does not execute repository code to produce these summaries.

## Compute placement

Flurry uses a local-first, server-coordinated boundary. Working copies, staging,
native commits, branches, merges, ordinary diffs, builds, tests, and model-assisted
work can run on a developer machine or in separately operated automation. Those
clients publish immutable revisions and bounded result records through authenticated,
idempotent APIs. The server does not need the toolchain, model, dependency graph,
or repository execution environment that produced them.

The server remains authoritative for the state that collaborators must agree on:
accounts, authorization, repository objects, revision identity, refs, review state,
landing policy, quotas, and the retained provenance/evaluation record. Client-declared
tool names, versions, scores, and metrics are evidence attributed to the authenticated
actor; they are not independently verified by Flurry. Policy continues to use named
revision status contexts so repository owners can choose which authenticated systems
they trust.

Lightweight syntax summaries are currently computed on demand from already-bounded
review text as a fallback. They are not stored, required, or trusted for merging.
Richer parsing, embeddings, candidate generation, and repository-wide indexing belong
in clients or external workers; Flurry should accept bounded derived results when a
product workflow needs to share them, rather than requiring that computation in the
hosting process.

## MCP boundary

The native client includes a stdio MCP server. It is a local adapter over the
existing authenticated API, not another public network service. This avoids a
second HTTP authorization surface and keeps credentials in the same operating-system
store used by other native-client commands.

The MCP tool registry is fixed in the binary. Read tools cover repository metadata,
reviews, activity, bounded file previews, and bounded search. Write tools are absent
unless the process starts with `--allow-writes`; even then, the only exposed writes
append a review comment or immutable evaluation attempt. Server-side token scope,
repository restriction, role checks, and repository policy remain authoritative.

Input messages, output values, identifiers, repository paths, and text fields have
local limits before an API request is made. The adapter does not follow redirects,
honor ambient proxies, execute repository content, expose arbitrary API routes, or
place credentials in protocol output. Source, diffs, comments, and other repository
content are returned as untrusted data so MCP clients can keep data separate from
instructions.

## Backup and recovery

Repository blobs and trees are immutable content-addressed objects. Production
writes them directly to a private S3-compatible store before recording database
references; reads verify decompression, type, and SHA-256 identity. Local
development uses the same object interface with an atomic filesystem driver.

Postgres remains the recovery authority for users, repositories, refs, reviews,
instance policy, and object references. Do not delete objects merely because they are old
or absent from main: pending reviews and historical changesets may still reference
them. Restore Postgres and retain the complete object prefix before accepting
traffic. See [storage and recovery](backups.md).

## Next stages

The next engine work is scalable ancestry and path-history indexes, iterative manifest
regeneration for deep histories,
and measured contention before moving tree computation outside the ref lock.
Working-copy synchronization, full-history import, and additional repository policy should
each be separate changes with their own correctness tests.
Distributed caching and virtual filesystems follow measured need.

## Git source bridge

`lib/flurry/git` is a boundary adapter around the Git executable. The native
engine never reads Git object formats during ordinary submission or landing.
A short-lived bare repository fetches one upstream branch without a checkout.
Its reachable commits and files are converted to immutable Flurry changesets,
blobs, and directory trees without executing repository content.

`sources` stores the URL, branch, common commit/root, executable modes, transfer
state, and pending review. It contains no access tokens. Pull uses a three-way
file comparison against the common snapshot, retaining Flurry-only edits.
The common snapshot advances transactionally with landing its incoming review.

Public sources require no credentials. Reusable account connections live in a
separate owner-scoped table. Access and refresh tokens are encrypted with
AES-GCM using connection identity as authenticated context; API responses expose
only provider, host, account, and expiry metadata. OAuth state values are random,
single-use, stored only as digests, and expire after ten minutes. Generic allowed
hosts can store the same encrypted credential shape without provider discovery.

Push captures the owner-selected main revision before the task starts. It exports
that exact tree into Git and creates a child of the common Git commit. Both a
preflight check and an explicit `--force-with-lease=refs/heads/branch:expected`
guard the update. Despite the Git option's name, the exported commit is always a
child of the expected upstream commit, so a successful push preserves history.
A push intent (commit/root/modes) is saved before the external update; retries can
recognize an accepted commit after a lost response. A remote advancing further
after an ambiguous push can require manual conflict resolution on pull. There is
no distributed transaction between Postgres and an external Git server.

Git runs with isolated config, no inherited helpers, TLS verification, disabled
redirects and other transports, and DNS pinned to public addresses on allowed
hosts. Commands have bounded output, time, and temporary storage. Repository
content is never checked out or executed. Temporary bare repositories are removed
after each operation. Decrypted and one-time credentials exist only in the
worker's memory and child environment, never in command arguments, repository
config, logs, API responses, or persisted errors.
Local Git fixtures test import/pull/push, racing writes, and lost-response recovery.

## Storage limits

Each repository owner account is locked when recording new retained file versions,
serializing quota checks across that owner’s projects. The ledger charges unique
blob hashes per repository, including immutable review and removed history. It can
be rebuilt from retained changeset deltas. Metadata, orphan objects, and physical
object-store overhead are outside the count.

Administrators configure one file-size ceiling and optional per-project and
per-account retained-storage ceilings. Zero means unlimited retained storage.
Lowering a ceiling blocks excess writes while preserving authorized reads and
history. See [settings](settings.md) for validation and accounting details.

## Native CLI, branches, and Git compatibility

Native `fsc` stages immutable blob snapshots and creates local commits offline.
A push transaction verifies the expected branch head, authenticates ownership or
write membership, inserts a bounded topological commit series, and records an
idempotent receipt. Topic refs advance directly; main creates a series review.
A series review compares its original base with its complete tip, including all
commits. Landing can fast-forward the whole series or rebase its aggregate delta
with provenance and a second parent. Independent approval checks all new authors.
Ancestry traverses both parent edges with a bounded breadth-first walk. Tags are
immutable and can carry an annotation. Git-tag annotations preserve their raw
object and identity when imported.

`git-remote-flurry` uses Git's connect helper capability and an isolated temporary
bare repository. A trusted pre-receive hook translates one ref update, and only
acknowledges an accepted topic ref. A protected-main update creates a review and
returns a rejection; the Git client never records an unlanded remote head.
Original Git commit objects and file modes are stored alongside native history;
the server validates their object, tree, and parent identities. These original
interop records are authoritative for lossless Git IDs, so retain `gitcommits`
and annotated-tag rows in database backups. Generated Git views and `gitblobs`
hash caches can be rebuilt. Native-generated Git messages include a revision
trailer to make their identities deterministic and unambiguous.

The native filesystem store remains SHA-256-addressed. Git views use SHA-1 Git
object identities at the compatibility boundary. The helper verifies both native
blob hashes and Git identities, streams zlib object writing, reuses blob mappings,
and batches reads from the receiving Git object database. It never executes
repository code. See [CLI limits](../cli/readme.md) for current transport, history,
conflict-resolution, and platform boundaries.

The optional SSH listener authenticates registered Ed25519 account or deploy keys
through an OTP channel callback. Each accepted Git command receives an isolated
materialized bare repository and streams bytes directly between the SSH channel and
the Git process. Only upload-pack and receive-pack are accepted. The listener does
not expose a shell, passwords, forwarding, or subsystems, and applies the same
native import path and branch policy as HTTPS pushes.
