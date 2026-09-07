# Modified distribution

This is a modified distribution of iCoreTech Codex Pooler 0.7.3, forked from
https://github.com/icoretech/codex-pooler at
`8ae4595fc9d5f09eb9e185476d51d7add6180ccd`. Upstream history, copyright and
Elastic License 2.0 (`LICENSE.md`) are retained. This fork is maintained at
https://github.com/korkin25/codex-pooler and is not an upstream release.

From `0.7.3-kk.2`, draining rejects new provider HTTP admission before granting
or queueing work. Native clients receive HTTP 503 with `server_is_overloaded`;
the rejection creates no request, attempt or ledger entry. Already admitted
streams and pre-drain queue entries retain their leases and finish under the
existing bounded shutdown policy. WebSocket owner draining, browser and MCP
admission are unchanged. This closes late HTTP admission after readiness
withdrawal; it does not migrate streams or guarantee completion beyond the
configured drain and endpoint shutdown deadlines.

Version series `0.7.3-kk.N` adopts upstream 0.7.3 and retains the following
quota changes introduced in `0.7.1-kk.N`:

- The latest valid, non-future Usage API observation is the quota authority for
  display, quota selection and the matching exported selection. A newer API
  snapshot may decrease usage, report zero, or correct its reset earlier or
  later. Older or equal observations do not overwrite that snapshot or refresh
  its observation age. Credential-epoch and usage-probe ordering fences remain
  in the persistence path.
- Runtime headers and rate-limit events remain raw diagnostics. They do not
  override an API percentage or manufacture an unsupported API meter. Ordinary
  source/reset disagreement no longer replaces the main percentage or countdown
  with a warning. The upstream evidence dialog opens on demand, keeps the reading snapshot
  stable while open, and lists the selected record first with expandable details.
  It retains source values, observation time, reset and freshness.
- Failed or missing API refreshes do not establish fresh capacity. Retained API
  values show their last observation age and become historical/stale, including
  additional Spark/Reserve meters. Missing measurements remain unknown; an
  explicit zero used percentage means 100% remaining. Freshness is evaluated at
  the requested snapshot time. Historical resets are not live countdowns.
- Actual provider quota rejections remain separate routing and Saved Reset
  evidence. Only an actual failed request/terminal response can create the
  rejection marker; a successful response's headers cannot. Persistence checks
  the credential epoch captured by the request under the existing identity
  lock. Consumers reject old-epoch, future, stale or elapsed rejection evidence;
  a newer matching API observation can supersede it. Matching uses the full
  canonical meter identity, including additional-meter tokens. This does not
  change provider permission flags or make a successful API poll proof that a
  model request will succeed. Upstream's fresh explicit account and model-specific
  permissions remain independent of the displayed percentage, including the
  supported Spark grant; a current actual rejection still constrains routing.
- A runtime/API mismatch requests a full account reconciliation through the
  existing worker. The identity-scoped 60-second enqueue cooldown includes
  cancelled/failed attempts, and unfinished jobs prevent overlapping automatic
  work regardless of age. API ingestion cannot create a refresh loop. Standalone
  ingestion enqueues after commit; writes inside a caller-owned transaction rely
  on the existing periodic reconciliation sweep. An enqueue failure cannot undo
  committed quota evidence. Queue/provider delays still affect refresh latency.
- Account quotas are labelled Account Weekly; additional Spark/Reserve meters
  retain their separate identities. `normal_model_slug` is persisted as metadata
  and displayed without becoming routing identity. Raw provider meter tokens
  are hashed in the UI projection.
- From `0.7.1-kk.2`, the existing authorized `/metrics` response exposes native
  gauges for every non-deleted enrolled account, including paused, disabled,
  unassigned and never-success accounts. A bounded read-only database snapshot
  reports inventory, memberships, retained source observations, utilization,
  resets, freshness and collector coverage. Conflict gauges are diagnostics;
  selected-observation gauges identify the authoritative API view. Internal
  identities and closed label vocabularies keep credentials, emails, aliases and
  raw provider/model descriptors out of exposition. Scrapes never load account
  secrets, refresh OAuth, poll providers, enqueue work, call models, switch
  accounts or redeem credits. See the native metrics contract in
  `docs-site/src/content/docs/operators/monitoring.mdx`.

The fork changes quota evidence selection as well as display/export. It cannot
change the provider's actual allowance or guarantee uninterrupted requests.
Provider failure/cooldown handling remains independent of percentage selection.
Saved Reset enable/trigger defaults, consumption latch, confirmation lifecycle,
15-minute probe grace and 30-minute automatic-consumption cooldown remain in
force; a source mismatch alone does not justify spending or confirming a reset.
The separate proposed active-work/expiration policy is not implemented here.

The quota changes add no new worker or OAuth refresh owner. This integration
includes upstream's alert-delivery migration allowing lifetime attempt numbers
beyond one retry cycle; it does not migrate account credentials, enrollment,
pool assignments or gateway keys. The upstream native JSON codec replaces Jason
throughout this distribution, including the fork's request-rejection handling.
There is no new quota history store: observations already overwritten by their
own source cannot be reconstructed. Account metrics and history depend on the
retained evidence and monitoring backend; collector success alone does not
establish fresh quota for every account. Regression providers and accounts are
synthetic; tests contain no production credentials or account identifiers.

GitHub Actions runs formatting, compilation, architecture/lint, assets and the
full default test suite before building the upstream release Dockerfile with
pinned base images and this notice/license in the runtime image. Image tags
combine VERSION and the full source SHA; source/version/upstream labels and OCI
provenance identify the artifact. Existing tags must never be overwritten.
Deployment pins the resulting digest through the existing Helm chart.

Local verification uses Elixir 1.20.4/OTP 29 and disposable PostgreSQL 18 with
`MIX_ENV=test`. `mix test` resets only the configured synthetic test database.
