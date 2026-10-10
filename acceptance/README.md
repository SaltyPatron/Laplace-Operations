# Installation acceptance

The [parent issue](https://github.com/SaltyPatron/Laplace-Operations/issues/2) tracks delivery. `criteria.json` owns the
versioned operational outcomes, responsible repositories, dependencies, required evidence and executable check mapping.
The [audit](../docs/2026-10-10-system-audit.md#expanded-installation-delivery-and-resource-audit) explains why they exist.
These operational criteria do not replace Laplace's product specification.

List the checks with `pwsh -NoProfile -File acceptance/verify.ps1 -List`.
Run every registered check with an explicit new evidence destination:

```powershell
. ./laplace.env.ps1
pwsh -NoProfile -File acceptance/verify.ps1 -Output "$env:LAPLACE_WORK/acceptance/full-20261010.json"
```

This currently returns **2 (incomplete)**. Checks without implementations, checks for another operating system, and
checks not selected are named in the receipt. A missing executable, timeout or failed check cannot return success.
Exit 1 means a check failed. Exit 0 means only the selected checks passed; it does not accept the whole installation.
The receipt distinguishes those outcomes and includes source revision, dirty-worktree flags, registry digest, host,
UTC timestamps, exact commands, exit codes and output. Existing receipts are never overwritten.

For a bounded Windows verification:

```powershell
. ./laplace.env.ps1
pwsh -NoProfile -File acceptance/verify.ps1 -Check storage-windows,resource-refusal-windows,backup-copy-windows -Output "$env:LAPLACE_WORK/acceptance/windows-20261010.json"
```

CI runs the named implemented checks on Windows and Linux and uploads their JSON receipts even on failure. Its green
component jobs are not a green whole-installation acceptance result. Future live probes must identify the target,
installed release, knowledge selection and workload identity without logging credentials. Live destructive operations
must not be smuggled into this default verifier; setup/recovery actions prepare the state, and verification reads it.

Work proceeds as: criterion -> failing check -> implementation -> passing check -> install/activate when applicable ->
live evidence -> tracker update. Do not check off a whole-host outcome using a narrower fixture. The two storage fixes
and refusal of planner-declared overcommit have executable regression evidence. Configuration convergence, coherent
release installation, cloud-off serving, identity, network/TLS, recovery and wire-budget criteria remain open.
