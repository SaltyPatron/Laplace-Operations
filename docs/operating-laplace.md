# Operating Laplace

Run these from this Operations checkout on HART-DESKTOP, using your existing GitHub CLI login:

```powershell
./laplace.ps1 status -Target production -Wait
./laplace.ps1 verify -Target staging -Wait
./laplace.ps1 verify -Target production -Wait
./laplace.ps1 deploy -Wait
```

`staging` selects hart-server; `production` selects hart-prod; `knowledge` selects hart-cloud when it is running.
`status` inspects installed revisions, configuration and connectivity; `runs` lists workflow history. `verify` executes the installed application. With `-Wait`, status and verification receipts are downloaded under `$LAPLACE_WORK/operations/<run-id>`.
`deploy` delivers `main` through the same chain used by a merge: build and run on hart-server, then start hart-cloud,
build the production bundle, publish on hart-prod and verify it. The cloud lease is released afterward so the
existing idle-stop mechanism can stop the VM. HART-DESKTOP remains the development and optional GPU machine.

Every operation returns a GitHub run link. `-Wait` follows that run and returns failure if it fails. The GitHub
**Product — maintenance** workflow offers the same controls. `-Revision` selects a published ref; local uncommitted
changes are not uploaded by this command. No repository or build directory is mounted on a deployment target.

The installed-runtime check requires API/web responses, MCP authentication when installed, authenticated SQL
execution, native decomposition/storage invariants, compatible loaded Tier-0 artifacts, and the configured Stockfish
executable's UCI/search behavior. An empty knowledge database is reported separately from failed infrastructure.
The verifier issues a temporary key in the migration-provisioned verification workspace and revokes it afterward.

On a declared Linux host, from the matching Laplace source checkout:

```sh
bash deploy/linux/site.sh smoke
bash deploy/linux/site.sh configure restart smoke
```

The first command verifies the installed site. The second regenerates its declared runtime configuration and
restarts it. Shared host locks prevent these operations from racing deployment or ingestion.

Install API operator and existing OAuth provider credentials from OpenBao on an SSH-accessible target:

```powershell
./secrets/configure-site.ps1 -HostName hart-server -InstallPrefix /opt/laplace
```

This uses the existing authenticated Bao session. Values travel over stdin and are not printed. An operator credential
is created once under `kv/hosts/<host>/laplace-api`; provider credentials come from `kv/shared/laplace-auth`.
Conflicting installed credentials stop the operation instead of silently rotating them. Restart the service after
a reported change. This bootstrap does not replace the host's AppRole or establish credential-refresh automation.

Register an existing Stockfish build using its actual selected source path:

```sh
python3 scripts/install-stockfish.py --configure --source-dir "$LAPLACE_STOCKFISH_SOURCE" --prefix "$LAPLACE_INSTALL_PREFIX"
```

The command validates the official pinned checkout and executes a legal search before saving its paths. It preserves
unrelated service settings and leaves the checkout in place.

Production can select the existing hart-server knowledge database while keeping its application database local.
`secrets/provision-knowledge.ps1` creates the non-superuser knowledge login and the consumer's OpenBao record;
`sudo ./setup.sh knowledge-client` installs the existing host AppRole's credential refresh timer. Selecting a new
knowledge source is explicit; the timer only refreshes the selected credential. It never moves account/session data.

When MCP runs on the knowledge host, declare `LAPLACE_MCP_UPSTREAM` in the consumer's machine.env and run the
site host installer. Distribute the existing MCP credential with:

```powershell
./secrets/configure-site.ps1 -HostName hart-prod -InstallPrefix /opt/laplace -UseSudo -McpTokenSource kv/hosts/hart-server/laplace-api
./network/cloudflare-api.ps1 -Zone hartonomous.com -ApiHosts api.hartonomous.com,mcp.hartonomous.com
```

The Cloudflare command checks the host-specific API rule; `-Apply` converges it. Browser Integrity Check was returning
403/error 1010 for legitimate Python clients before they reached Laplace. The rule disables that browser heuristic
only on the two programmatic service hosts, preserving application authentication and other security rules.
[Cloudflare documents this setting for API traffic](https://developers.cloudflare.com/waf/tools/browser-integrity-check/).
The nginx template preserves HTTPS from the trusted local tunnel and the public host header, so OAuth callback URLs
have the correct public origin. [ASP.NET proxy guidance](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-10.0)
explains why forwarded scheme and host affect redirects.
