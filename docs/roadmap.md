# Roadmap

This roadmap records intended directions, not compatibility promises. Work moves
into the implemented capability list only after its behavior, security boundary,
and recovery story are tested and documented.

## Linked Flurry engines

Flurry engines should be able to link without becoming one shared trust domain.
The first version will use repository replication with a single authoritative
home for each repository rather than unrestricted multi-writer clustering.

Planned uses include:

- verified mirrors for backup, recovery, and migration
- read replicas for geographically closer clone and fetch traffic
- selective synchronization between independently operated instances
- deliberate transfer of a repository's authoritative home
- public relays that can distribute public objects without administrative access

The replication protocol should provide:

- stable instance identities and public-key verification
- protocol and capability negotiation
- repository-scoped, revocable peer credentials
- hash-based discovery and batched transfer of missing objects
- signed, replay-resistant ref updates and replication receipts
- explicit push, pull, and bidirectional policies
- observable lag, health, pause, resync, and audit state
- defined tombstone, deletion, and retention behavior

An authoritative repository remains single-writer at first. A linked engine may
accept work on a namespaced branch, but the home engine decides what lands on its
protected branches. This avoids split-brain refs, conflicting policy decisions,
and ambiguous deletion while preserving a path toward carefully bounded
federation later.

## Other planned work

- interactive native conflict resolution
- unreachable-object accounting and collection
- external identity providers
- optional hosted automation workers with an isolated trust boundary

