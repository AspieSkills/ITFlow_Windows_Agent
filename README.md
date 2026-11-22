# ITFlow Agent — User Manual

## Version 8.2.3 | PowerShell 5.1 | Windows

---

# 1. Introduction

ITFlow Agent is a PowerShell-based tool that syncs Windows machine inventory to [ITFlow](https://itflow.org), an open-source IT documentation, ticketing, and accounting system for small MSPs. It handles automatic device enrollment, hostname synchronization, client transfer detection, Active Directory attribute sync, dynamic user-contact assignment, and scheduled background syncing.

## What it does

- Collects local hardware inventory (CPU, RAM, disks, displays, network)
- Looks up the machine by serial number in ITFlow
- Creates a new asset if none exists (enrollment)
- Updates existing assets with current hardware info, including per-type `asset_specs` (CPU, RAM, storage / vCPUs)
- Matches external monitors to existing ITFlow Display assets and keeps their make/model/size/resolution and a "Last Seen" timestamp current
- Syncs computer attributes back to Active Directory (serial, description, notes)
- Detects when an asset has been transferred to another ITFlow client — including transfers performed natively in the ITFlow UI, which archive the original record
- Assigns the ITFlow asset's primary contact automatically from Windows Security log logon activity, with recency-weighted scoring and AD/Entra email matching
- Queues and executes computer renames when the hostname differs from ITFlow
- Supports reimage scenarios — detects serial matches across duplicate hostnames
- Auto-reboots unattended at startup to complete a queued rename (domain-joined machines only, and only when no interactive user is present), closing the AD trust-relationship window
- Retries failed renames up to 3 times with automatic flag cleanup
- Creates HTML-formatted tickets in ITFlow for enrollments, renames, conflicts, failures, transfers, archived assets, unmatched displays, missing contacts, and device reports
- Classifies API failures (invalid/expired key, permission denied, bad request, server error) instead of reporting every failure as a generic error
- Supports GPO-triggered device reporting via registry flag
- Hardens its own install directory, script file, and registry key against tampering by non-admin users
- Can run on a schedule via Windows Task Scheduler

## Requirements

- Windows 7 / Server 2008 R2 or later
- PowerShell 5.1
- Network access to ITFlow server
- ITFlow **26.12 or later** (API keys are user-owned and RBAC-scoped since 26.08, and 26.12 is the first version with the `X-API-Key` header authentication this agent requires — see [§12 ITFlow Server Compatibility](#12-itflow-server-compatibility))
- ITFlow API key, issued against a user with asset read/write, contact read, and ticket create permissions on every client the agent syncs into
- Administrative rights for: scheduled tasks, computer rename, registry writes, ACL hardening on install

---

# 2. Installation

## 2.1 Quick Start (GUI)

1.  Run the script: `.\ITFlow-Agent.ps1`
2.  Click **Config** and enter:
    -   **ITFlow Base URL**: `https://itflow.yourdomain.com`
    -   **Client ID**: The ITFlow client ID this machine belongs to
    -   **API Key**: Your ITFlow API key
3.  Click **Save**
4.  Click **Test API** to verify connectivity and check what permissions the key has
5.  Click **Run / Sync** to perform the first sync

## 2.2 Quick Start (Silent / Scheduled Task)

```powershell
# One-line setup (run as Administrator):
.\ITFlow-Agent.ps1 -Install
```

This hardens and writes config to registry, copies the script to `C:\ProgramData\ITFlow\ITFlow-Agent.ps1`, locks down the install directory and script ACLs, and creates a scheduled task (`ITFlow-Agent-Sync`) that runs the agent at every system startup in unattended auto-rename mode.

For GPO deployment: pre-configure registry keys, then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "\\server\share\ITFlow-Agent.ps1" -Install
```

On subsequent GPO runs (same version), the `-Install` switch detects the installed version matches and only triggers the task without re-copying.

## 2.3 Manual Uninstall

**GUI**: Click the **Uninstall** button (appears after installation).

**Command line**:

```powershell
.\ITFlow-Agent.ps1 -Uninstall
```

Removes the scheduled task, all registry keys under `HKLM:\SOFTWARE\ITFlow`, and the `C:\ProgramData\ITFlow` folder.

---

# 3. Configuration

## 3.1 Config Dialog

Click **Config** in the GUI to open the settings window.

### ITFlow Settings

| Field | Description |
|-------|-------------|
| **ITFlow Base URL** | Full URL to your ITFlow instance (e.g., `https://itflow.example.com`). Pinned after the first elevated install/save — a SYSTEM run whose registry `BaseUrl` differs from the pinned value falls back to the pinned value and logs a security warning. |
| **Client ID** | Numeric ITFlow client ID this machine belongs to |
| **API Key** | Your API key (displayed masked). Re-encrypted with machine-scoped DPAPI automatically if found in plaintext from an older agent version. |

### Agent Options

| Option | Default | Description |
|--------|---------|-------------|
| **Create Tickets** | ON | Creates ITFlow tickets for enrollment, rename, conflicts, failures, transfers, archived assets, unmatched displays, missing contacts, and device reports |
| **Follow Client Transfers** | ON | Automatically follows asset when moved to another ITFlow client, including transfers made in the ITFlow UI |
| **Auto-update ClientId on Transfer** | ON | Persists the new ClientId after a transfer so future syncs target the new client |

### User Assignment (from Logon Activity)

New **User Assignment** groupbox, off by default:

| Option | Default | Description |
|--------|---------|-------------|
| **Enable contact assignment** | OFF | Assigns the ITFlow asset's primary contact from Windows Security log logon activity |
| **Lookback days** | 90 | How many days of the local Security log to scan (1–365) |
| **Recency half-life (days)** | 14 | Session minutes are weighted `0.5^(ageDays / HalfLife)`; `0` disables decay (flat cumulative totals) |
| **Allowed domain(s)** | *(auto-detect)* | Comma-separated logon-domain allow list; blank auto-detects the AD domain (FQDN + NetBIOS) plus `AzureAD` |
| **Verbose logging** | OFF | Enables `Log-Debug` diagnostic output for contact matching and other internals |

See [§5.6 Dynamic Contact Assignment](#56-dynamic-contact-assignment) for how matching and the reassignment hysteresis work.

### Defaults Button

Resets all agent options and the User Assignment settings to default. ITFlow connection settings are preserved. After save, the Device Overview panel refreshes immediately to reflect the new configuration.

## 3.2 Portable Mode (USB / Ad-hoc)

When run from a USB stick or non-elevated, the agent detects that the registry is unavailable and switches to **portable mode**:

-   All data is stored in `ITFlow-AssetManager.ini` alongside the script
-   No registry writes are attempted
-   Config, preferences, state, cache, and ticket flags are all stored in the INI file
-   The INI file follows standard section format:

```ini
[ITFlow]
BaseUrl=https://itflow.example.com
ClientId=11
ApiKey=...

[Preferences]
CreateTicketsGui=1
FollowClientTransfers=1
AutoUpdateClientIdOnTransfer=1
PushAssetSpecs=1
PushDisplaySpecs=1
TicketUnmatchedDisplays=0
AssignContactFromLogons=0
AssignContactLookbackDays=90
AssignContactHalfLifeDays=14
AssignContactAllowedDomain=
VerboseLogging=0

[State]
LastSyncOK=1
LastRunAt=2026-05-13 12:00:00

[Cache]
LastSentMAC=00:11:22:33:44:55

[TicketFlags]
Enrollment=1
```

-   The `[ITFlow]` section is written by the Config dialog and updated by `Set-ConfiguredClientId` on transfer.
-   All other sections are managed automatically by the agent's helper functions.
-   The SYSTEM-run scheduled task still reads config from the registry, not the INI — see [§11.1](#111-registry-vs-ini).

---

# 4. Usage

## 4.1 GUI Mode

Run without switches: `.\ITFlow-Agent.ps1`

### Window Layout

The GUI is a single compact window with three areas stacked vertically. Window width is locked on first display; height expands when details are shown.

**Header row** (always visible): Left-aligned action buttons, right-aligned Config button.

**Status bar** (always visible): Shows current operation state and notifications. Color-coded:

-   Gray — Idle
-   DarkGoldenrod — Sync in progress / rename available
-   DarkGreen — Sync completed successfully
-   DarkRed — Sync error / rejected API key
-   DarkOrange — Notification (rename pending, limited API permissions)

**Details panel** (collapsed by default, toggled with "Show Details"): Contains the Device Overview table and full Log.

### Header Buttons

| Button | Description |
|--------|-------------|
| **Test API** | Probes what the agent actually needs — assets read, contacts read, clients read — independently, via `Test-ITFlowApiCapabilities`. Reports one of three outcomes: rejected key (red), OK with limited permissions (amber — some features will be skipped), or fully successful (green). A 403 on the assets probe specifically shows "API key valid - no asset permission". |
| **Run / Sync** | Starts an async sync in a background runspace. Button text changes to **Cancel Sync** while running. The GUI remains responsive — log updates in real time via file tailing. |
| **Install / Uninstall** | Installs: hardens ACLs, writes config to registry (if elevated), copies script to `C:\ProgramData\ITFlow\`, creates at-startup scheduled task, triggers it immediately. Uninstalls: removes task, registry keys, `C:\ProgramData\ITFlow` folder. Toggles label based on whether the scheduled task exists. Self-elevates if not admin. |
| **Open SysInfo** | Opens the latest sysinfo JSON file in Notepad. |
| **View SysInfo** | Parses the latest sysinfo JSON and shows a formatted dialog with hardware summary (CPU, RAM, disks, displays, network adapters). |
| **Rename** | Enabled after a sync detects the ITFlow asset name differs from the local hostname (orange status bar). Starts the rename process. If not elevated, shows instructions to run as administrator. |
| **Config** | Opens the Settings dialog. Disabled during sync. |

### Status Bar

Single-line label with color-coded status messages. Auto-truncates if the message exceeds the window width.

Common messages:

-   `STATUS: Idle` (gray)
-   `STATUS: Running sync...` (gold)
-   `STATUS: Success` (green)
-   `STATUS: Error` (red — error details in log panel)
-   `STATUS: API OK - limited permissions` (amber — Test API passed with a gap, e.g. no contacts/clients read)
-   `STATUS: API key valid - no asset permission` (red — key authenticates but can't sync assets)
-   `STATUS: Rename available: <hostname>` (orange)
-   `STATUS: Previous rename failed - manual intervention required` (red)
-   `STATUS: Rename pending - reboot required` (orange)
-   `STATUS: Cancelled` (gray)

### Config Dialog

Opened by the **Config** button. Three sections:

**ITFlow Settings:**

-   ITFlow Base URL — text field (full URL, e.g. `https://itflow.example.com`)
-   Client ID — numeric text field
-   API Key — masked password field

**Agent Options:** (three checkboxes)

-   **Create Tickets** — enables/disables all ticket creation (enrollment, rename, conflicts, failures, transfers, archived assets, unmatched displays, missing contacts, device reports)
-   **Follow Client Transfers** — auto-follow when asset serial found in another client
-   **Auto-update ClientId on Transfer** — persist the new ClientId after a transfer follow

**User Assignment:** (five controls, see [§3.1](#31-config-dialog))

**Bottom buttons:**

-   **Defaults** — resets all checkboxes/fields to default, strips INI/registry of all `[Preferences]`, `[State]`, `[Cache]`, `[TicketFlags]` sections. Preserves `BaseUrl`, `ClientId`, `ApiKey`.
-   **Save** — writes everything, calls `Refresh-OverviewUI` to update the Device Overview immediately, closes dialog.
-   **Cancel** — closes dialog without saving.

### Device Overview (Details Panel)

| Field | Source | Notes |
|-------|--------|-------|
| Hostname | Live `$env:COMPUTERNAME` | Reflects immediately after rename + reboot |
| Serial | Last sync result | From `$script:LastRunState.Serial` |
| Type | Detected locally | Laptop / Desktop / Server / Virtual Machine / Other |
| IP / MAC | Live local values | From `Get-PrimaryIP` / `Get-PrimaryMAC` |
| ClientId (Configured) | From config | `$Config.ClientId` — the configured client |
| ClientId (Effective) | Last sync result | May differ after transfer follow (shows "(last)" suffix) |
| AssetId | Last sync result | ITFlow asset ID from last successful sync |
| Transfer Followed / ClientId Updated | Last sync result | "Yes / No" or "No / No" |
| Sysinfo | File path + timestamp | Auto-refreshes via 30-second timer |

The overview panel auto-refreshes every 30 seconds (stops during sync). After a Config save, it refreshes immediately.

## 4.2 Command-Line Options

| Switch | Description |
|--------|-------------|
| `-Silent` | Run without GUI (console mode). Used by scheduled tasks. |
| `-Rename` | Allow automatic computer rename in silent mode (used with `-Silent`). |
| `-Reboot` | Run the rename in **unattended auto-rename mode**: rename and force a restart back-to-back when no interactive user is present (domain-joined), or rename without forcing a restart on non-domain machines. Used by the scheduled task; see [§6 Rename Handling](#6-rename-handling). |
| `-Install` | Install the agent: harden ACLs, write config to registry, copy script to `C:\ProgramData\ITFlow\`, create scheduled task. |
| `-Uninstall` | Remove the agent: delete task, registry keys, and `C:\ProgramData\ITFlow`. |
| `-Worker` | Internal flag used by the GUI's async engine. Not for direct use. |

### Examples

```powershell
# Run once, sync and rename if needed, unattended (as installed by the scheduled task):
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\ITFlow\ITFlow-Agent.ps1" -Silent -Rename -Reboot -Worker

# Install from network share:
powershell.exe -ExecutionPolicy Bypass -File "\\server\share\ITFlow-Agent.ps1" -Install
```

## 4.3 Scheduled Task

When installed via the **Install** button or `-Install` switch, a task named `ITFlow-Agent-Sync` is created:

| Property | Value |
|----------|-------|
| **Trigger** | At startup (resets to startup after successful sync) |
| **Action** | `powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\ITFlow\ITFlow-Agent.ps1" -Silent -Rename -Reboot -Worker` |
| **Run as** | SYSTEM |
| **Run with highest privileges** | Yes |
| **Execution time limit** | 15 minutes (default is 3 days) |

The `-Worker` flag in the task action skips the single-instance mutex, allowing the task to run even if another instance is exiting. After installation, the task is triggered immediately via `Start-ScheduledTask` with a `schtasks.exe /run` fallback.

**Existing installs** keep their prior task argument string until the agent is reinstalled/updated — confirm the task action includes `-Reboot` after upgrading from a pre-v7.5 agent.

### Retry on Failure

If the sync fails (ITFlow unreachable), the task trigger switches to:

-   **First run**: 1 hour from failure time
-   **Repetition**: Every 1 hour
-   **Duration**: Up to 24 hours

Once a sync succeeds, the trigger reverts to at-startup.

A **rejected or expired API key** is not treated as "unreachable" — the connectivity probe aborts the 5×30s retry immediately on an auth failure instead of burning two and a half minutes, and the log clearly says to reissue the key rather than implying a network problem.

---

# 5. Sync Flow

## 5.1 What happens during a sync

1.  **Local inventory collection**: BIOS serial, hostname, manufacturer, model, OS (Caption + build/DisplayVersion, e.g. `Microsoft Windows 11 Pro 24H2`), MAC, IP
2.  **Sysinfo snapshot**: CPU, RAM, disks, displays (including EDID serials and native per-monitor resolution), network — saved as JSON to `C:\ProgramData\ITFlow\sysinfo_<hostname>.json`
3.  **Connectivity check**: Up to 5 attempts, 30 seconds apart; aborts immediately on an auth rejection instead of retrying a dead key
4.  **Key scope check**: Infers how many clients the API key's user can see (`Get-ITFlowKeyScope`), and whether the configured client is among them — logged as a warning when transfer detection or asset sync could be degraded
5.  **Asset lookup**: Search ITFlow by serial number in the configured client, preferring a **live** row over an archived one
6.  **If a live asset is found in the configured client**:
    -   Update local truth: type, make, model, OS, status, MAC, IP, and per-type `asset_specs` (CPU/RAM/storage, or vCPUs/RAM/storage for VMs) — only fields that differ are sent
    -   Check hostname mismatch → queue rename if needed
7.  **If only an archived record is found in the configured client**: treated as possibly transferred — see [§5.3 Transfer Following](#53-transfer-following)
8.  **If no record (live or archived) is found in the configured client**:
    -   Global search by serial (all clients)
    -   If a live copy is found in another client → **follow transfer** (update ClientId, create tickets)
        -   The sync automatically re-enters the update path — the transferred asset's hostname check, rename detection, and field update all happen in the same sync run, no second sync needed
    -   If not found at all → enroll (create new asset, create ticket)
9.  **External display matching**: for each connected external monitor with a readable EDID serial, match against an existing ITFlow Display asset in the client and keep its make/model/size/resolution and a "Last Seen" timestamp current — see [§5.7](#57-external-display-asset-matching)
10. **Dynamic contact assignment**: if enabled, resolve and assign the asset's primary ITFlow contact from recent logon activity — see [§5.6](#56-dynamic-contact-assignment)
11. **Sync AD computer attributes**: Writes serial number, hardware summary (description), and full device spec (info/notes, as plain text) back to the computer object in Active Directory
12. **Device report check**: If a GPO-set registry flag is detected, creates a `[DEVICE REPORT]` ticket
13. **Result**: `LastSyncOK` persisted to registry/INI. Hourly retry task created/removed based on result.

## 5.2 Enrollment

When a machine's serial number doesn't exist (live or archived) anywhere in ITFlow, the agent:

1.  Creates a new asset in the configured client, including `asset_description` (the "Last Check-In" line) and `asset_specs` on the create call itself
2.  Sets asset name to local hostname
3.  Populates type, make, model, OS, serial, IP, MAC, status
4.  Creates an `[ENROLL]` ticket

## 5.3 Transfer Following

ITFlow's own **Transfer to Client** action copies the asset into the destination client under a **new asset ID** and **archives the original**, noting the old/new asset IDs and clients in its description. The agent's transfer handling covers both the legacy "enroll looks elsewhere first" path and this native-transfer case:

1.  **Live asset found in another client** → followed as before:
    -   Creates `[TRANSFER DETECTED]` ticket in the originating client
    -   Updates the effective ClientId to the destination client
    -   Optionally persists the ClientId change (Auto-update ClientId on Transfer)
    -   Creates `[TRANSFER FOLLOWED]` ticket in the receiving client
    -   Continues update sync with the new client context
2.  **Only an archived record remains in the configured client, and the live copy is outside the API key's visible clients** → `TRANSFER_OUT_OF_SCOPE`: one `[TRANSFER] … agent key cannot follow` ticket naming the destination client and new asset ID (flag `TransferOutOfScope`); no enrollment. Granting the key's user access to that client lets the next run follow it.
3.  **Only an archived record remains, with no transfer note at all** → genuinely archived: `ASSET_ARCHIVED`, one `[ARCHIVED]` ticket (flag `AssetArchived`), no update, no enrollment. Restoring the asset in ITFlow resumes normal sync; deleting it lets the agent enroll a new one.
4.  **An archived record exists only in another client** (nothing live or archived in the configured client) → `TRANSFER_TARGET_ARCHIVED`, one ticket (flag `TransferTargetArchived`), sync stops for this run.

The enrollment path is never reached while the configured client holds an archived record for the serial, even if the cross-client lookup errors.

## 5.4 AD Attribute Sync

After every successful asset sync, the agent writes hardware attributes back to the computer object in Active Directory (domain-joined only):

1.  **serialNumber**: Sets the AD `serialNumber` attribute to the local BIOS serial (not all schemas allow this — failures are non-fatal)
2.  **description**: Writes a compact hardware summary string:
    ```
    Dell Precision 5560 | 11th Gen Intel(R) Core(TM) i7-11850H @ 2.50GHz | 64 GB RAM | 512 GB Storage | Windows 11 Pro 24H2
    ```
3.  **info** (Notes): Writes the full device specification block, converted from the ticket's HTML back to readable plain text, appended with `Last Check-In: <timestamp>`

The sync is best-effort and non-fatal. If AD is unreachable or the schema doesn't support a specific attribute, the agent logs the failure and continues.

## 5.5 Asset Type Detection

`Get-AssetType` maps the SMBIOS chassis type (with a model-name and OS fallback) to the ITFlow asset types that carry hardware details (`Laptop`, `Desktop`, `Server`, `Virtual Machine`) rather than the generic `Other`, which receives no `asset_specs`:

| SMBIOS chassis / signal | Mapped to |
|---|---|
| All-in-One, sealed-case PC, Mini PC / Stick PC (chassis 13, 24, 35, 36) | Desktop |
| Tablet, Convertible, Detachable (chassis 30–32) | Laptop (ITFlow's `Tablet` type is for phones, not Windows 2-in-1s) |
| Server chassis / rack / blade running a client OS | Desktop |
| Unknown/Other chassis | `PCSystemType`: Mobile/Slate → Laptop, Desktop/Workstation/Appliance → Desktop |
| Server OS or VM signals | Server / Virtual Machine (checked first, unchanged) |

An existing ITFlow asset previously typed `Other` is corrected on its first sync under this logic, together with its full `asset_specs`.

## 5.6 Dynamic Contact Assignment

Off by default (`AssignContactFromLogons`). When enabled, assigns the primary ITFlow contact to an asset based on Windows Security event log activity (local machine only, not a domain controller).

- **`Get-UserLogonDurations`** scans the local Security log for logon (4624) / logoff (4634) events (interactive and RDP), bucketed per boot (using 4608 boot markers) to avoid conflating recycled Logon IDs across reboots. Session minutes are weighted by recency (`0.5^(ageDays / HalfLifeDays)`), so a handed-off device re-ranks to its new primary user within a few half-lives instead of staying anchored to historical hours. Set the half-life to `0` for flat cumulative totals.
- **Matching** tries, in order: AD `userPrincipalName` → AD `mail` → the logon name itself if it already looks like an email (Entra-joined devices) → `"$UserName@$DomainName"` as a last resort. The email lookup is scoped to the asset's client (`contact_email` with `client_id`) and independently re-verified against the returned row's client, so an all-clients key can't assign a contact from a different client. If no email match is found, a paginated name-token fallback search runs across the client's full contact list.
- **Reassignment hysteresis**: the current primary user only changes when a new leader clears the incumbent's current weighted score by a 1.25× margin, or the incumbent has aged out of the lookback window entirely. This prevents assignment churn when a device flip-flops between users at a shared site.
- **Missing-contact ticketing**: if the device is an existing ITFlow asset but its resolved primary user matches no ITFlow contact by any of the above, a ticket is raised (deduplicated per asset + user, cleared automatically once a contact is later found) so a technician can create the contact.
- **Domain auto-detect**: when `AssignContactAllowedDomain` is blank, the agent detects the AD domain (FQDN + NetBIOS) and always also allows `AzureAD`, for hybrid-joined machines.

## 5.7 External Display Asset Matching

The agent reads monitor EDID data for its local sysinfo snapshot and, since v8.2.0, uses it to keep existing ITFlow **Display** assets current — it never creates one.

- For each external monitor with a readable EDID serial, the agent matches it to a **live** ITFlow asset of type `Display` with the same serial in the client, and updates its make (via a vendor lookup table), model (the EDID friendly name, not the raw product code), `asset_specs` (`size_in`, `resolution`), and — since v8.2.2 — unconditionally stamps `asset_description` with `Last Seen: <timestamp> By <hostname> (Agent v<version>)` on every sync, even when nothing else changed, so ITFlow always shows which host last saw a given monitor and when.
- Built-in laptop/AIO panels are detected via `VideoOutputTechnology` and skipped before any lookup; a monitor whose EDID has no serial is skipped entirely (no reliable way to match or dedupe it).
- **`TicketUnmatchedDisplays`** (off by default) raises a one-time-per-serial ticket against the host asset when an unmatched external monitor is still unmatched on a *later* sync (never on first sight), so a technician can label/create the Display asset in ITFlow.
- Gated by `PushDisplaySpecs` (on by default — this path only ever updates an asset a technician already created with a matching serial, so it carries little risk).

---

# 6. Rename Handling

## 6.1 How rename works

1.  Sync detects hostname mismatch between local machine and ITFlow asset name
2.  Preflight checks run:
    -   **ITFlow duplicate**: Is another live asset (with a different serial) already using this hostname? (Archived records are ignored.)
    -   **AD duplicate**: Does a computer account already exist with this name?
3.  If preflight detects a duplicate:
    -   If the **serial matches** the conflicting record → treated as a **reimage scenario**: the old AD account is deleted or disabled, rename proceeds
    -   If the **serial differs** → creates `[RENAME CONFLICT]` ticket, blocks rename
4.  If preflight passes:
    -   **GUI mode**: Enable "Rename" button in the status bar
    -   **Silent mode with `-Rename`**: Automatically calls `Rename-Computer`

## 6.2 Rename button (GUI)

-   Appears when a queued rename target is available (orange status bar)
-   Requires administrator privileges
-   If not elevated, shows instructions to run as admin, with an option to auto-elevate
-   After successful rename: offers to reboot immediately

## 6.3 Unattended Rename + Auto-Reboot (`-Silent -Rename -Reboot`)

`Rename-Computer` on a domain-joined machine renames the AD computer object immediately but only applies the local name on reboot — the gap is a domain-trust window where a machine that never reboots can lose its secure channel ("trust relationship failed"). The scheduled task runs with `-Reboot` to close that window automatically:

-   **Domain-joined, no interactive user at the console** (`Test-InteractiveUserPresent`, via `Win32_ComputerSystem.UserName`): renames and **forces a restart (15s delay)** so the AD rename and completing reboot happen back-to-back.
-   **Domain-joined, a user is present**: the rename is **deferred and re-queued** rather than renamed-and-left-pending, so the trust window is never opened. It applies at the next startup (before interactive logon), the normal unattended case. If a prior run left a rename stuck pending reboot, the next no-user startup force-reboots to complete it (self-heal for fleets where users rarely restart).
-   **Not domain-joined** (workgroup or Entra-only — no AD object, no trust window): the agent renames **even with a user signed in**, and does **not** force a restart. This specifically fixes single-account, no-password workgroup PCs where Windows auto-logs in before the SYSTEM startup run reaches its decision, so the "no user present" window never arrived. The new name applies at the machine's next natural reboot; until then the GUI/log show "Rename pending - reboot required".
-   **Fail-safe**: if WMI can't be queried, `Test-InteractiveUserPresent` returns *true* (assume present), so the agent never force-reboots a machine it can't inspect.
-   **GUI-initiated renames are unaffected** — the GUI worker launches without `-Reboot`, so it neither defers-on-user nor auto-reboots; it keeps its own interactive reboot prompt.

### Rename attempt mechanics

-   Tries `Rename-Computer -Force -Restart:$false`
-   If fails with credential error and `netdom` is available: falls back to `netdom renamecomputer`
-   Tracks retry attempts per target hostname (max 3)
-   Sets `RenameFailed_<target>` flag to prevent re-attempting on every sync
-   Creates `[RENAME FAILED]` ticket if ticketing is enabled
-   Automatically clears previous `RenameFailed` flags on retry

## 6.4 Preflight Checks

Before any rename attempt, two safety checks run:

**ITFlow duplicate name**: Queries the ITFlow API for the target hostname within the effective client, ignoring archived records. If another live asset (with a different serial) already has that name, the rename is blocked and a `[RENAME CONFLICT]` ticket is created. If the serial matches, it is treated as a reimage and rename proceeds.

**AD computer account**: Searches Active Directory for a computer object with the target hostname, with a PDC-emulator fallback when a conflict is found on the local DC (guards against multi-DC replication lag producing a false conflict). If one exists with a matching serial, the old account is deleted or disabled (reimage scenario). If the serial differs, the rename is blocked. If AD is unreachable (non-domain, DNS failure), this check passes silently.

## 6.5 Pending Rename Detection

`Test-PendingComputerRename` compares the currently active computer name (in memory) with the pending name (in the registry, set by a previous `Rename-Computer` that hasn't rebooted yet). If they differ, the GUI shows "Rename pending - reboot required" and disables the Rename button until the machine is restarted.

## 6.6 Rename Button State Logic

After every sync and on GUI startup:

1.  Check for pending reboot rename → if found, show notification and disable button
2.  Read `LastRenameRequired` and `LastTargetHostname` from State → if queued and sync not running → enable button
3.  Check `RenameFailed_<target>` ticket flag → if set (previous rename failed), show "Previous rename failed — manual intervention required" and disable button

## 6.7 Rename Retry Logic

The agent tracks rename attempts per target hostname using a cache counter (`RenameRetry_<DesiredHostname>`):

-   On each sync where a rename is needed, the counter is incremented
-   If the counter reaches **3**, the rename is abandoned for that target
-   Previous `RenameFailed` flags are auto-cleared on each retry (conditions may have changed)
-   On successful rename, the counter is reset to 0

---

# 7. Ticket Reference

All tickets are rendered as HTML cards and tables in the ITFlow UI (key/value tables for scalar fields, real `<table>`s for repeating hardware lists), not escaped plain text.

| Ticket Title | Trigger | Linked To |
|-------------|---------|-----------|
| `[ENROLL]` | New asset created | Serial → asset lookup |
| `[RENAME]` | Rename initiated (GUI or silent) | Asset ID |
| `[RENAME FAILED]` | Rename-Computer threw an exception | Asset ID |
| `[RENAME CONFLICT]` | Preflight check blocked rename (ITFlow duplicate name or AD name-exists) | Asset ID |
| `[TRANSFER DETECTED]` | Serial found in originating client before transfer | Serial → asset lookup |
| `[TRANSFER FOLLOWED]` | Serial now in receiving client after transfer | Asset ID |
| `[TRANSFER] … agent key cannot follow` | Transfer note found but destination client is outside the API key's visible clients | Flag `TransferOutOfScope` |
| `[ARCHIVED]` | Asset exists only as an archived record, with no transfer note | Flag `AssetArchived` |
| Unmatched display ticket | External monitor still unmatched to an ITFlow Display asset on a later sync | Host asset; opt-in via `TicketUnmatchedDisplays` |
| Missing-contact ticket | Asset exists but the resolved primary user matches no ITFlow contact | Flag `ContactMissing_<assetId>_<user>`; requires `AssignContactFromLogons` |
| `[DEVICE REPORT]` | GPO-triggered registry flag detected | Serial → asset lookup |

All tickets are suppressed when **Create Tickets** is unchecked, except the missing-contact ticket, which fires whenever contact assignment is enabled independent of the general ticketing toggle, and `[TRANSFER DETECTED]`/`[TRANSFER FOLLOWED]`, which also fire regardless when `Auto-update ClientId on Transfer` is off (they carry no dedup ticket flag).

---

# 8. File Locations

| Path | Purpose |
|------|---------|
| `C:\ProgramData\ITFlow\` | Installed agent directory (ACL-hardened: owner Administrators, `SYSTEM:F, Administrators:F, Authenticated Users:RX`) |
| `C:\ProgramData\ITFlow\ITFlow-Agent.ps1` | Deployed script (scheduled task target), ACL-hardened the same way |
| `C:\ProgramData\ITFlow\Logs\` | Sync log files |
| `C:\ProgramData\ITFlow\SysinfoArchive\` | Historical sysinfo JSON snapshots |
| `HKLM:\SOFTWARE\ITFlow\` | Registry config (installed mode), DACL-hardened: Administrators + SYSTEM full, Users read-only |
| `HKLM:\SOFTWARE\ITFlow\State\` | Runtime state |
| `HKLM:\SOFTWARE\ITFlow\Preferences\` | GUI preferences |
| `HKLM:\SOFTWARE\ITFlow\Cache\` | Agent cache |
| `HKLM:\SOFTWARE\ITFlow\TicketFlags\` | Spam prevention flags |
| `ITFlow-AssetManager.ini` | Portable mode config (same directory as script) |

---

# 9. Troubleshooting

## 9.1 Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "No resource" errors | Serial not found in configured client | Normal — triggers global lookup or enrollment |
| `AUTH FAILURE` / red Test API | API key invalid, expired, or deleted by an ITFlow 26.08+ upgrade | Issue a new key under **Admin Settings > API Keys** against a suitably-permissioned user; see [§12](#12-itflow-server-compatibility) |
| "API OK - limited permissions" (amber) | Key's user is missing contacts or clients read | Grant the key's user the missing module permission, or ignore if that feature isn't used |
| "API key valid - no asset permission" (red) | Key's user lacks Support module write | Grant asset read/write to the key's user — this blocks all syncing |
| `PERMISSION DENIED (<action>)` in log | 403 from ITFlow naming the required level | Grant the named module/level to the key's user in ITFlow |
| Enrollment creates duplicate asset | Asset exists in another client outside the key's visible scope (`TRANSFER_LOOKUP_INCONCLUSIVE`) | Grant the key's user visibility of all clients the fleet moves between, or transfer/merge manually |
| `[ARCHIVED]` ticket | Asset was archived in ITFlow with no transfer note | Restore the asset in ITFlow to resume sync, or delete it to let the agent enroll a new one |
| `[TRANSFER] … agent key cannot follow` | Asset was transferred to a client the key's user can't see | Grant the key's user access to the destination client |
| Rename fails "Access is denied" | Process not elevated | Run as Administrator or use the GUI elevate prompt |
| Rename fails "Wrong username or password" | SYSTEM account can't authenticate to AD | The `netdom` fallback handles this automatically |
| Workgroup PC never renames (interactive user deferral loop) | Single passwordless account auto-logs in before the SYSTEM task evaluates | Fixed in v8.2.0+ — non-domain-joined machines rename with the user present and wait for the next natural reboot |
| Config changes not saving | Non-elevated, INI locked | Config is saved in memory; retry the save. If persistent, check if INI file is read-only. |
| "Portable mode" message | Registry unavailable or non-elevated | Normal for USB/ad-hoc use. All data goes to INI file. |
| Scheduled task not running | Missing permissions | Task runs as SYSTEM. Check that `C:\ProgramData\ITFlow\ITFlow-Agent.ps1` exists. |
| Install directory pre-created by a non-admin | Possible planting/privilege-escalation attempt | The agent refuses/resets the directory and reasserts hardened ownership and ACLs automatically |

## 9.2 Logs

Log files are written to `C:\ProgramData\ITFlow\Logs\<hostname>-<timestamp>.log`. Each sync run creates a new log file. The GUI's log panel tails the latest log file in real time.

## 9.3 First Run (Elevated)

When running `-Install` or the GUI elevated on a clean machine, the registry key `HKLM:\SOFTWARE\ITFlow` doesn't exist yet. The agent detects that you're elevated and creates the key and all subkeys (with a hardened DACL) automatically, then promotes the INI-based config to the registry. The "Portable mode" message is suppressed and `$script:RegistryAllowed` is set to `$true` for the session.

This means `-Install` on a clean elevated machine will:

1.  Read config from the INI file (next to the script)
2.  Create and harden registry keys
3.  Write BaseUrl, ClientId, ApiKey to the registry (and pin BaseUrl)
4.  Harden and copy the script to `C:\ProgramData\ITFlow\`
5.  Install the scheduled task (with `-Reboot`)
6.  Trigger the task immediately for the first sync

## 9.4 Startup Log

The first line of every log shows the execution context:

```
ITFlow Agent v8.2.3 starting (mode=Install, rename=False, elevated=yes)
```

Modes: `GUI` (WinForms), `Worker` (GUI async engine), `Silent` (scheduled task / console), `Install` (setup), `Uninstall` (removal).

## 9.5 API Key Hardening

When the agent loads config from the registry and finds an ApiKey that isn't DPAPI-encrypted (plaintext), it automatically re-encrypts it using `LocalMachine`-scoped DPAPI. This upgrades keys stored by older agent versions or manual registry edits. Requires elevation to write back to the registry.

## 9.6 Sync Comparison Logging

During every sync, `Log-LocalVsITFlowVerbose` logs a detailed before/after comparison of all tracked fields between the local machine and the ITFlow asset record, including `asset_specs` (`spec.<key>` lines). This fires once per sync run and is the primary diagnostic tool for verifying sync is working correctly. Enable **Verbose logging** in the User Assignment section of Config for additional `Log-Debug` detail on contact matching and other internals.

---

# 10. Security Hardening

The agent installs to `C:\ProgramData\ITFlow\ITFlow-Agent.ps1` and runs via the scheduled task **as SYSTEM at startup**. If an unprivileged user could modify the script, its install directory, or the registry config it trusts, they could influence or replace code that later runs as SYSTEM after a reboot they can trigger — a local privilege escalation chain (any user + reboot → SYSTEM). Full details, threat model, and original assessment are in `hardening.md`.

| Protection | What it does |
|---|---|
| **Hardened install ACLs** | Every install/update takes ownership of the install directory and script to Administrators, disables inheritance, and sets an explicit DACL (`SYSTEM:F, Administrators:F, Authenticated Users:RX`) — applied unconditionally, even on a pre-existing directory. |
| **Suspicious install target rejection** | If the install directory is a reparse point (junction/hardlink planting), it is removed (never followed) before a clean, hardened directory is recreated. |
| **Runtime script-integrity gate** | Before the SYSTEM run does any privileged work, it verifies the running script grants write only to trusted principals and is owned by one; otherwise the run is refused and logged. GUI/portable runs are unaffected. |
| **Hardened registry key + BaseUrl pin** | `HKLM\SOFTWARE\ITFlow` gets an explicit DACL (Users read-only). The elevated install/save records `InstalledBaseUrl`; a SYSTEM run whose loaded `BaseUrl` differs falls back to the pinned value, neutralizing API-key exfiltration even if the key itself were user-writable. |
| **Symlink-safe SYSTEM writes** | Before SYSTEM writes the sysinfo JSON or creates the log directory, it confirms the parent isn't a reparse point and is admin-owned. |

Not implemented: code-signing the script (deferred — needs certificate infrastructure and changes to deployment; the agent still runs with `-ExecutionPolicy Bypass`).

---

# 11. Architecture Notes

## 11.1 Registry vs INI

The agent uses a `$script:RegistryAllowed` flag to determine storage backend:

-   `$true` → All reads/writes go to `HKLM:\SOFTWARE\ITFlow\*` subkeys
-   `$false` → All reads/writes go to `ITFlow-AssetManager.ini` sections

This flag is set once at startup: `(Test-Path $RegRoot) -and (Test-IsAdmin)`. The SYSTEM scheduled task always has registry access, so a planted INI file is not a config-injection vector for the elevated run.

## 11.2 Process Model

-   GUI mode launches syncs in a background runspace pool (one runspace at a time)
-   The runspace calls the script with `-Silent -Worker -LogPath <shared_log>`
-   Worker mode skips the single-instance mutex
-   Worker mode uses `return` instead of `exit` to avoid killing the host process
-   The global script mutex is released and disposed before every `exit`, so a mid-run failure doesn't leave an orphaned mutex

## 11.3 Versioning

-   Version is stored in `$AgentVersion` at the top of the script
-   The `-Install` switch detects installed version by reading `$AgentVersion` from the deployed copy
-   If the version differs, the script is re-copied and the task re-registered
-   Downgrade protection: if the installed version is greater than the script version, installation is skipped

## 11.4 HTTP / API Plumbing

-   All API calls go through `Invoke-ITFlow` → `Invoke-ITFlowChecked`, which classifies every failure (`Get-ITFlowFailureKind`) into Auth / Permission / BadRequest / Method / Server / Transport from the HTTP status code (falling back to message text), so callers never have to re-parse a raw exception.
-   Every GET is built via `New-ITFlowReadUri`, which URL-escapes every query value — a serial, hostname, or other field containing `&`, `#`, `+`, or a space no longer gets silently truncated or mismatched by the query string. The API key itself is never part of the URL; `Invoke-ITFlow` sends it as the `X-API-Key` header on every request (GET and POST alike).
-   POST bodies are sent as explicit UTF-8 bytes with an explicit charset, so non-ASCII characters (accented names, the ticket section icons) survive instead of being replaced with `?` under Windows PowerShell 5.1's default Latin-1 encoding.

---

# 12. ITFlow Server Compatibility

This agent's API usage is re-verified against the ITFlow API reference and upstream source on each release; the full line-by-line assessment lives in `itflow-api-compatibility.md`. Current summary, as of **ITFlow 26.12** (agent v8.2.3+ requires 26.12 for header auth; earlier points below carried over from the 26.11.2 review against agent v8.2.0+):

- **API key model (ITFlow 26.08+, required):** keys are owned by a user and inherit that user's role/module/client permissions — they no longer carry their own scope, and every pre-26.08 key was deleted by that upgrade. Issue a new key under **Admin Settings > API Keys**, against a user with asset read/write, contact read, and ticket create on every client this agent syncs into. Keys also carry an expiry date; the agent reports `AUTH FAILURE` identically for an invalid or expired key (ITFlow does not distinguish the two in its response).
- **Transport is header-only as of v8.2.3:** ITFlow 26.12 added `X-API-Key` header authentication and deprecated the old query-string/body form (still functional there for now, behind an **Admin > Settings > Security > "Take API keys in the address"** toggle, but slated for removal). The agent sends `X-API-Key` as an HTTP header on every request and no longer puts `api_key` on the query string or in the JSON body — this requires **ITFlow 26.12 or later**; a server on an older version has no header-auth support and will reject every call with v8.2.3, so such servers' agents must stay on v8.2.2 until the server is upgraded. The key no longer appears in the web server access log as a result (previously mitigated server-side via `docs.itflow.org/api_apache-logging`).
- **Permissions are enforced per-call (403):** the agent parses ITFlow's "needs *Level* on *Module*" wording and logs exactly which role change to make; this is not an invalid key and reissuing one will not help.
- **Asset details (`asset_specs`) and the `Display` asset type** are both used from 26.11 onward (see [§5.5](#55-asset-type-detection) and [§5.7](#57-external-display-asset-matching)).
- **ITFlow's native Transfer to Client** (which archives the original and creates a new asset ID) is fully handled — see [§5.3](#53-transfer-following).

Not yet adopted (tracked for a future release): `tickets/resolve.php` / ticket close (to auto-resolve the agent's own tickets when a condition clears) and `contacts/create.php` (to create a missing contact rather than only ticketing about it).

---

# 13. Development

## Adding new preferences

1.  Add the preference to the Config dialog (checkbox, read value at open, write at save)
2.  Add to the INI `[Preferences]` section in the save handler's here-string
3.  Add a `Set-PreferenceDword` call if registry persistence is needed
4.  Add the startup read near the top-level preference block (before the silent handler)
5.  Wire the variable into the relevant sync logic

## Adding new feature flags

New capabilities gated by `$Enable*`/`$Push*` variables (e.g., `$PushAssetSpecs`, `$PushDisplaySpecs`, `$TicketUnmatchedDisplays`) should:

1.  Declare the flag near the top of the Global Variables section
2.  Pick a default that preserves existing behavior for upgrading installs
3.  Guard the feature logic with `if ($Enable*)`/`if ($Push*)` checks
4.  Add any associated persistence values to the Preferences, Cache, or State subkeys

## Adding new ticket types

1.  Build the ticket body with the `New-ITFlowTicket*` HTML helpers (key/value table, list table, section, paragraph) rather than a hand-built string — see `Create-ITFlowTicket`'s existing call sites for the pattern
2.  Add a `Create-ITFlowTicket` call at the appropriate location
3.  Gate it behind `if ($EnableTicketingSilent)` unless it should fire independent of the ticketing toggle (as the missing-contact ticket does)
4.  Add the ticket title and trigger condition to §7 of this manual
5.  Use `Test-TicketFlag` / `Set-TicketFlag` for deduplication

## Adding new API failure handling

1.  Route new failure paths through `Invoke-ITFlowChecked` / `Register-ITFlowFailure` rather than logging a bare message, so they inherit auth/permission classification automatically
2.  If a new HTTP status or message pattern needs recognizing, extend `Get-ITFlowFailureKind`
3.  Re-verify against `itflow-api-compatibility.md` and the live ITFlow API reference before relying on new response fields

---

*Last updated: 2026-11-23. Generated for ITFlow Agent v8.2.3. For the per-release history, see `CHANGELOG.md`; for the security assessment, see `hardening.md`; for ITFlow server-version compatibility notes, see `itflow-api-compatibility.md`.*
