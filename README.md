# ITFlow Agent — User Manual

## Version 7.1 | PowerShell 5.1 | Windows

---

# 1. Introduction

ITFlow Agent is a PowerShell-based tool that syncs Windows machine inventory to [ITFlow](https://itflow.org), an open-source IT documentation, ticketing, and accounting system for small MSPs. It handles automatic device enrollment, hostname synchronization, client transfer detection, and scheduled background syncing.

## What it does
- Collects local hardware inventory (CPU, RAM, disks, displays, network)
- Looks up the machine by serial number in ITFlow
- Creates a new asset if none exists (enrollment)
- Updates existing assets with current hardware info
- Detects when an asset has been transferred to another ITFlow client
- Queues and executes computer renames when the hostname differs from ITFlow
- Creates tickets in ITFlow for enrollments, renames, conflicts, and transfers
- Can run on a schedule via Windows Task Scheduler

## Requirements
- Windows 7 / Server 2008 R2 or later
- PowerShell 5.1
- Network access to ITFlow server
- ITFlow API key (all-clients or client-specific)
- Administrative rights for: scheduled tasks, computer rename, registry writes

---

# 2. Installation

## 2.1 Quick Start (GUI)

1. Run the script: `.\ITFlow-Agent-v7.1.ps1`
2. Click **Config** and enter:
   - **ITFlow Base URL**: `https://itflow.yourdomain.com`
   - **Client ID**: The ITFlow client ID this machine belongs to
   - **API Key**: Your ITFlow API key
3. Click **Save**
4. Click **Test API** to verify connectivity
5. Click **Run / Sync** to perform the first sync

## 2.2 Quick Start (Silent / Scheduled Task)

```powershell
# One-line setup (run as Administrator):
.\ITFlow-Agent-v7.1.ps1 -Install
```

This writes config to registry, copies the script to `C:\ProgramData\ITFlow\ITFlow-Agent.ps1`, and creates a scheduled task that runs the agent at every system startup.

For GPO deployment: pre-configure registry keys, then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "\\server\share\ITFlow-Agent-v7.1.ps1" -Install
```

On subsequent GPO runs (same version), the `-Install` switch detects the installed version matches and only triggers the task without re-copying.

## 2.3 Manual Uninstall

**GUI**: Click the **Uninstall** button (appears after installation).

**Command line**: 
```powershell
.\ITFlow-Agent-v7.0.ps1 -Uninstall
```
Removes the scheduled task, all registry keys under `HKLM:\SOFTWARE\ITFlow`, and the `C:\ProgramData\ITFlow` folder.

---

# 3. Configuration

## 3.1 Config Dialog

Click **Config** in the GUI to open the settings window.

### ITFlow Settings
| Field | Description |
|-------|-------------|
| **ITFlow Base URL** | Full URL to your ITFlow instance (e.g., `https://itflow.example.com`) |
| **Client ID** | Numeric ITFlow client ID this machine belongs to |
| **API Key** | Your API key (displayed masked) |

### Agent Options

| Option | Default | Description |
|--------|---------|-------------|
| **Create Tickets** | ON | Creates ITFlow tickets for enrollment, rename, conflicts, and transfers |
| **Follow Client Transfers** | ON | Automatically follows asset when moved to another ITFlow client |
| **Auto-update ClientId on Transfer** | ON | Persists the new ClientId after a transfer so future syncs target the new client |

### Defaults Button
Resets all agent options to default (ON). ITFlow connection settings are preserved. After save, the Device Overview panel refreshes immediately to reflect the new configuration.

## 3.2 Portable Mode (USB / Ad-hoc)

When run from a USB stick or non-elevated, the agent detects that the registry is unavailable and switches to **portable mode**:

- All data is stored in `ITFlow-AssetManager.ini` alongside the script
- No registry writes are attempted
- Config, preferences, state, cache, and ticket flags are all stored in the INI file
- The INI file follows standard section format:
  ```ini
  [ITFlow]
  BaseUrl=https://itflow.example.com
  ClientId=11
  ApiKey=...

  [Preferences]
  CreateTicketsGui=1
  FollowClientTransfers=1
  AutoUpdateClientIdOnTransfer=1

  [State]
  LastSyncOK=1
  LastRunAt=2026-05-13 12:00:00

  [Cache]
  LastSentMAC=00:11:22:33:44:55

  [TicketFlags]
  Enrollment=1
  ```

- The `[ITFlow]` section is written by the Config dialog and updated by `Set-ConfiguredClientId` on transfer.
- All other sections are managed automatically by the agent's helper functions.

---

# 4. Usage

## 4.1 GUI Mode

Run without switches: `.\ITFlow-Agent-v7.1.ps1`

### Window Layout
The GUI is a single compact window with three areas stacked vertically. Window width is locked on first display; height expands when details are shown.

**Header row** (always visible): Left-aligned action buttons, right-aligned Config button.

**Status bar** (always visible): Shows current operation state and notifications. Color-coded:
- Gray — Idle
- DarkGoldenrod — Sync in progress / rename available
- DarkGreen — Sync completed successfully  
- DarkRed — Sync error
- DarkOrange — Notification (rename pending)

**Details panel** (collapsed by default, toggled with "Show Details"): Contains the Device Overview table and full Log.

### Header Buttons

| Button | Description |
|--------|-------------|
| **Test API** | Sends a GET to `clients/read.php` to verify connectivity. Updates status bar to green (success) or red (failure). |
| **Run / Sync** | Starts an async sync in a background runspace. Button text changes to **Cancel Sync** while running. The GUI remains responsive — log updates in real time via file tailing. |
| **Install / Uninstall** | Installs: writes config to registry (if elevated), copies script to `C:\ProgramData\ITFlow\`, creates at-startup scheduled task, triggers it immediately. Uninstalls: removes task, registry keys, `C:\ProgramData\ITFlow` folder. Toggles label based on whether the scheduled task exists. Self-elevates if not admin. |
| **Open SysInfo** | Opens the latest sysinfo JSON file in Notepad. |
| **View SysInfo** | Parses the latest sysinfo JSON and shows a formatted dialog with hardware summary (CPU, RAM, disks, displays, network adapters). |
| **Rename** | Enabled after a sync detects the ITFlow asset name differs from the local hostname (orange status bar). Starts the rename process. If not elevated, shows instructions to run as administrator. |
| **Config** | Opens the Settings dialog. Disabled during sync. |

### Status Bar
Single-line label with color-coded status messages. Auto-truncates if the message exceeds the window width.

Common messages:
- `STATUS: Idle` (gray)
- `STATUS: Running sync...` (gold)
- `STATUS: Success` (green)
- `STATUS: Error` (red — error details in log panel)
- `STATUS: Rename available: <hostname>` (orange)
- `STATUS: Previous rename failed - manual intervention required` (red)
- `STATUS: Rename pending - reboot required` (orange)
- `STATUS: Cancelled` (gray)

### Config Dialog
Opened by the **Config** button. Two sections:

**ITFlow Settings:**
- ITFlow Base URL — text field (full URL, e.g. `https://itflow.example.com`)
- Client ID — numeric text field
- API Key — masked password field

**Agent Options:** (three checkboxes)
- **Create Tickets** — enables/disables all ticket creation (enrollment, rename, conflicts, transfers)
- **Follow Client Transfers** — auto-follow when asset serial found in another client
- **Auto-update ClientId on Transfer** — persist the new ClientId after a transfer follow

**Bottom buttons:**
- **Defaults** — resets all three checkboxes to ON, strips INI/registry of all `[Preferences]`, `[State]`, `[Cache]`, `[TicketFlags]` sections. Preserves `BaseUrl`, `ClientId`, `ApiKey`.
- **Save** — writes everything, calls `Refresh-OverviewUI` to update the Device Overview immediately, closes dialog.
- **Cancel** — closes dialog without saving.

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
| `-Install` | Install the agent: write config to registry, copy script to `C:\ProgramData\ITFlow\`, create scheduled task. |
| `-Uninstall` | Remove the agent: delete task, registry keys, and `C:\ProgramData\ITFlow`. |
| `-TaskScriptPath` | Specify the script path for the scheduled task (required for GPO deployment). |
| `-Reboot` | After successful rename in silent mode, reboot the computer (60s delay). |
| `-Worker` | Internal flag used by the GUI's async engine. Not for direct use. |

### Examples
```powershell
# Run once, sync and rename if needed (for scheduled task):
powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\ITFlow\ITFlow-Agent.ps1" -Silent -Rename

# Install from network share:
powershell.exe -ExecutionPolicy Bypass -File "\\server\share\ITFlow-Agent-v7.0.ps1" -Install -TaskScriptPath "C:\ProgramData\ITFlow\ITFlow-Agent.ps1"
```

## 4.3 Scheduled Task

When installed via the **Install** button or `-Install` switch, a task named `ITFlow-Agent-Sync` is created:

| Property | Value |
|----------|-------|
| **Trigger** | At startup (resets to startup after successful sync) |
| **Action** | `powershell.exe -ExecutionPolicy Bypass -File "C:\ProgramData\ITFlow\ITFlow-Agent.ps1" -Silent -Rename -Worker` |
| **Run as** | SYSTEM |
| **Run with highest privileges** | Yes |
| **Execution time limit** | 15 minutes (default is 3 days) |

The `-Worker` flag in the task action skips the single-instance mutex, allowing the task to run even if another instance is exiting. After installation, the task is triggered immediately via `Start-ScheduledTask` with a `schtasks.exe /run` fallback.

### Retry on Failure
If the sync fails (ITFlow unreachable), the task trigger switches to:
- **First run**: 1 hour from failure time
- **Repetition**: Every 1 hour
- **Duration**: Up to 24 hours

Once a sync succeeds, the trigger reverts to at-startup.

---

# 5. Sync Flow

## 5.1 What happens during a sync

1. **Local inventory collection**: BIOS serial, hostname, manufacturer, model, OS, MAC, IP
2. **Sysinfo snapshot**: CPU, RAM, disks, displays, network — saved as JSON to `C:\ProgramData\ITFlow\sysinfo_<hostname>.json`
3. **Connectivity check**: Up to 5 attempts, 30 seconds apart
4. **Asset lookup**: Search ITFlow by serial number in the configured client
5. **If asset found**:
   - Update local truth: type, make, model, OS, status, MAC, IP
   - Check hostname mismatch → queue rename if needed
6. **If asset not found in configured client**:
   - Global search by serial (all clients)
   - If found in another client → **follow transfer** (update ClientId, create tickets)
     - **The sync automatically re-enters the update path** — the transferred asset's hostname check, rename detection, and field update all happen in the same sync run, no second sync needed
   - If not found at all → enroll (create new asset, create ticket)
7. **Result**: `LastSyncOK` persisted to registry/INI. Hourly retry task created/removed based on result.

## 5.2 Enrollment
When a machine's serial number doesn't exist anywhere in ITFlow, the agent:
1. Creates a new asset in the configured client
2. Sets asset name to local hostname
3. Populates type, make, model, OS, serial, IP, MAC, status
4. Creates an `[ENROLL]` ticket

## 5.3 Transfer Following
When an asset's serial exists in a different ITFlow client:
1. Creates `[TRANSFER DETECTED]` ticket in the originating client
2. Updates the effective ClientId to the destination client
3. Optionally persists the ClientId change (Auto-update ClientId on Transfer)
4. Creates `[TRANSFER FOLLOWED]` ticket in the receiving client
5. Continues update sync with the new client context

---

# 6. Rename Handling

## 6.1 How rename works
1. Sync detects hostname mismatch between local machine and ITFlow asset name
2. Preflight checks run:
   - **ITFlow duplicate**: Is another asset already using this hostname?
   - **AD duplicate**: Does a computer account already exist with this name?
3. If preflight blocks: creates `[RENAME CONFLICT]` ticket, skips rename
4. If preflight passes:
   - **GUI mode**: Enable "Rename" button in the status bar
   - **Silent mode with `-Rename`**: Automatically calls `Rename-Computer`

## 6.2 Rename button (GUI)
- Appears when a queued rename target is available (orange status bar)
- Requires administrator privileges
- If not elevated, shows instructions to run as admin
- After successful rename: offers to reboot immediately

## 6.3 Silent rename (`-Silent -Rename`)
- Tries `Rename-Computer -Force -Restart:$false`
- If fails with credential error and `netdom` is available: falls back to `netdom renamecomputer`
- Sets `RenameFailed_<target>` flag to prevent re-attempting on every sync
- Creates `[RENAME FAILED]` ticket if ticketing is enabled

## 6.4 Preflight Checks
Before any rename attempt, two safety checks run. Both must pass or the rename is blocked with a `[RENAME CONFLICT]` ticket:

- **ITFlow duplicate name**: Queries the ITFlow API for the target hostname within the effective client. If another asset already has that name, the rename is blocked.
- **AD computer account**: Searches Active Directory for a computer object with the target hostname. If one exists, the rename is blocked. If AD is unreachable (non-domain, DNS failure), this check passes silently.

## 6.5 Pending Rename Detection
`Test-PendingComputerRename` compares the currently active computer name (in memory) with the pending name (in the registry, set by a previous `Rename-Computer` that hasn't rebooted yet). If they differ, the GUI shows "Rename pending - reboot required" and disables the Rename button until the machine is restarted.

## 6.6 Rename Button State Logic
After every sync and on GUI startup:
1. Check for pending reboot rename → if found, show notification and disable button
2. Read `LastRenameRequired` and `LastTargetHostname` from State → if queued and sync not running → enable button
3. Check `RenameFailed_<target>` ticket flag → if set (previous rename failed), show "Previous rename failed — manual intervention required" and disable button

---

# 7. Ticket Reference

| Ticket Title | Trigger | Linked To |
|-------------|---------|-----------|
| `[ENROLL]` | New asset created | Serial → asset lookup |
| `[RENAME]` | Rename initiated (GUI or silent) | Asset ID |
| `[RENAME FAILED]` | Rename-Computer threw an exception | Asset ID |
| `[RENAME CONFLICT]` | Preflight check blocked rename | Asset ID |
| `[TRANSFER DETECTED]` | Serial found in originating client before transfer | Serial → asset lookup |
| `[TRANSFER FOLLOWED]` | Serial now in receiving client after transfer | Asset ID |

All tickets are suppressed when **Create Tickets** is unchecked.

---

# 8. File Locations

| Path | Purpose |
|------|---------|
| `C:\ProgramData\ITFlow\` | Installed agent directory |
| `C:\ProgramData\ITFlow\ITFlow-Agent.ps1` | Deployed script (scheduled task target) |
| `C:\ProgramData\ITFlow\Logs\` | Sync log files |
| `C:\ProgramData\ITFlow\SysinfoArchive\` | Historical sysinfo JSON snapshots |
| `HKLM:\SOFTWARE\ITFlow\` | Registry config (installed mode) |
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
| Enrollment creates duplicate asset | Asset exists in another client | Transfer it back or delete the duplicate in ITFlow |
| Rename fails "Access is denied" | Process not elevated | Run as Administrator or use the GUI elevate prompt |
| Rename fails "Wrong username or password" | SYSTEM account can't authenticate to AD | The `netdom` fallback handles this automatically |
| Config changes not saving | Non-elevated, INI locked | Config is saved in memory; retry the save. If persistent, check if INI file is read-only. |
| "Portable mode" message | Registry unavailable or non-elevated | Normal for USB/ad-hoc use. All data goes to INI file. |
| Scheduled task not running | Missing permissions | Task runs as SYSTEM. Check that `C:\ProgramData\ITFlow\ITFlow-Agent.ps1` exists. |

## 9.2 Logs
Log files are written to `C:\ProgramData\ITFlow\Logs\<hostname>-<timestamp>.log`. Each sync run creates a new log file. The GUI's log panel tails the latest log file in real time.

## 9.3 First Run (Elevated)

When running `-Install` or the GUI elevated on a clean machine, the registry key `HKLM:\SOFTWARE\ITFlow` doesn't exist yet. The agent detects that you're elevated and creates the key and all subkeys automatically, then promotes the INI-based config to the registry. The "Portable mode" message is suppressed and `$script:RegistryAllowed` is set to `$true` for the session.

This means `-Install` on a clean elevated machine will:
1. Read config from the INI file (next to the script)
2. Create registry keys
3. Write BaseUrl, ClientId, ApiKey to the registry
4. Copy the script to `C:\ProgramData\ITFlow\`
5. Install the scheduled task
6. Trigger the task immediately for the first sync

## 9.4 Startup Log
The first line of every log shows the execution context:
```
ITFlow Agent v7.0 starting (mode=Install, rename=False, elevated=yes)
```
Modes: `GUI` (WinForms), `Worker` (GUI async engine), `Silent` (scheduled task / console), `Install` (setup), `Uninstall` (removal).

## 9.5 API Key Hardening
When the agent loads config from the registry and finds an ApiKey that isn't DPAPI-encrypted (plaintext), it automatically re-encrypts it using `LocalMachine`-scoped DPAPI. This upgrades keys stored by older agent versions or manual registry edits. Requires elevation to write back to the registry.

## 9.6 Sync Comparison Logging
During every sync, `Log-LocalVsITFlowVerbose` logs a detailed before/after comparison of all tracked fields between the local machine and the ITFlow asset record. This fires once per sync run and is the primary diagnostic tool for verifying sync is working correctly.

---

# 10. Architecture Notes

## 10.1 Registry vs INI
The agent uses a `$script:RegistryAllowed` flag to determine storage backend:
- `$true` → All reads/writes go to `HKLM:\SOFTWARE\ITFlow\*` subkeys
- `$false` → All reads/writes go to `ITFlow-AssetManager.ini` sections

This flag is set once at startup: `(Test-Path $RegRoot) -and (Test-IsAdmin)`.

## 10.2 Process Model
- GUI mode launches syncs in a background runspace pool (one runspace at a time)
- The runspace calls the script with `-Silent -Worker -LogPath <shared_log>`
- Worker mode skips the single-instance mutex
- Worker mode uses `return` instead of `exit` to avoid killing the host process

## 10.3 Versioning
- Version is stored in `$AgentVersion` at the top of the script
- The `-Install` switch detects installed version by reading `$AgentVersion` from the deployed copy
- If the version differs, the script is re-copied and the task re-registered

---

# 11. Development

## Adding new preferences
1. Add the preference to the Config dialog (checkbox, read value at open, write at save)
2. Add to the INI `[Preferences]` section in the save handler's here-string
3. Add a `Set-PreferenceDword` call if registry persistence is needed
4. Add the startup read at line 2384 (before the silent handler)
5. Wire the variable into the relevant sync logic

## Adding new ticket types
1. Add a `Create-ITFlowTicket` call at the appropriate location
2. Gate it behind `if ($EnableTicketingSilent)`
3. Add the ticket title and trigger condition to this manual

---

*Last updated: 2026-05-13. Generated for ITFlow Agent v7.0.*
