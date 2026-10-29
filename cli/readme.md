# fsc — Flurry Source Control

A Rust command-line client for Flurry's native version-control engine. Stage and
commit offline, publish topic branches, tag revisions, merge, and send main
through review. A companion Git remote helper supports existing Git clients.

## Build and install

Requires Rust 1.89 or newer. Git interoperability also requires Git 2.40+ and a
POSIX shell for the trusted receive hook. The native client does not invoke Git.

```sh
cargo build --manifest-path cli/Cargo.toml --release
cargo install --path cli --locked
fsc --help
```

Installation provides `fsc` and `git-remote-flurry`. Put Cargo's bin directory on
PATH so Git can discover the helper. Builds are tested on macOS arm64; Linux and
Windows credential backends are selected at compile time but have not been
exercised here. The Git helper's receive hook currently targets POSIX systems.
The binaries are development builds, without release signing or notarization.

## Authenticate

The server defaults to `http://127.0.0.1:4040`. Choose another origin explicitly:

```sh
export FLURRY_URL=https://flurry.example.com
fsc auth login
fsc auth status
```

`auth login` prompts for a personal access token created in web settings. A token
with write access supports native source-control commands; repository-scoped
credentials cannot create/import repositories. `fsc auth login --email you@example.com`
uses a hidden password prompt followed by an authenticator/recovery-code prompt.
Session credentials expire after seven days; use an expiring PAT for regular CLI
work. `--token-stdin` reads a token from stdin without putting it in process args.

Saved credentials use macOS Keychain, Windows Credential Manager, or Linux's
kernel keyring. Linux persistence depends on the login/keyring lifecycle. There
is no plaintext credential-file fallback. If an OS store is unavailable, supply
`FLURRY_TOKEN` and an explicit `FLURRY_URL` together. Tokens in the environment
are never silently rebound to a server named by a working copy. The Git helper
also requires that `FLURRY_URL` match the explicit Git remote origin when using
`FLURRY_TOKEN`. `--server` overrides the server for one command. Auth commands use `FLURRY_URL` or
`--server` independently of the current checkout; select the remote instance
explicitly when managing its credentials.

`fsc auth logout` deletes the saved local credential. Remove any environment token
separately and revoke the server-side token in web settings when needed.

## Familiar workflow

Replace `REPOSITORY_UUID` with the repository ID shown by `fsc repo list` or the
web repository URL.

```sh
fsc repo list
fsc clone REPOSITORY_UUID project
cd project
fsc status
fsc switch -c feature
fsc add .
fsc diff --staged
fsc commit -m "Describe the change"
fsc push
fsc switch main
fsc merge feature
fsc push
```

Topic-branch pushes advance their remote ref atomically. `main` is protected:
its push uploads the commit chain and creates a review instead of changing main.
Use the resulting review ID:

```sh
fsc review show REVIEW_UUID
fsc review comment REVIEW_UUID -m "Ready for review"
fsc review approve REVIEW_UUID
fsc review land REVIEW_UUID
fsc pull
```

Repository policies still control who can approve/land and whether independent
approval is required. No CLI flag bypasses that policy. Further work can be
committed locally while a review is open; land the review and pull/fetch before
pushing the next series.

`fsc init NAME` creates a private remote repository for an existing local directory.
`--public` is explicit. `fsc repo create NAME` creates a remote without initializing
a directory. A fresh checkout stores the server and repository identity in
`.flurry`; native commands discover it from subdirectories.

`add` stores the exact staged bytes, so edits after staging stay unstaged.
`add -A` stages the entire selected checkout, including deletions. Root and nested
`.gitignore`/`.flurryignore` files use Git ignore patterns; already tracked files
stay tracked. Generated dependency/build directories are ignored by default when
untracked. Files outside an explicitly cloned sparse prefix are never submitted.

```sh
fsc log --oneline
fsc show HEAD
fsc diff
fsc restore --staged path
fsc restore path
fsc commit --amend -m "Correct an unpublished commit"
fsc tag v1.0
fsc tag -a v1.1 -m "Release notes"
fsc push --tags
```

`restore path` discards changes to tracked paths using the index; it preserves
untracked files. Amend applies only to unpublished local commits. Published tags
are immutable. Ref names must be portable: case aliases and file/directory prefix
collisions are rejected. `tag -d NAME` removes a local tag only; fetching can restore the
published tag. `branch -d NAME` refuses the current or unmerged branch.

`pull` fast-forwards or retains local commits that already descend from the new
remote head. Divergent histories require `fetch` then `merge origin/BRANCH`.
Merging handles disjoint files and bounded, nonoverlapping text-line edits and
records two parents. Conflicting/binary/large overlapping changes leave working
files untouched. Native interactive conflict markers, stash, rebase, cherry-pick,
and octopus merges are not implemented. Git's normal conflict-resolution workflow
is available through the companion helper.

`fsc clone REPOSITORY_UUID project --sparse lib` downloads one directory prefix.
Merging requires a full checkout. Sparse commits preserve paths outside their
prefix on the server. File/directory topology replacements during an update are
refused before writing; use a fresh clone for those changes in this version.
Native content commits do not separately track chmod-only changes; Git-imported
executable modes are retained in the Git view.

## Existing Git clients

Once the helper is installed on PATH:

```sh
git clone flurry::https://flurry.example.com/REPOSITORY_UUID project
cd project
git switch -c feature
git add .
git commit -m "Git change"
git push origin feature
git tag -a v1.0 -m "Release"
git push origin v1.0
git fetch origin
```

This uses Git's [remote-helper protocol](https://git-scm.com/docs/gitremote-helpers).
It is not ordinary HTTPS smart-Git hosting. Native Flurry commits export to stable
Git objects; imported Git commits retain exact Git IDs, author/committer metadata,
merge parents, and executable modes. Lightweight and annotated tag IDs round-trip.
Signed commit/tag bytes are retained, but Flurry does not verify their signatures.
Native UI authorship identifies the authenticated uploader.

Pushing to protected main creates a review and reports a Git rejection so Git does
not record an unlanded remote head. The error names the review. Approve and land it
in Flurry, then fetch again. Repeating the push reuses the original Git commits
and existing open review. No silent auto-approval occurs.

Push one branch or tag at a time; push the branch before its tags. Topic branches
may be deleted, while main and published tags remain permanent. Atomic multi-ref
pushes, forced ref replacement, nested annotated tags, octopus
merges, symlinks, submodules, Git LFS transfer, and SHA-256-format Git repositories
are not supported. Unsupported requests fail explicitly. The helper currently
exports at most 1,000 reachable revisions and 1,000 refs per transfer and imports
at most 100 new commits per push. An uncached native Git view traverses at most
512 ancestors per request. These are deliberate alpha bounds, not scale claims.

## Linked upstream Git providers

The existing server bridge still imports a provider's branch snapshot and pushes
landed main changes back explicitly:

```sh
fsc repo import https://git.example.com/owner/project.git --name project
fsc source status
fsc source pull
fsc source push --revision LANDED_MAIN_HASH
```

Use `--token-stdin` plus `--username` for private provider transfers. Tokens are
per-transfer and are not retained. Source status/pull/push operate inside a native
checkout. Import is asynchronous; check its status before working with its files.
This snapshot bridge is separate from the lossless Git remote-helper history path.

## MCP server

`fsc mcp` is a local stdio MCP server. It exposes bounded tools for repositories,
reviews, activity, file previews, and search. It opens no listening socket and
does not accept an arbitrary API path, shell command, or filesystem path.

Authenticate first, preferably with an expiring, repository-scoped read token:

```sh
fsc --server https://flurry.example.com auth login --token-stdin
fsc --server https://flurry.example.com mcp
```

Use the absolute `fsc` path and those arguments in the MCP client's server
configuration. Standard input and output are reserved for JSON-RPC messages;
startup and protocol failures go to standard error.

The default tool set is read-only. `mcp --allow-writes` adds bounded review
operations: a general comment, an immutable evaluation attempt, requesting and
completing a structured review run, publishing a finding, and independently
verifying a finding. It does not expose approval, landing, finding disposition,
deletion, account administration, source credentials, or arbitrary repository
mutation. Flurry still applies the token's
expiry, read/write scope, optional repository restriction, account role, and
repository policy to every request.

Protocol input is limited to 1 MiB per message and tool results to 2 MiB. File
reads use the server's 20 KiB preview. Tool names and API routes are fixed, UUIDs
and repository paths are validated before network access, redirects and ambient
proxies remain disabled, and errors are bounded, escaped, and credential-redacted.
Repository files, diffs, comments, and other user-authored values are marked as
untrusted data in tool results.

## Safety and resource limits

The native CLI has no daemon, background polling, async runtime, or repository
hooks. It streams file hashing and upload encoding through 64 KiB buffers and
shares immutable in-memory snapshots. Requests reuse one blocking HTTP agent;
redirects and ambient proxies are disabled. HTTPS certificate validation stays on;
HTTP is permitted only on loopback. Requests have global/connect/read deadlines
and bounded headers/bodies. Credentials are omitted from output and server error
messages are redacted and escaped for the terminal.

Working-copy access uses capability-relative directory handles and rejects
symlinks, traversal, reserved metadata paths, nonregular files, and case/Unicode
aliases. Updates use synced temporary files, atomic renames, a nonblocking OS
working-copy lock, and a durable recovery journal. Untracked collisions and edits
seen during update/recovery stop the operation. The CLI lock coordinates CLI
commands; it cannot lock out an external editor, so avoid editing the same path
during an update. `fsc recover` completes an interrupted update offline without
silently discarding unexpected edits.

Push payloads and request IDs are saved before transmission. A lost response is
retried with the identical payload and server receipt. `fsc push --abort` checks
that receipt under the server's ref lock: it cancels a confirmed unaccepted push,
or reconciles an already accepted push. Local commits are preserved. After a
rejected oversized unpublished commit, abort the pending request, fix/stage the
file, amend the local commit, and push again.

Current client ceilings are 100 MiB per file, 1 GiB per checkout/cache, 100,000
files, 200,000 scanned entries, 64 directory levels, 32 MiB metadata/JSON responses,
100 changed paths per commit, and 140 MiB per push payload. Instance file-size limits
can be smaller. Text diff/merge work is bounded by 40 KiB and 2,000 combined lines.
`fsc gc` removes unreferenced cached blobs; it does not rewrite published history.
Snapshots retained for local history count toward metadata/cache limits; use a
fresh clone when those bounds are reached. Working-copy file creation is private
on Unix; existing file permissions are preserved when replacing files.

The Git helper uses an isolated temporary bare repository, direct streamed loose
object encoding, cached blob mappings, and a persistent Git batch reader. It
suppresses inherited Git configuration/hooks and limits pack input to 256 MiB,
pack threads to one, and pack-window/cache memory. Git itself still consumes
resources while serving the transfer. Its temporary mirror is reconstructed for
each transfer; large-history performance remains future work.

## Validation

```sh
cargo fmt --manifest-path cli/Cargo.toml --check
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path cli/Cargo.toml
cargo audit --file cli/Cargo.lock
cargo build --manifest-path cli/Cargo.toml
cd web
bun run test
```

Rust tests cover path/alias rejection, symlink escape attempts, concurrent command
locks, interrupted updates, preservation of unexpected edits, ignore rules,
three-way merges, redirects, credential redaction, malformed responses, and
identical retries after a lost push response. The optional native credential-store
test is run separately on machines with an available OS store. Browser-driven
integration tests use the isolated `flurrye2e` database and real CLI/Git processes.

A macOS arm64 release fixture measured about 7 MiB peak resident memory and 0.7–1.0 s
for status on one 100 MiB file, and about 18 MiB/0.5–0.8 s for 10,000 small files. A
100 MiB push to a loopback streaming fixture used about 10 MiB peak memory and
1.3 s. These measure client behavior on a local warm filesystem, not production
server throughput or cross-platform performance. Reproduce on macOS with
`python3 cli/scripts/bench.py`; results go to `artifacts/cli/performance.json`.
