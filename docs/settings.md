# Settings and administration

Flurry keeps account, repository, and instance administration separate. Each
surface exposes only controls that the instance can enforce end to end.

## Available controls

| Area | Available now |
| --- | --- |
| Public profile | Name, bio, location, website, repositories, recent activity; email stays private |
| Account | Change email/password with current password; revoke old sessions and tokens |
| Authentication | Password login, passwordless passkeys, verified email, password recovery, authenticator TOTP, single-use recovery codes |
| Sessions | Inspect sessions, revoke one or all other sessions |
| API access | Expiring read/write tokens, optionally restricted to one repository; revoke tokens |
| Agent accounts | Separate non-interactive identities with expiring one-time credentials and explicit repository or team membership |
| Preferences | Light/dark/system appearance, code wrapping, default visibility |
| Privacy | Private profile and hidden activity |
| Repository | Name, description, visibility, collaborator roles, policy, lifecycle, and linked sources |
| Organizations | Member, administrator, and owner roles; organization-owned repositories |
| Teams | Member and maintainer roles with reusable read, write, or maintain repository grants |
| Integrations | Signed webhooks, status contexts, immutable evaluations, and automation provenance |
| Automated review | Manual, review-opened, or every-revision requests; specialist profiles; optional policy status |
| Notifications | Durable inbox for review, issue, assignment, and transfer activity |
| Instance | Name, registration, sign-in and public-repository policy, allowed Git hosts, storage limits |
| Administration | Account access, additional administrators, audit log, service health, and usage counts |

The first successful signup owns the instance. An advisory lock serializes
initial registration. The owner identity persists separately from the
administrator flag and cannot be disabled or demoted through administration.
Other administrators can manage account access and instance policy.

Browser sessions are required for account, repository, and instance settings.
Sensitive changes require the current password and a second factor when enabled.
API tokens cannot administer these areas. Audit records exclude passwords,
tokens, authenticator secrets, and recovery codes.

Passkeys are discoverable WebAuthn credentials with required local user
verification. Enrollment requires the current password and active authenticator
factor, when configured. Challenges expire after five minutes, are deleted before
verification, and cannot be replayed. Flurry stores only the credential identifier,
public key, signature counter, backup state, and user-supplied name. Removing a
passkey rotates sessions and API tokens immediately.

## Agent accounts and teams

An agent account is an identity for one automated worker, not a human login or
a general account token. Create one under **Settings → Agent accounts**. Flurry
shows its `fla_` credential once and stores only its digest. Credentials expire
in 1–365 days; rotation invalidates the previous credential immediately.

Agents cannot create repositories, change repository settings, manage members,
configure sources, transfer ownership, or open browser settings. Their access
comes only from a direct collaborator grant or organization team membership.
Revocation disables the identity and removes its collaborator, organization,
and team memberships while retaining authorship on existing work.

Organization owners and administrators manage organization membership, create
teams, and grant repository access. A team maintainer may add, update, and
remove members of that team, but cannot change repository grants. Agent accounts
may be organization and team members, but never administrators, owners, or team
maintainers. Repository grants remain `read`, `write`, or `maintain`.

## Identity recovery

TOTP requires `FLURRY_SECRET_KEY`, a base64-encoded random 32-byte encryption
key. Keep the same key across restarts and back it up separately from the
database. Recovery codes are shown once, stored hashed, and can be replaced after
fresh password and authenticator confirmation. Verification links
expire after 24 hours; password recovery links expire after one hour, are
single-use, and revoke existing sessions.

Configure the documented mail API or `FLURRY_SENDMAIL_PATH` for delivery. Without
delivery, messages remain in the durable queue. A server operator can recover
access with `mix flurry.user`; passwords are read from `FLURRY_PASSWORD`, never
command-line arguments. The recovery command can explicitly remove authenticator
two-factor state with `--disabletwofactor` and registered passkeys with
`--disablepasskeys`; neither is removed implicitly.

## Storage limits

Instance administrators configure three safety limits:

- maximum bytes in one new file version;
- retained file bytes per project; and
- retained file bytes across projects owned by one account.

The per-project and per-account values may be zero for unlimited. File size must
remain positive. If both retained-storage limits are enabled, the project limit
cannot exceed the account limit, and the file limit cannot exceed an enabled
project limit.

Storage counts distinct uncompressed blob versions within each repository,
including unlanded reviews and removed repositories. Equal content stored in two
repositories counts twice. Tree metadata, database overhead, temporary transfers,
and orphaned blobs left by rejected submissions are outside the ledger. Quota
checks serialize on the repository owner’s account. Lowering a limit never deletes
history; it can block new file versions until usage is within the configured bound.

Repository counts are not limited. Removing a repository retains its history and
storage charge until a future documented garbage-collection process exists.

## Source connections

Public repositories import directly from an allowed HTTPS clone URL. Configure
the documented provider client ID and secret pairs to offer account connection
and private repository discovery. Register this callback:

```text
https://your-flurry-host/api/source-connections/callback
```

Provider configuration requires `FLURRY_PUBLIC_URL` and `FLURRY_SECRET_KEY`.
Connection tokens are encrypted at rest, never returned to the browser, and can
be disconnected by their owner.

## Git SSH hosting

Set `FLURRY_SSH_PORT` and the absolute `FLURRY_SSH_HOST_KEY_DIR` together to
start the Git-only SSH listener. The directory must contain an Ed25519 host key
named `ssh_host_ed25519_key`. The listener exposes no shell, password login,
forwarding, or file-transfer subsystem.

## Operations

`FLURRY_RATE_LIMIT` bounds sensitive unauthenticated attempts per client address
each minute. `FLURRY_API_RATE_LIMIT` bounds authenticated API requests per
account. Set `FLURRY_TRUSTED_PROXIES` to the exact proxy IPs that may supply
`X-Forwarded-For`.

Back up PostgreSQL, the complete object-store prefix, and the authenticator key.
See [storage and recovery](backups.md).
