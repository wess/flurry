# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Flurry serves individual developers and software teams that need to host Git
repositories, review changes, and manage projects from a browser and standard
Git tooling. Instance owners also manage registration, access, storage policy,
service health, and recovery.

## Product Purpose

Flurry is a Git-compatible source-code management product. It provides dependable
repository hosting, review and collaboration workflows, project records, account
security, automation endpoints, and operational controls in one product. Success
means users can bring an existing Git project in, collaborate on changes, and
retrieve the same supported Git history through ordinary tools.

## Positioning

Flurry pairs standard Git transport with a native immutable changeset model. Git
repositories remain interoperable while reviews, policies, receipts, recovery,
and repository state are explicit product records rather than hidden side effects.

## Operating Context

Users work through HTTPS Git clone, fetch, and push; the `fsc` working-copy tool;
the local `fsc mcp` server; and the Flurry web interface. Common workflows include
importing a repository, submitting and reviewing changes, landing approved work, managing collaborators
and organizations, publishing releases, sharing versioned snippets, and connecting external automation through
signed webhooks, commit statuses, immutable evaluations, and bounded automation
provenance. Production runs at `flurry.codes`.
The hosted snippet surface runs at `snip.flurry.codes` and shares the account session.

## Capabilities and Constraints

The verified P0–P2 baseline is maintained in `docs/capabilities.md`. Important
boundaries include no hosted build runners, package registry, container registry,
enterprise directory provisioning, automatic upstream mirroring,
automatic unreachable-object collection, symlinks, submodules, octopus merges,
SHA-256 Git object format, or atomic multi-ref pushes. Production currently exposes
HTTPS Git transport; SSH hosting is implemented but not publicly exposed.

Flurry is the complete self-hosted product. Instances allow unlimited public and
private repositories. Administrators can configure uniform maximum-file, per-project,
and per-account retained-storage limits as operational safety controls.

## Brand Commitments

The product name is Flurry. Product language should be direct, calm, technically
precise, and self-contained. Public copy describes Flurry on its own terms and
does not frame it through other companies or products. The established mark is a
snowflake and the established line is “Source control, kept simple.”

## Evidence on Hand

- `docs/capabilities.md` records the implemented capability baseline and deliberate boundaries.
- `docs/architecture.md` records storage, consistency, security, and recovery behavior.
- `docs/settings.md` records account, administration, and storage-limit behavior.
- `web/tests/` exercises the principal browser workflows.
- `test/flurry/` exercises the engine, security, Git, collaboration, and quota contracts.

There are no approved customer testimonials, adoption metrics, or performance
benchmarks. Future public surfaces must not invent them.

## Product Principles

- Preserve Git interoperability for every behavior Flurry claims to support.
- Make repository state and consequential operations explicit, inspectable, and recoverable.
- Keep the source-hosting core self-contained and independently operable.
- Prefer bounded, authenticated, auditable operations over implicit automation.
- Keep source work local-first: clients may compute and experiment offline, while the
  server coordinates only the shared state collaborators must agree on.
- Derive documentation URLs and examples from the current instance origin.
- Make clear that each independent instance operator owns its service terms, privacy
  policy, infrastructure choices, and data-handling obligations.
- Keep endpoint references usable on narrow screens by stacking each endpoint's method,
  path, and description instead of requiring horizontal scrolling.
- Honor the system color-scheme preference on public surfaces when no account preference
  is available.
- State unsupported formats and post-baseline extensions plainly.

## Accessibility & Inclusion

The web product supports keyboard focus, reduced-motion preferences, responsive
layouts, semantic headings and navigation, and readable light/dark preferences.
New work must preserve those behaviors and keep core workflows usable without a
pointing device.
