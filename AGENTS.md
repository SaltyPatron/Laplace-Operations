# Laplace-Operations Engineering & Operational Guide

## 1. Host Topology & Environment Roles

| Host | Tailscale / LAN IP | Role & Environment Isolation Contract | Public / Local Origin | Databases & Services |
|---|---|---|---|---|
| **`HART-DESKTOP`** (`hart-desktop-1`) | `100.70.222.78`<br>`192.168.1.x` | **Local Interactive Dev**: Windows 11 development & optional GPU host. **Zero gatekeeping, no background GitHub Actions runners.** | `https://dev.hartonomous.com` (IIS), `http://localhost:5187` (dev source run) | Single custom PostgreSQL 18.6 (`laplace-postgres`, port 5432, SSPI + TLS): `laplace-mono`, `laplace-desktop-app`, and `laplace`. |
| **`hart-server`** | `100.76.181.27`<br>`192.168.1.2` | **Staging (CI/CD App Deployment) + Shared Infra Host**: Ubuntu 22.04 server (**damaged GPU must remain disabled**). App & modular services deployed **via CI/CD only**; host remains accessible for `/vault` storage, OpenBao, Vaultwarden, and DB hosting. | `https://staging.hartonomous.com` (`laplace-api`, `laplace-mcp`, `laplace-modular-mcp`) | PostgreSQL 18.6 cluster (`laplace-mono`, `laplace`), **OpenBao** (`https://openbao.hartonomous.com`), **Vaultwarden**, SMB shares (`/vault`), Linux GitHub Actions runners. |
| **`hart-prod`** | `100.124.95.17` | **Locked Enterprise Production (CI/CD Promotion Only)**: Low-cost always-on GCP VM (`us-east1-b`). **Never manually SSH-patched or built on.** Receives verified packages promoted from `hart-server` by CI/CD. | `https://api.hartonomous.com`, `https://mcp.hartonomous.com` | Local PostgreSQL 18.6 (`laplace-app` for accounts, sessions, keys, billing). Connects to `hart-server` (or `hart-cloud` when active) over Tailscale for substrate queries. |
| **`hart-cloud`** | `100.103.255.122` | **On-Demand AVX-512 DB & Qualification Host**: GCP `c3-standard-8` VM. | Internal / Tailscale | **Kept `TERMINATED` (off) when idle** to preserve GCP trial credit. Auto-stops via `idlestop` once its lease expires. |
| **`hart-router`** | `192.168.1.1` | OpenWrt router | LAN gateway | Split-horizon DNS and LAN routing. |

---

## 2. Execution Boundaries (Automation vs. User Execution)

1. **One-Time Host Provisioning (Admin / `sudo`)**:
   - Linux: `sudo ./setup.sh` (shared/modular infrastructure) and `sudo bash deploy/linux/site-host.sh` (monorepo site/TLS/OpenBao enrollment).
   - Windows (`HART-DESKTOP`): `pwsh -File setup.ps1` (Admin) and `Laplace/deploy/windows/Install-IisRuntime.ps1` (Admin).
   - **Windows UAC / ACL Rule**: Non-elevated shells on `HART-DESKTOP` do not hold the `BUILTIN\Administrators` (`S-1-5-32-544`) token. Any elevated script that modifies directory or file ACLs on `E:\Data\Laplace`, `D:\Libraries\build\Laplace`, `D:\Data\Laplace`, or `C:\ProgramData\Laplace` **must** explicitly grant `$declared.windows_sid` (`HART-DESKTOP\ahart`, `S-1-5-21-1955383224-1799969050-1119319971-1001`) `FullControl`. Use `pwsh -File installation/Repair-DesktopPermissions.ps1` in an elevated prompt if permissions ever drift.
2. **Automated CI/CD Delivery**:
   - Pushes to `main` in `Laplace-Native`, `Laplace-postgres`, `Laplace-Engine`, or `Laplace-MCP` run component tests and dispatch `main-merged` to `.github/workflows/laplace.yml` in `Laplace-Operations` to deploy and verify on `hart-server`.
   - Pushes to `main` in `Laplace` run monorepo delivery to `hart-server` (staging) and promote to `hart-prod` (production).
   - **Database Reseed Policy**: Push/merge workflows never automatically drop or reseed databases. Destructive resets (`drop` / `reseed`) require explicit manual dispatch.
3. **Normal Operator CLI & Verification (Non-Elevated Shell)**:
   - Installed CLIs on `HART-DESKTOP`: `laplace` (`%LOCALAPPDATA%\Laplace\bin\laplace.cmd`) and `laplace-mono` (`%LOCALAPPDATA%\Laplace\bin\laplace-mono.cmd`). Re-package the modular Windows client anytime without elevation via `pwsh -File installation/install-windows-client.ps1 -Installation installation/hart-desktop-modular-client.json`.
   - Lifecycle & verification: `./laplace.ps1`, `./installation/Verify-DesktopDatabases.ps1`, and `./installation/Verify-PlatformAccess.ps1`.
   - Default platform administrators (`aharttn@gmail.com` Google, `thesaltypatron@gmail.com` Google, `thesaltypatron@gmail.com` Microsoft) are seeded automatically in `Laplace` migration `20261016000000_app_default_platform_administrators.sql` across all application databases (`laplace-desktop-app`, `laplace-mono`, `laplace-app`).
4. **Frozen Reference (`Laplace-Refactor`)**:
   - `Laplace-Refactor` is archived as a read-only reference for recipe-driven ingestion. Do not provision, build, or deploy `Laplace-Refactor`.

---

## 3. Operational Acceptance & Verification

For installation and infrastructure work, consult `acceptance/criteria.json` and run the actual verification scripts (`acceptance/verify.ps1`, `installation/Verify-DesktopDatabases.ps1`, `installation/Verify-PlatformAccess.ps1`). Record installation and live-operation evidence accurately, and keep the repositories clean of worktree or scratch-script sprawl.

