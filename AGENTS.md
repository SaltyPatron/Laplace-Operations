# Operational acceptance

The user's instructions and product specifications remain authoritative. The audit is evidence, not a replacement specification.

For installation and infrastructure work, read `acceptance/criteria.json` and the parent tracker linked there. Select the
criterion being implemented, preserve its dependencies and other open criteria, and run its actual checks. Add a missing
check when implementing the behavior. `acceptance/verify.ps1` saves the command, result, revision, host and scope; use a
new receipt path for each run. CI publishes receipts as artifacts.

Do not mark a criterion implemented because documentation exists, or operationally accepted because a fixture passes.
Record installation and live-operation evidence separately. Missing, failed, stale or wrong-host evidence does not pass.
Keep the parent issue open while whole-system criteria remain unmet, and link changes and evidence there so continuation
does not depend on chat history. Preserve an existing desktop backup-task path until its task has been deliberately
migrated and read back; a merged source change does not change a registered task action.

Preserve the isolated environments: hart-desktop is development, hart-server is staging, and hart-prod is the inexpensive
always-on production web host. Hart-cloud is the on-demand AVX-512 database VM; keep it off when unused to preserve trial
credit. Production can fail over from hart-cloud to hart-server. Hart-prod also has PostgreSQL for local fallback and
application data such as accounts and billing. A current connection to hart-server is not evidence of a configuration
error or authorization to redesign placement. Read docs/operating-laplace.md and the cloud-off-serving criterion before
changing database targets or resetting data. Hart-server's damaged GPU must not run; OpenBao and Vaultwarden already
live there. Database target selection is distinct from application-data recovery. Network acceptance measures external
round trips and bytes, not counts of SQL executed inside PostgreSQL.
