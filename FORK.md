# Modified distribution

This is a modified distribution of iCoreTech Codex Pooler 0.7.1, forked from
https://github.com/icoretech/codex-pooler at
`b2d025c7430faab3fdb1ef503b5ba701536bd9f8`. Upstream history, copyright and
Elastic License 2.0 (`LICENSE.md`) are retained. This fork is maintained at
https://github.com/korkin25/codex-pooler and is not an upstream release.

Version series `0.7.1-kk.N` carries the following bounded changes:

- The admin quota view projects raw source observations separately from the
  routing selector. Conflicting reports for windows that have not elapsed show
  `sources differ`, both values, source, observed time, reset time and actual
  freshness. Ordinary growth between ordered samples retains the selected
  meter; decreases before either reported reset and different values at equal
  or unknown observation times are uncertain. Known reset timestamps must differ
  by more than 60 seconds to replace the countdown with a separate warning.
  This UI tolerance accommodates rounding and collection delay without changing
  raw timestamps or identifying quota cycles. Missing resets stay explicit in
  details. The selected routing value is explicitly identified. No value is
  declared the true remaining allowance based solely on a later future reset.
- Account quotas are labelled Account Weekly; additional Spark/Reserve
  meters retain their separate identity. `normal_model_slug` is persisted in
  metadata and displayed without altering routing identity or availability.
- From `0.7.1-kk.2`, the existing authorized `/metrics` response also exposes
  native gauges for every non-deleted enrolled account, including paused,
  disabled, unassigned and never-success accounts. A bounded read-only database
  snapshot reports inventory, pool memberships, retained source observations,
  utilization, resets, freshness, conflicts and collector coverage. Opaque
  internal identities and closed label vocabularies keep credentials, emails,
  aliases and raw provider/model descriptors out of exposition. Scrapes never
  load account secrets, refresh OAuth, poll providers, enqueue work, call models,
  switch accounts or redeem credits. Missing data remains unknown; inactive
  accounts' retained observations can become stale. See the native metrics
  contract in `docs-site/src/content/docs/operators/monitoring.mdx`.
- The scheduler's default selection behavior, routing telemetry, freshness TTL,
  account state and writes remain upstream-compatible. Metrics reuse the same
  selector with routing telemetry disabled only for read-only evaluation. The
  fork changes evidence display and export, not account selection policy or
  the provider's actual quota. Source conflicts never become a combined
  available-capacity total.

The selector still uses its upstream reset-margin heuristic for routing. A UI
warning does not disable an account. Elapsed observations remain inspectable but
no longer create a current-window conflict. Missing measurements are unknown;
zero use remains 100% remaining. Freshness is evaluated at the snapshot time.
Only persisted observations are available: this patch does not add a history
store or reconstruct samples previously overwritten by their own source.

No database migration, OAuth enrollment, model request or account change is
needed. A normal scheduled usage refresh populates the additional metadata.
The underlying provider discrepancy is unresolved; all regression data is
synthetic. No production account identifiers or credentials are in the tests.
The metrics patch adds no database migration or refresh owner. Account metrics
and history depend on the retained provider evidence and monitoring backend;
collector success alone does not establish fresh quota for every account.

GitHub Actions runs the existing Elixir tests and formatting/compile checks, then builds the
upstream release Dockerfile with pinned base images and this notice/license in
the runtime image. The image tag combines VERSION and the full source SHA;
source/version/upstream labels and OCI provenance identify the artifact. An
existing tag must never be overwritten. Deployment pins the resulting digest
through an existing Helm chart, without upgrading chart/dependencies.

Local verification uses Elixir 1.20.2/OTP 28 and a disposable PostgreSQL 18 with
`MIX_ENV=test`. `mix test` resets only the configured synthetic test database.
