# Flurry capability baseline

This document records the P0–P2 product baseline. It is written in Flurry terms
and should be updated whenever a capability or boundary changes.

## P0: dependable source hosting

- Native immutable changesets, branches, tags, merge parents, portable paths, and
  content-addressed storage.
- Standard HTTPS and optional SSH clone, fetch, topic push, and topic deletion.
- Stable Git object identities for supported commits, trees, blobs, modes, and
  annotated tags.
- Repository import, explicit upstream pull/push, full selected-branch history,
  archives, comparisons, blame, path history, and code/path search.
- Streamed large-file transfer with integrity checks, quotas, authorization, and
  repository path locks.
- Private/public repositories, collaborators, organizations, teams, deploy keys,
  repository transfer, duplication, archive, removal, restore, and provenance.
- Bounded transfers, authenticated writes, idempotent submissions, recovery
  journals, audit events, and backup/restore guidance.

## P1: review and collaboration

- Review diffs, revision-anchored comments, requested reviewers, approval and
  change-request decisions, stale-decision invalidation, and protected main.
- Required approval counts, status checks, protected paths, code owners, push
  allowlists, signed changes, and multi-author review enforcement.
- Issues, comments, labels, milestones, assignees, locking, and notifications.
- Releases, assets, source archives, wiki pages, topics, stars, and watches.
- Repository pages expose files, issues, reviews, releases, wiki, history, clone
  commands, and settings without requiring API-only workflows.
- Multi-file snippets with public, unlisted, or private visibility, immutable
  revisions, raw-file links, forks, stars, and safe syntax highlighting.

## P2: identity, automation, and operations

- Username-or-email password login, stable public profile URLs, verified email,
  password recovery, passwordless discoverable passkeys, sessions, scoped tokens,
  authenticator two-factor security, recovery codes, and administrator recovery.
- Non-interactive agent identities with one-time expiring credentials, rotation,
  revocation, explicit repository/team membership, and no browser login.
- Durable in-product notifications and a durable local mail-delivery queue.
- Registered Ed25519 account/deploy SSH keys and signing keys.
- Credential-free public repository imports plus encrypted, revocable source
  connections and private repository discovery.
- Signed outbound webhooks with bounded durable retries and delivery inspection.
- Revision status contexts for external build, test, and deployment systems.
- Immutable evaluation attempts with structured metrics, bounded automation provenance,
  syntax-aware review summaries, and a repository activity timeline.
- Revision-bound specialist review runs, verified structured findings, stable cross-revision
  fingerprints, append-only disposition history, webhook dispatch, and optional status policy.
- A local stdio MCP server with fixed, bounded repository tools, read-only defaults,
  explicit additive writes, and inherited token and repository authorization.
- Instance policy, user administration, storage limits, audit logs, health
  diagnostics, storage selection, and backup configuration reporting.

## Deliberate boundaries after P2

The following are extensions, not hidden or partially enabled features:

- Passkeys, external identity providers, and enterprise directory provisioning.
- Hosted build runners. Flurry accepts external status results but does not execute
  repository code on the server.
- Package and container registries, project boards, federation, and avatar uploads.
- Automatic upstream mirroring and automatic unreachable-object collection.
- Symlinks, submodules, octopus merges, SHA-256 Git object format, atomic multi-ref
  pushes, and replacement of published tags.

These boundaries must remain explicit in the interface and documentation until a
complete, secured implementation is available.
