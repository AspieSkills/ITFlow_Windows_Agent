# =====================================================
# ITFlow PowerShell Agent
# version - 8.2.2
# PowerShell 5.1 Compatible
# =====================================================

param(
    [switch]$Silent,
    [switch]$Rename,

    # NEW: internal worker-mode for background runspace execution
    [switch]$Worker,

    # NEW: allow the GUI to force the worker to use the same log file
    [string]$LogPath,

    # NEW: install or uninstall the daily scheduled task
    [switch]$Install,
    [switch]$Uninstall,

    # NEW: path the scheduled task should point to (defaults to current script location)
    [string]$TaskScriptPath,

    # NEW: reboot after successful rename (headless mode only)
    [switch]$Reboot
)


# =====================================================
# EXECUTION CONTEXT FLAGS (CRITICAL FIX)
# =====================================================
$IsHeadlessExecution = $Silent
$script:IsWorkerRunspace = $Worker
$AllowUserInteraction = (-not $IsHeadlessExecution) -and (-not $script:IsWorkerRunspace)

# True only when this process runs as the LocalSystem account (the startup scheduled task).
# Security hardening (v7.5.5) gates its fail-closed self-checks on this so GUI/portable runs,
# which never do privileged startup work, are never blocked.
$script:IsSystemContext = try { [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { $false }

#===============================
#  Global Variables
#===============================

# Agent version
$AgentVersion = "8.2.2"

# Current asset context for ticket linking (set during sync runs)
$script:CurrentAssetId = $null

# Ticketing feature switches - overridden by GUI preference or registry
$EnableTicketingSilent = $true
$EnableTicketingGui    = $true
$DefaultAssetStatus    = "Deployed"

# Asset Transfer Handling (Client Follow)
$AllowFollowClientTransfer = $true
$CreateTransferMismatchTicket = $false

# Rename Safety Checks
$EnableRenamePreflightITFlowDupCheck = $true
$EnableRenamePreflightADCheck        = $true
$EnableRenameFailureTicketing        = $true

# Auto-update configured ClientId when transfer-follow occurs (all-client scoped API key environments)
$AutoUpdateClientIdOnTransfer = $true

# Dynamic Contact Assignment from User Logon Activity
$AssignContactFromLogons = $false
$AssignContactLookbackDays = 90
$AssignContactHalfLifeDays = 14
$AssignContactAllowedDomain = ""

# Priority sent on every ticket the agent raises. ITFlow 26.09 changed the default
# applied when none is given - its changelog says Medium, the API reference still
# says Low - so the agent states the value rather than inheriting either. "Low" keeps
# the behaviour agent tickets had before 26.09. Valid: Low, Medium, High.
$TicketPriority = "Low"

# Verbose debug logging (gated by checkbox; useful for diagnosing event log / contact issues)
$VerboseLogging = $false

# Scheduled task name for -Install / -Uninstall
$TaskName = "ITFlow-Agent-Sync"

$script:LastRunState = [pscustomobject]@{
    RanAt              = ""
    Hostname           = ""
    Serial             = ""
    DetectedType       = ""
    PrimaryIP          = ""
    PrimaryMAC         = ""
    ConfigClientId     = ""
    EffectiveClientId  = ""
    AssetId            = ""
    TransferFollowed   = $false
    ClientIdAutoUpdated= $false
    SysInfoPath        = ""
    SysInfoCollectedAt = ""
    RenameRequired     = $false
    TargetHostname     = ""
    AuthFailed         = $false
    AuthFailureReason  = ""
    PermissionDenied   = $false
    PermissionReason   = ""
    AssetArchived      = $false
    KeyScope           = ""
}

# ITFlow 26.08: API keys are owned by a user and inherit that user's role, module
# and client permissions. These hold what the current key was observed to be able
# to do, so the run can log when transfer detection is operating blind.
$script:ApiKeyScope = $null
$script:AuthFailureReason = $null
$script:PermissionFailureReason = $null
# asset_specs computed from the snapshot once per Run-AssetSync
$script:LocalAssetSpecs = [ordered]@{}
$script:AssetSpecsUnsupportedLogged = $false
# Chassis/PCSystemType behind the last Get-AssetType answer (debug logging)
$script:LastChassisInfo = ""


# Prevent duplicate Local vs ITFlow compare blocks per run
$script:LoggedLocalVsITFlow = $false
$script:SetAssetNameOnce = $false

# Sync result tracking for silent-mode retry logic
$script:LastSyncOK = $true




# =====================================================
# ASYNC SYNC CONTROL (Added)
# -----------------------------------------------------
# Runs sync off the UI thread and enables graceful cancellation.
# Cancel is responsive even during retry sleeps (1 second granularity).
# =====================================================
$script:SyncRunning         = $false
$script:CancelSyncRequested = $false

function Throw-IfCancelRequested {
    if ($script:CancelSyncRequested) {
        throw "SYNC_CANCELLED_BY_USER"
    }
}

function Start-SleepCancelAware {
    param([Parameter(Mandatory=$true)][int]$Seconds)

    for ($i = 0; $i -lt $Seconds; $i++) {
        Throw-IfCancelRequested
        Start-Sleep -Seconds 1
    }
}
#======================================
# Rename Conflict Flag Resolver Helper
#======================================

function Clear-RenameFlags {
    param(
        [Parameter(Mandatory=$true)][string]$DesiredHostname
    )

    $conflictFlag = "RenameConflict_$DesiredHostname"
    $failedFlag   = "RenameFailed_$DesiredHostname"
    $initFlag     = "RenameInitiated_$DesiredHostname"

    Clear-TicketFlag $conflictFlag
    Clear-TicketFlag $failedFlag
    Clear-TicketFlag $initFlag
}


#===============================
# Asset Transfer Mismatch Helper
#===============================

function Write-AssetTransferLog {
    param(
        [string]$Serial,
        [string]$Hostname,
        [int]$ConfiguredClientId,
        [int]$DiscoveredClientId,
        [int]$DiscoveredAssetId
    )

    Log ("TRANSFER_DETECTED serial='{0}' hostname='{1}' configured_client_id='{2}' discovered_client_id='{3}' discovered_asset_id='{4}' action='{5}'" -f `
        $Serial, $Hostname, $ConfiguredClientId, $DiscoveredClientId, $DiscoveredAssetId, `
        ($(if ($AllowFollowClientTransfer) { "FOLLOW" } else { "ABORT" })))
}

# ===============================
# Unified Asset Transfer Follow
# ===============================
function Invoke-AssetTransferFollow {
    param(
        [Parameter(Mandatory=$true)][pscustomobject]$Inv,
        [Parameter(Mandatory=$true)][int]$DiscoveredClientId,
        [Parameter(Mandatory=$true)][int]$DiscoveredAssetId,
        [string]$DeviceSpec = ""
    )

    $origClientId = if ($Config.ClientId) { [int]$Config.ClientId } else { 0 }
    Write-AssetTransferLog -Serial $Inv.Serial -Hostname $Inv.Hostname `
        -ConfiguredClientId $origClientId -DiscoveredClientId $DiscoveredClientId -DiscoveredAssetId $DiscoveredAssetId

    # Set CurrentAssetId before any ticket creation so Create-ITFlowTicket can
    # use $script:CurrentAssetId as a fallback for asset linking.
    $script:CurrentAssetId = $DiscoveredAssetId

    if (-not $AllowFollowClientTransfer -or $DiscoveredClientId -le 0) {
        Log "WARNING: Serial '$($Inv.Serial)' exists in ITFlow under client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId). Aborting."
        if ($CreateTransferMismatchTicket) {
            $title = "[TRANSFER DETECTED] $($Inv.Hostname) | Serial: $($Inv.Serial) moved to client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
            $infoPairs = [ordered]@{
                "Configured Client ID" = $origClientId
                "Discovered Client ID" = $DiscoveredClientId
                "Discovered Asset ID"  = $DiscoveredAssetId
                "Serial"               = $Inv.Serial
                "Hostname"             = $Inv.Hostname
                "Blocked"              = "AllowFollowClientTransfer=$false"
            }
            $details = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
                (New-ITFlowTicketSection -Title "Transfer Detected" -Icon "🔀" -InnerHtml (New-ITFlowTicketKeyValueTable $infoPairs))
            )
            # Do NOT pass -AssetId here: the asset belongs to $DiscoveredClientId, not $origClientId.
            # Cross-client asset linking would be rejected by the API.
            Create-ITFlowTicket -Title $title -ClientId $origClientId -Details $details | Out-Null
        }
        $script:CurrentAssetId = $null
        return [pscustomobject]@{ Followed = $false }
    }

    if ($EnableTicketingSilent) {
        $title = "[TRANSFER DETECTED] $($Inv.Hostname) | Serial: $($Inv.Serial) moved to client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
        $infoPairs = [ordered]@{
            "Original Client ID"   = $origClientId
            "Discovered Client ID" = $DiscoveredClientId
            "Discovered Asset ID"  = $DiscoveredAssetId
            "Serial"               = $Inv.Serial
            "Hostname"             = $Inv.Hostname
        }
        $details = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
            (New-ITFlowTicketSection -Title "Transfer Detected" -Icon "🔀" -InnerHtml (New-ITFlowTicketKeyValueTable $infoPairs))
        )
        # Do NOT pass -AssetId here: the asset belongs to $DiscoveredClientId, not $origClientId.
        # Cross-client asset linking would be rejected by the API.
        Create-ITFlowTicket -Title $title -ClientId $origClientId -Details $details | Out-Null
    }

    $script:LastRunState.TransferFollowed = $true

    if ($AutoUpdateClientIdOnTransfer -and $DiscoveredClientId -ne $origClientId) {
        Log "Auto-update enabled: persisting ClientId change $origClientId -> $DiscoveredClientId"
        $persistOk = Set-ConfiguredClientId -NewClientId $DiscoveredClientId
        if ($persistOk) { $script:LastRunState.ClientIdAutoUpdated = $true }
    }

    if ($EnableTicketingSilent) {
        $title = "[TRANSFER FOLLOWED] $($Inv.Hostname) | Serial: $($Inv.Serial) now in client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
        $infoPairs = [ordered]@{
            "Original Client ID" = $origClientId
            "New Client ID"      = $DiscoveredClientId
            "Asset ID"           = $DiscoveredAssetId
            "Serial"             = $Inv.Serial
            "Hostname"           = $Inv.Hostname
            "Auto-Update"        = $AutoUpdateClientIdOnTransfer
        }
        $details = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
            (New-ITFlowTicketSection -Title "Transfer Followed" -Icon "🔀" -InnerHtml (New-ITFlowTicketKeyValueTable $infoPairs))
        )
        Create-ITFlowTicket -Title $title -ClientId $DiscoveredClientId -AssetId $DiscoveredAssetId -Details $details | Out-Null
    }

    Log "Following transfer: EffectiveClientId updated to $DiscoveredClientId (asset_id=$DiscoveredAssetId)"

    return [pscustomobject]@{ Followed = $true; DiscoveredClientId = $DiscoveredClientId; DiscoveredAssetId = $DiscoveredAssetId }
}

function Get-SysInfoSummaryText {
    param([string]$Path = "C:\ProgramData\ITFlow\sysinfo_$($env:COMPUTERNAME).json")

    if (-not (Test-Path $Path)) { return $null }

    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }

    $sb = New-Object System.Text.StringBuilder

    $null = $sb.AppendLine("SysInfo Summary")
    $null = $sb.AppendLine("==============")
    $null = $sb.AppendLine("File:     $Path")
    if ($obj.Meta) {
        $null = $sb.AppendLine("Collected: $($obj.Meta.CollectedAt)")
        $null = $sb.AppendLine("Agent:     $($obj.Meta.AgentVersion)")
    }
    $null = $sb.AppendLine("")

    if ($obj.Device) {
        $null = $sb.AppendLine("Device"); $null = $sb.AppendLine("------")
        $null = $sb.AppendLine("Hostname:   $($obj.Device.Hostname)")
        $null = $sb.AppendLine("Serial:     $($obj.Device.Serial)")
        $null = $sb.AppendLine("Make/Model: $($obj.Device.Make) / $($obj.Device.Model)")
        $null = $sb.AppendLine("OS:         $($obj.Device.OS)")
        $null = $sb.AppendLine("Type:       $($obj.Device.AssetType)")
        $null = $sb.AppendLine("MAC:        $($obj.Device.PrimaryMAC)")
        $null = $sb.AppendLine("IP:         $($obj.Device.PrimaryIP)"); $null = $sb.AppendLine("")
    }
    if ($obj.CPU) {
        $null = $sb.AppendLine("CPU"); $null = $sb.AppendLine("---")
        $null = $sb.AppendLine("Name:       $($obj.CPU.Name)")
        $null = $sb.AppendLine("Cores/CPU:  $($obj.CPU.CoreCount) / $($obj.CPU.LogicalCount)")
        $null = $sb.AppendLine("Max MHz:    $($obj.CPU.MaxClockMHz)"); $null = $sb.AppendLine("")
    }
    if ($obj.Memory) {
        $null = $sb.AppendLine("Memory"); $null = $sb.AppendLine("------")
        $null = $sb.AppendLine("Total GB:   $($obj.Memory.TotalGB)"); $null = $sb.AppendLine("")
    }
    if ($obj.Storage -and $obj.Storage.Totals) {
        $null = $sb.AppendLine("Storage"); $null = $sb.AppendLine("-------")
        $null = $sb.AppendLine("Physical Total GB: $($obj.Storage.Totals.PhysicalTotalGB)")
        $null = $sb.AppendLine("Volume Total GB:   $($obj.Storage.Totals.VolumeTotalGB)"); $null = $sb.AppendLine("")
    }
    if ($obj.Displays) {
        $null = $sb.AppendLine("Displays"); $null = $sb.AppendLine("--------")
        $null = $sb.AppendLine("Count: $(@($obj.Displays).Count)"); $null = $sb.AppendLine("")
    }
    if ($obj.Network -and $obj.Network.Adapters) {
        $null = $sb.AppendLine("Network"); $null = $sb.AppendLine("-------")
        $null = $sb.AppendLine("Adapters: $(@($obj.Network.Adapters).Count)"); $null = $sb.AppendLine("")
    }

    return $sb.ToString()
}

function Show-SysInfoSummary {
    $path = "C:\ProgramData\ITFlow\sysinfo_$($env:COMPUTERNAME).json"
    $text = Get-SysInfoSummaryText -Path $path

    if ($null -eq $text) {
        [System.Windows.Forms.MessageBox]::Show(
            "Sysinfo file not found or unreadable:`r`n$path",
            "SysInfo",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "SysInfo Summary"
    $f.StartPosition = "CenterParent"
    $f.Size = New-Object System.Drawing.Size(760, 520)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = "Vertical"
    $tb.Dock = "Fill"
    $tb.Font = New-Object System.Drawing.Font("Consolas", 10)
    $tb.Text = $text
    $f.Controls.Add($tb)

    $f.ShowDialog() | Out-Null
}


#============================
# SysInfo Collector Helpers
#============================

function Convert-EdidString {
    param([object[]]$Arr)

    if (-not $Arr) { return $null }

    # Handles arrays of bytes/ints/uint16; strips nulls and non-printables
    $chars = foreach ($v in $Arr) {
        $i = [int]$v
        if ($i -eq 0 -or $i -eq 65535) { continue }     # null/empty padding
        if ($i -lt 32 -or $i -gt 126) { continue }      # non-printable
        [char]$i
    }

    $s = ($chars -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Normalize-Mac {
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $Mac }
    return (($Mac -replace '-',':').ToUpper())
}


# ==========================================
# Duplicate Asset Name Helper
# ==========================================
function Test-ITFlowDuplicateAssetName {
    param(
        [Parameter(Mandatory=$true)][string]$DesiredHostname,
        [Parameter(Mandatory=$true)][int]$EffectiveClientId,
        [Parameter(Mandatory=$true)][int]$CurrentAssetId
    )

    try {
        # Query by exact asset name (client-scoped first to reduce noise)
        $uri = New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ client_id = $EffectiveClientId; asset_name = $DesiredHostname })
        $resp = Invoke-ITFlowChecked GET $uri $null "Asset name duplicate check"

        if ($resp -and "$($resp.success)" -eq "True" -and $resp.count -gt 0) {
            # Archived records don't hold a live name, so they don't block a rename.
            $others = @($resp.data | Where-Object { [int]$_.asset_id -ne $CurrentAssetId -and -not (Test-ITFlowAssetArchived $_) })
            if ($others.Count -gt 0) {
                return [pscustomobject]@{
                    IsDuplicate = $true
                    Count       = $resp.count
                    OtherAssetIds = ($others | ForEach-Object { [int]$_.asset_id })
                    OtherAssetSerials = ($others | ForEach-Object { [string]$_.asset_serial })
                }
            }
        }
    } catch {
        Log "ITFlow duplicate-name check failed (ignored): $($_.Exception.Message)"
    }

    return [pscustomobject]@{ IsDuplicate = $false; Count = 0; OtherAssetIds = @() }
}


# ==========================================
# computer account exists Helper
# ==========================================
function Test-ADComputerNameExists {
    param(
        [Parameter(Mandatory=$true)][string]$DesiredHostname
    )

    # Quick domain join check
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if (-not $cs.PartOfDomain) {
            return [pscustomobject]@{ IsDomainJoined = $false; Exists = $false; ExistingDN = $null }
        }
    } catch {
        return [pscustomobject]@{ IsDomainJoined = $false; Exists = $false; ExistingDN = $null }
    }

    # If we're domain joined but cannot query AD at runtime, treat as "unknown" not "exists"
    try {
        $domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()).Name
        $root = "LDAP://$domain"
        $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$root)
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$DesiredHostname`$))"
        $searcher.PropertiesToLoad.AddRange(@("distinguishedName", "serialNumber")) | Out-Null
        $result = $searcher.FindOne()

        if ($result -and $result.Properties["distinguishedname"]) {
            # PDC emulator verification (replication-lag guard for multi-DC environments)
            try {
                $domainObj = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
                $pdc = $domainObj.PdcRoleOwner
                $pdcRoot = "LDAP://$($pdc.Name)/$($domainObj.Name)"
                $pdcSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$pdcRoot)
                $pdcSearcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$DesiredHostname`$))"
                $pdcSearcher.PropertiesToLoad.AddRange(@("distinguishedName")) | Out-Null
                $pdcResult = $pdcSearcher.FindOne()
                if (-not $pdcResult) {
                    Log "AD conflict detected on local DC but not on PDC emulator ($($pdc.Name)) — replication lag, treating as non-conflict"
                    return [pscustomobject]@{ IsDomainJoined = $true; Exists = $false; ExistingDN = $null; ExistingSerial = "" }
                }
            } catch {
                Log "PDC verification unavailable (ignored): $($_.Exception.Message)"
            }
            $dn = $result.Properties["distinguishedname"][0]
            $existingSerial = if ($result.Properties.serialnumber) { $result.Properties.serialnumber[0] } else { "" }
            return [pscustomobject]@{ IsDomainJoined = $true; Exists = $true; ExistingDN = $dn; ExistingSerial = $existingSerial }
        }

        return [pscustomobject]@{ IsDomainJoined = $true; Exists = $false; ExistingDN = $null; ExistingSerial = "" }
    }
    catch {
        Log "AD check unavailable (ignored): $($_.Exception.Message)"
        return [pscustomobject]@{ IsDomainJoined = $true; Exists = $false; ExistingDN = $null; ADCheckFailed = $true; ExistingSerial = "" }
    }
}

# =====================================================
# AD Computer Attribute Sync Helper
# =====================================================
function Sync-ADComputerAttributes {
    param(
        [Parameter(Mandatory=$true)]$Snapshot,
        [string]$DeviceSpec = "",
        [string]$LastCheckIn = "",
        $ComputerSystem = $null
    )

    # Only attempt on domain-joined machines
    try {
        if (-not $ComputerSystem) { $ComputerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        if (-not $ComputerSystem.PartOfDomain) { Log "AD attribute sync skipped: not domain-joined"; return }
    } catch { return }

    try {
        $domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()).Name
        $root = "LDAP://$domain"
        $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$root)
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$env:COMPUTERNAME`$))"
        $searcher.PropertiesToLoad.AddRange(@("distinguishedName", "serialNumber", "description", "info"))
        $result = $searcher.FindOne()

        if (-not $result) {
            Log "AD attribute sync skipped: computer object not found"
            return
        }

        $computer = [ADSI]$result.Path

        # 1) serialNumber (try individually - not all schemas allow this on computer objects)
        $serial = $Snapshot.Device.Serial
        $currentSerial = if ($result.Properties.serialnumber) { $result.Properties.serialnumber[0] } else { "" }
        if ($currentSerial -ne $serial) {
            try {
                $computer.Put("serialNumber", $serial)
                $computer.SetInfo()
                Log "AD serialNumber: '$currentSerial' -> '$serial'"
            } catch {
                Log "AD serialNumber write skipped (non-fatal): $($_.Exception.Message)"
            }
        }

        # 2) description - compact summary string
        $parts = @()
        $parts += "$($Snapshot.Device.Make) $($Snapshot.Device.Model)"
        if ($Snapshot.CPU) { $parts += "$($Snapshot.CPU.Name)" }
        if ($Snapshot.Memory -and $Snapshot.Memory.TotalGB) { $parts += "$($Snapshot.Memory.TotalGB) GB RAM" }
        if ($Snapshot.Storage -and $Snapshot.Storage.Totals -and $Snapshot.Storage.Totals.PhysicalTotalGB) {
            $parts += "$($Snapshot.Storage.Totals.PhysicalTotalGB) GB Storage"
        }
        $parts += "$($Snapshot.Device.OS)"
        $description = $parts -join " | "

        $currentDesc = if ($result.Properties.description) { $result.Properties.description[0] } else { "" }
        if ($currentDesc -ne $description) {
            try {
                $computer.Put("description", $description)
                $computer.SetInfo()
                Log "AD description: '$currentDesc' -> '$description'"
            } catch {
                Log "AD description write failed (non-fatal): $($_.Exception.Message)"
            }
        }

        # 3) info (Notes) - full device specification block. $DeviceSpec is HTML
        # (built for tickets); AD's Notes field needs plain text.
        if ($DeviceSpec) {
            $infoValue = ConvertFrom-ITFlowHtmlToPlainText $DeviceSpec
            if ($LastCheckIn) { $infoValue += "`r`n`r`nLast Check-In: $LastCheckIn (Agent v$AgentVersion)" }
            $currentInfo = if ($result.Properties.info) { $result.Properties.info[0] } else { "" }
            if ($currentInfo -ne $infoValue) {
                try {
                    $computer.Put("info", $infoValue)
                    $computer.SetInfo()
                    Log "AD info (Notes) updated with check-in timestamp"
                } catch {
                    Log "AD info write failed (non-fatal): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Log "AD attribute sync failed (non-fatal): $($_.Exception.Message)"
    }
}


# =====================================================
# Device Report Ticket (GPO-triggered)
# =====================================================
function Invoke-DeviceReportCheck {
    param(
        [Parameter(Mandatory=$true)][string]$Hostname,
        [Parameter(Mandatory=$true)][string]$Serial,
        [Parameter(Mandatory=$true)][int]$ClientId,
        [Parameter(Mandatory=$true)][string]$DeviceSpec
    )

    $regPath = "$RegRoot\TicketFlags"
    $regName = "DeviceReport"
    $triggered = $false
    try {
        $val = (Get-ItemProperty -LiteralPath $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
        if ($val -eq 0) { $triggered = $true }
    } catch { }

    if ($triggered) {
        $title = "[DEVICE REPORT] $Hostname | Serial: $Serial"
        $details = New-ITFlowTicketBody -Sections @($DeviceSpec)
        Create-ITFlowTicket -Title $title -ClientId $ClientId -Serial $Serial -Details $details | Out-Null
        $flagOk = Set-TicketFlag $regName
        if ($flagOk) {
            Log "Device report ticket created for '$Serial'"
        } else {
            Log "WARN: Device report ticket created but flag write failed - may re-trigger on next sync"
        }
    }
}


# =========================
# Local Sysinfo Collection
# =========================
$EnableLocalSysInfo = $true
$SysInfoRoot        = "C:\ProgramData\ITFlow"
$SysInfoArchiveDir  = Join-Path $SysInfoRoot "SysinfoArchive"
$SysInfoKeep        = 20   # keep last 20 boots

# Single-instance guard (prevents overlapping runs)
# IMPORTANT: Worker mode runs inside the same process in a background runspace,
# so we must NOT block on the mutex there.
if (-not $Worker) {
    $mutexName = "Global\ITFlow-AssetManager"
    $script:mutex = New-Object System.Threading.Mutex($false, $mutexName)
    if (-not $script:mutex.WaitOne(0)) { exit 0 }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Security
if ($AllowUserInteraction) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

# =====================================================
# Test for Elevation
# =====================================================
function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =====================================================
# SECURITY HARDENING HELPERS  (v7.5.5)
# ---------------------------------------------------------------------------
# The agent installs to C:\ProgramData\ITFlow and runs as SYSTEM at startup.
# If an unprivileged user can overwrite the script, its install directory, or
# the registry config it trusts, the next reboot yields SYSTEM code execution
# (a local privilege-escalation chain: any user + reboot -> SYSTEM).
#
# These helpers close that chain. They are PS 5.1-native (Get-Acl/Set-Acl,
# System.Security.AccessControl) and use well-known SIDs so they behave the
# same on non-English Windows.
# =====================================================

# Well-known SIDs treated as privileged (write access by these is acceptable).
$script:TrustedWriteSids = @(
    'S-1-5-18',      # LocalSystem
    'S-1-5-32-544',  # BUILTIN\Administrators
    'S-1-5-19',      # LocalService
    'S-1-5-20',      # NetworkService
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' # NT SERVICE\TrustedInstaller
)

function Test-PathReparsePoint {
    # True if the path exists and is a reparse point (junction / symlink).
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    } catch { return $false }
}

function Reset-SuspiciousInstallDir {
    # Finding #2 (junction/hardlink planting): if the install directory is a
    # reparse point, an attacker can redirect SYSTEM's writes into a protected
    # location. Remove the reparse point *itself* (never follow it) so the caller
    # can recreate a clean, admin-owned directory.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-PathReparsePoint -Path $Path) {
        Log "SECURITY: install directory '$Path' is a reparse point (possible junction-planting attack) - removing it"
        try {
            # Directory.Delete(path,$false) removes the junction, not its target contents.
            [System.IO.Directory]::Delete($Path, $false)
        } catch {
            Log "SECURITY: failed to remove reparse point at '$Path': $($_.Exception.Message)"
        }
    }
}

function Set-ITFlowHardenedAcl {
    # Findings #1 & #2 remediation A: take ownership to Administrators, break
    # inheritance, and set an explicit DACL of
    #   SYSTEM:FullControl, Administrators:FullControl, Authenticated Users:ReadAndExecute
    # Applied unconditionally on every install/update, even when the target
    # pre-exists (resets a CREATOR OWNER foothold from a pre-created directory).
    param(
        [string]$Path,
        [switch]$IsContainer
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $sidAuthU  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-11')
        $isContainerPath = try { (Get-Item -LiteralPath $Path -Force).PSIsContainer } catch { [bool]$IsContainer }

        # Phase 1: take ownership FIRST via a fresh security object that carries only
        # the owner. Set-Acl then needs just WRITE_OWNER (granted to admins by
        # SeTakeOwnershipPrivilege), so this succeeds even when an attacker pre-created
        # the directory and stripped the inherited Administrators ACE (finding #2). Once
        # we own it, we implicitly hold WRITE_DAC for phase 2.
        try {
            $ownerOnly = if ($isContainerPath) { New-Object System.Security.AccessControl.DirectorySecurity } else { New-Object System.Security.AccessControl.FileSecurity }
            $ownerOnly.SetOwner($sidAdmins)
            Set-Acl -LiteralPath $Path -AclObject $ownerOnly -ErrorAction Stop
        } catch {
            Log "SECURITY: could not take ownership of '$Path' before DACL reset: $($_.Exception.Message)"
        }

        # Phase 2: with ownership secured, break inheritance and set the explicit DACL.
        $acl = Get-ACL -Path $Path
        $acl.SetOwner($sidAdmins)
        # Protect from inheritance and drop every existing/inherited ACE.
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

        if ($IsContainer) {
            $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        } else {
            $inherit = [System.Security.AccessControl.InheritanceFlags]::None
        }
        $prop  = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $full  = [System.Security.AccessControl.FileSystemRights]::FullControl
        $rx    = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem, $full, $inherit, $prop, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins, $full, $inherit, $prop, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAuthU,  $rx,   $inherit, $prop, $allow)))

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        Log "SECURITY: failed to harden ACL on '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Protect-InstallPath {
    # Remediation A + B for the install directory: neutralise a planted reparse
    # point, ensure the directory exists, then lock down owner + DACL. Callers
    # copy the script in afterwards and call Set-ITFlowHardenedAcl on the file.
    param([Parameter(Mandatory=$true)][string]$InstallDir)
    Reset-SuspiciousInstallDir -Path $InstallDir
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }
    Set-ITFlowHardenedAcl -Path $InstallDir -IsContainer | Out-Null
}

function Test-ScriptIntegrity {
    # Remediation C (runtime fail-safe): verify the running script grants write
    # only to trusted principals and is owned by one. Returns $false if any
    # non-privileged principal can modify it, so the SYSTEM run can refuse
    # privileged work. Fails closed on inspection errors.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $true } # cannot inspect -> do not block
    try {
        if (Test-PathReparsePoint -Path $Path) {
            Log "SECURITY: running script '$Path' is a reparse point - refusing privileged work"
            return $false
        }
        # Atomic modify/write/ownership bits only. Do NOT fold in the composite
        # rights Write/Modify/FullControl here: Modify and FullControl also carry
        # read/execute/synchronize bits, so a benign read-only ACE (e.g.
        # 'Authenticated Users: ReadAndExecute, Synchronize') would share bits
        # with the mask and be misreported as writable, aborting the SYSTEM run.
        # A FullControl/Modify/Write ACE is still caught because it contains
        # these atomic write bits.
        $writeMask = [System.Security.AccessControl.FileSystemRights]::WriteData `
            -bor [System.Security.AccessControl.FileSystemRights]::AppendData `
            -bor [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes `
            -bor [System.Security.AccessControl.FileSystemRights]::WriteAttributes `
            -bor [System.Security.AccessControl.FileSystemRights]::Delete `
            -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles `
            -bor [System.Security.AccessControl.FileSystemRights]::ChangePermissions `
            -bor [System.Security.AccessControl.FileSystemRights]::TakeOwnership

        $acl = Get-ACL -Path $Path -ErrorAction Stop
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if (($ace.FileSystemRights -band $writeMask) -eq 0) { continue }
            $sid = try { $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { "$($ace.IdentityReference)" }
            if ($script:TrustedWriteSids -contains $sid) { continue }
            Log "SECURITY: script is writable by non-privileged principal '$($ace.IdentityReference)' (SID $sid, rights $($ace.FileSystemRights)) - refusing privileged work"
            return $false
        }
        $ownerSid = try { $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { $null }
        if ($ownerSid -and -not ($script:TrustedWriteSids -contains $ownerSid)) {
            Log "SECURITY: script owner '$ownerSid' is not a privileged principal - refusing privileged work"
            return $false
        }
        return $true
    } catch {
        Log "SECURITY: script integrity check errored ($($_.Exception.Message)) - failing closed"
        return $false
    }
}

function Test-SafeSystemDir {
    # Remediation E: before SYSTEM writes into a directory, confirm it is not a
    # reparse point and (if it exists) is owned by a trusted principal. Returns
    # $true when inspection is inconclusive so it never blocks legitimate writes.
    param([string]$Path)
    try {
        if (Test-PathReparsePoint -Path $Path) { return $false }
        if (Test-Path -LiteralPath $Path) {
            $acl = Get-ACL -Path $Path -ErrorAction Stop
            $ownerSid = try { $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { $null }
            if ($ownerSid -and -not ($script:TrustedWriteSids -contains $ownerSid)) { return $false }
        }
        return $true
    } catch { return $true }
}

function Protect-RegistryKey {
    # Remediation D: give HKLM\SOFTWARE\ITFlow an explicit DACL (Administrators
    # + SYSTEM full, Users read-only) with inheritance disabled, instead of
    # inheriting potentially loose parent permissions. Closes the config-tamper
    # / API-key-exfiltration vector where the key is reported user-writable.
    param([string]$RegPath)
    try {
        if (-not (Test-Path -LiteralPath $RegPath)) { return $false }
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $sidUsers  = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

        # Phase 1: take ownership first (mirrors Set-ITFlowHardenedAcl). If an
        # attacker - or an older loose ACL - left the key owned by / readable only
        # to a non-privileged principal, the phase-2 Get-Acl would fail and return
        # $null, which previously surfaced as the misleading "You cannot call a
        # method on a null-valued expression". Setting only the owner needs just
        # WRITE_OWNER (SeTakeOwnershipPrivilege, held by admins/SYSTEM), after
        # which we implicitly hold WRITE_DAC for the DACL rewrite below.
        try {
            $ownerOnly = New-Object System.Security.AccessControl.RegistrySecurity
            $ownerOnly.SetOwner($sidAdmins)
            Set-Acl -LiteralPath $RegPath -AclObject $ownerOnly -ErrorAction Stop
        } catch {
            Log "SECURITY: could not take ownership of registry key '$RegPath' before DACL reset: $($_.Exception.Message)"
        }

        # Phase 2: with ownership secured, break inheritance and set the DACL.
        $acl = Get-ACL -Path $RegPath -ErrorAction Stop
        if (-not $acl) { throw "Get-Acl returned no security descriptor for '$RegPath'" }
        $acl.SetOwner($sidAdmins)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit'
        $prop    = [System.Security.AccessControl.PropagationFlags]::None
        $allow   = [System.Security.AccessControl.AccessControlType]::Allow
        $full    = [System.Security.AccessControl.RegistryRights]::FullControl
        $read    = [System.Security.AccessControl.RegistryRights]::ReadKey

        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($sidSystem, $full, $inherit, $prop, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($sidAdmins, $full, $inherit, $prop, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($sidUsers,  $read, $inherit, $prop, $allow)))

        Set-Acl -LiteralPath $RegPath -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        Log "SECURITY: failed to harden registry key '$RegPath': $($_.Exception.Message)"
        return $false
    }
}

# =====================================================
# DPAPI HELPERS
# =====================================================
function Protect-String {
    param([string]$PlainText)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    [Convert]::ToBase64String(
        [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
    )
}

function Unprotect-String {
    param([string]$CipherText)
    try {
        $bytes = [Convert]::FromBase64String($CipherText)
        [System.Text.Encoding]::UTF8.GetString(
            [System.Security.Cryptography.ProtectedData]::Unprotect(
                $bytes,
                $null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine
            )
        )
    } catch { "" }
}

# =====================================================
# Client ID Helper for moved assets
# =====================================================
function Set-ConfiguredClientId {
    param(
        [Parameter(Mandatory=$true)][int]$NewClientId
    )

    if ($NewClientId -le 0) { return $false }

    # Update in-memory config immediately
    $Config.ClientId = $NewClientId.ToString()

    # Persist to INI in portable mode
    if (-not $script:RegistryAllowed) {
        Log "Config ClientId updated in memory: $NewClientId"
        if (Test-Path $IniPath) {
            $content = [System.IO.File]::ReadAllText($IniPath)
            $content = $content -replace "(?m)(?<=^\[ITFlow\]\r?\n.*?)^ClientId=.*", "ClientId=$NewClientId"
            Write-IniFileSafely -Path $IniPath -Content $content
            Log "Config ClientId saved to INI: $NewClientId"
        }
        return $true
    }

    # Prefer registry (your script loads from HKLM first)
    try {
        if (Test-IsAdmin) {
            if (-not (Test-Path $RegRoot)) { New-Item -Path $RegRoot -Force | Out-Null }

            Set-ItemProperty -LiteralPath $RegRoot -Name "ClientId" -Value $Config.ClientId
            Log "Config ClientId updated in registry: $NewClientId"
            return $true
        }
        else {
            Log "Config ClientId not persisted (not elevated). In-memory only: $NewClientId"
            return $false
        }
    }
    catch {
        Log "Config ClientId persist failed: $($_.Exception.Message)"
        return $false
    }
}

# =====================================================
# REGISTRY WRITE HELPER
# =====================================================
function Write-ConfigToRegistry {
    if (-not $script:RegistryAllowed) { Log "Write-ConfigToRegistry skipped (portable mode)"; return $true }

    if (-not (Test-IsAdmin)) {
        throw "Administrator privileges are required to write to HKLM."
    }

    try {
        if (-not (Test-Path $RegRoot)) { New-Item -Path $RegRoot -Force | Out-Null }
        if (-not (Test-Path $RegPreferences)) { New-Item -Path $RegPreferences -Force | Out-Null }

        Set-ItemProperty -LiteralPath $RegRoot -Name "BaseUrl"  -Value $Config.BaseUrl
        Set-ItemProperty -LiteralPath $RegRoot -Name "ClientId" -Value $Config.ClientId
        Set-ItemProperty -LiteralPath $RegRoot -Name "ApiKey"   -Value (Protect-String $Config.ApiKey)

        # Remediation D: pin the BaseUrl written by an elevated admin. The SYSTEM
        # run compares against this and refuses a tampered value (see Assert-BaseUrlPin).
        Set-ItemProperty -LiteralPath $RegRoot -Name "InstalledBaseUrl" -Value $Config.BaseUrl

        Set-ItemProperty -LiteralPath $RegPreferences -Name "CreateTicketsGui" -Value $(if ($script:EnableTicketingGui) { 1 } else { 0 }) -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "FollowClientTransfers" -Value $(if ($AllowFollowClientTransfer) { 1 } else { 0 }) -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "AutoUpdateClientIdOnTransfer" -Value $(if ($AutoUpdateClientIdOnTransfer) { 1 } else { 0 }) -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactFromLogons" -Value $(if ($AssignContactFromLogons) { 1 } else { 0 }) -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactLookbackDays" -Value $AssignContactLookbackDays -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactHalfLifeDays" -Value $AssignContactHalfLifeDays -Type DWord
        Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactAllowedDomain" -Value $AssignContactAllowedDomain -Type String
        Set-ItemProperty -LiteralPath $RegPreferences -Name "VerboseLogging" -Value $(if ($VerboseLogging) { 1 } else { 0 }) -Type DWord

        # Remediation D: lock down the key's DACL after (re)writing config.
        Protect-RegistryKey -RegPath $RegRoot | Out-Null

        return $true
    }
    catch {
        Log "Registry write failed: $($_.Exception.Message)"
        return $false
    }
}

#===================================
#    Assetid to ticketAssetId helper
#===================================

function Test-ITFlowAssetArchived {
    # assets/read.php has no archived filter (ITFlow 26.11 source: a plain
    # SELECT * FROM assets WHERE asset_serial = ...), so archived rows come back
    # alongside live ones. A row is archived when asset_archived_at holds a date.
    param($Row)
    if ($null -eq $Row) { return $false }
    $v = Get-AssetProp $Row 'asset_archived_at'
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    if ($v -match '^0000-00-00') { return $false }
    return $true
}

function Select-ITFlowAssetRow {
    # Split a read result into the first non-archived row and the archived ones.
    # Rows are ordered by asset_id ascending, so taking data[0] picked the OLDEST
    # match - an archived record over the live duplicate that replaced it.
    # Windows PowerShell 5.1: @(<generic List>) inside a [pscustomobject]@{} literal
    # throws "Argument types do not match", so collect into a plain array and
    # build the object from pre-assigned locals.
    param($Rows)
    $active = $null
    $archived = @()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if (Test-ITFlowAssetArchived $r) { $archived += $r; continue }
        if ($null -eq $active) { $active = $r }
    }
    [object[]]$archivedArr = $archived
    $result = New-Object PSObject -Property @{ Active = $active; Archived = $archivedArr }
    return $result
}

function Invoke-ArchivedAssetNotice {
    # The only ITFlow record for this serial is archived. The API has no asset
    # unarchive endpoint, and enrolling a new asset would duplicate the serial
    # behind the archived one, so the agent stops and asks a technician to
    # restore or delete the record. One ticket per condition (flag-guarded).
    param(
        [Parameter(Mandatory=$true)]$Inv,
        [Parameter(Mandatory=$true)][int]$TicketClientId,
        [Parameter(Mandatory=$true)]$ArchivedRow,
        [Parameter(Mandatory=$true)][string]$FlagName,
        [Parameter(Mandatory=$true)][string]$LogTag,
        [Nullable[int]]$TicketAssetId = $null,
        [string]$DeviceSpec = ""
    )

    $aid = Get-AssetProp $ArchivedRow 'asset_id'
    $acid = Get-AssetProp $ArchivedRow 'asset_client_id'
    $aat = Get-AssetProp $ArchivedRow 'asset_archived_at'
    Log "$LogTag serial='$($Inv.Serial)' asset_id=$aid client_id=$acid archived_at='$aat' - not updating it and not enrolling a duplicate. Restore the asset in ITFlow (or delete it to let the agent enrol a new one)."

    try { $script:LastRunState.AssetArchived = $true } catch { }

    if ((($Silent -and $EnableTicketingSilent) -or (-not $Silent -and $EnableTicketingGui))) {
        if (-not (Test-TicketFlag $FlagName)) {
            $title = "[ARCHIVED] $($Inv.Hostname) | Serial: $($Inv.Serial) is checking in but its asset is archived"
            $infoPairs = [ordered]@{
                "Asset ID"     = $aid
                "Client ID"    = $acid
                "Archived at"  = $aat
                "Hostname"     = $Inv.Hostname
                "Serial"       = $Inv.Serial
            }
            $details = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
                (New-ITFlowTicketParagraph "This device is still running the ITFlow agent, but the only ITFlow asset with its serial number is archived."),
                (New-ITFlowTicketSection -Title "Archived Asset" -Icon "🗄️" -InnerHtml (New-ITFlowTicketKeyValueTable $infoPairs)),
                (New-ITFlowTicketParagraph "The agent will not update an archived asset or create a duplicate. Restore the asset to resume syncing, or delete it so the agent enrols a new one.")
            )
            Create-ITFlowTicket -Title $title -ClientId $TicketClientId -AssetId $TicketAssetId -Details $details | Out-Null
            Set-TicketFlag $FlagName | Out-Null
        } else {
            Log "Archived-asset ticket already created ($FlagName) - skipping"
        }
    }
}

function Get-ITFlowTransferNote {
    # ITFlow's Transfer to Client (agent/post/asset.php, bulk_transfer_client_asset)
    # copies the asset into the new client under a NEW asset_id, archives the
    # original, and appends to its notes:
    #   Transferred asset <name> (old asset ID: X) from <A> to <B> (new asset ID: Y)
    # The last such line is the most recent transfer. Returns $null when absent.
    param($ArchivedRow)
    $notes = Get-AssetProp $ArchivedRow 'asset_notes'
    if (-not $notes) { return $null }
    $found = [regex]::Matches($notes, 'Transferred asset .+? \(old asset ID: (\d+)\) from (.+?) to (.+?) \(new asset ID: (\d+)\)')
    if ($found.Count -eq 0) { return $null }
    $m = $found[$found.Count - 1]
    $note = New-Object PSObject -Property @{
        OldAssetId = [int]$m.Groups[1].Value
        FromClient = $m.Groups[2].Value
        ToClient   = $m.Groups[3].Value
        NewAssetId = [int]$m.Groups[4].Value
    }
    return $note
}

function Invoke-ArchivedInClientDecision {
    # The configured client holds only an archived record for this serial, and no
    # live copy was found anywhere this key can read. Either ITFlow transferred it
    # to a client outside the key's scope (its notes say so), or it was simply
    # archived. Neither case may enrol a duplicate.
    param(
        [Parameter(Mandatory=$true)]$Inv,
        [Parameter(Mandatory=$true)][int]$ClientId,
        [Parameter(Mandatory=$true)]$ArchivedRow,
        [string]$DeviceSpec = ""
    )

    $archivedId = $null
    try { $archivedId = [int](Normalize-Value $ArchivedRow.asset_id) } catch { $archivedId = $null }

    $note = Get-ITFlowTransferNote $ArchivedRow
    if ($note) {
        Log "TRANSFER_OUT_OF_SCOPE serial='$($Inv.Serial)' was transferred from '$($note.FromClient)' to '$($note.ToClient)' as asset_id=$($note.NewAssetId), but this key cannot see that client. Not enrolling a duplicate. Widen the key user's client access (the agent then follows it automatically) or reconfigure this device's ClientId."
        try { $script:LastRunState.AssetArchived = $true } catch { }
        if ((($Silent -and $EnableTicketingSilent) -or (-not $Silent -and $EnableTicketingGui))) {
            if (-not (Test-TicketFlag "TransferOutOfScope")) {
                $title = "[TRANSFER] $($Inv.Hostname) | Serial: $($Inv.Serial) moved to $($note.ToClient) (asset $($note.NewAssetId)) - agent key cannot follow"
                $infoPairs = [ordered]@{
                    "Archived asset here" = $archivedId
                    "New asset ID"        = $note.NewAssetId
                    "Hostname"            = $Inv.Hostname
                    "Serial"              = $Inv.Serial
                }
                $details = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
                    (New-ITFlowTicketParagraph "ITFlow transferred this asset from $($note.FromClient) to $($note.ToClient)."),
                    (New-ITFlowTicketSection -Title "Transfer" -Icon "🔀" -InnerHtml (New-ITFlowTicketKeyValueTable $infoPairs)),
                    (New-ITFlowTicketParagraph "The device's agent is still configured for this client and its API key's user cannot read $($note.ToClient), so it cannot follow the transfer. Either grant that user access to $($note.ToClient) (the agent follows on its next run) or reconfigure the agent's Client ID on the device.")
                )
                Create-ITFlowTicket -Title $title -ClientId $ClientId -AssetId $archivedId -Details $details | Out-Null
                Set-TicketFlag "TransferOutOfScope" | Out-Null
            } else {
                Log "Transfer-out-of-scope ticket already created - skipping"
            }
        }
        return
    }

    Invoke-ArchivedAssetNotice -Inv $Inv -TicketClientId $ClientId -ArchivedRow $ArchivedRow -FlagName "AssetArchived" -LogTag "ASSET_ARCHIVED" -TicketAssetId $archivedId -DeviceSpec $DeviceSpec
}

function Resolve-AssetIdBySerial {
    param(
        [Parameter(Mandatory=$true)][string]$Serial,
        [Parameter(Mandatory=$true)][int]$ClientId
    )

    try {
        $uri = New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ client_id = $ClientId; asset_serial = $Serial })
        $resp = Invoke-ITFlowChecked GET $uri $null "Resolve asset_id by serial"

        if ($resp -and "$($resp.success)" -eq "True" -and $resp.count -gt 0 -and $resp.data) {
            # Prefer the live asset; an archived one is still fine to link a ticket to.
            $sel = Select-ITFlowAssetRow -Rows $resp.data
            $row = $sel.Active
            if ($null -eq $row -and $sel.Archived.Count -gt 0) { $row = $sel.Archived[0] }
            if ($row -and $row.asset_id) { return [int]$row.asset_id }
        }
    } catch {
        Log "Resolve-AssetIdBySerial failed: $($_.Exception.Message)"
    }

    return $null
}


# =====================================================
# Registry Helpers (State, Preferences, Cache)
# All operations target structured subkeys under $RegRoot.
# =====================================================

function Read-RegValue {
    param([string]$Path, [string]$Name)
    # Try registry first
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $p) { return $p.$Name }
    } catch {}
    # Fallback to INI when registry unavailable or key missing
    if (Test-Path $IniPath) {
        $section = $Path.Substring($RegRoot.Length + 1)
        try {
            $raw = [System.IO.File]::ReadAllText($IniPath)
            $escapedName = [regex]::Escape($Name)
            if ($raw -match "(?ms)\[$section\].*?^$escapedName=([^\r\n]+)") { return $matches[1].Trim() }
        } catch { }
    }
    return $null
}

# Shared INI write logic used by both Write-RegDword and Write-RegString
function Write-IniValue {
    param([string]$Path, [string]$Name, [string]$Value, [string]$MatchPattern)

    $section = $Path.Substring($RegRoot.Length + 1)
    $content = try { [System.IO.File]::ReadAllText($IniPath) } catch { "" }
    if (-not $content) { $content = "" }
    $escapedName = [regex]::Escape($Name)
    if ($content -match "(?ms)\[$section\]") {
        if ($content -match "(?m)^$escapedName$MatchPattern") { $content = $content -replace "(?m)^$escapedName$MatchPattern", "$Name=$Value" }
        else { $content = $content -replace "(?m)(\[$section\])", "`$1`r`n$Name=$Value" }
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n[$section]`r`n$Name=$Value"
    }
    Write-IniFileSafely -Path $IniPath -Content $content
}

function Write-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if ($script:RegistryAllowed) {
        try {
            if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force -ErrorAction SilentlyContinue 2>&1 }
            $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction SilentlyContinue 2>&1
        } catch { }
    } else {
        Write-IniValue -Path $Path -Name $Name -Value $Value -MatchPattern '=\d+$'
    }
}

function Write-RegString {
    param([string]$Path, [string]$Name, [string]$Value)
    if ($script:RegistryAllowed) {
        try {
            if (-not (Test-Path $Path)) { $null = New-Item -Path $Path -Force -ErrorAction SilentlyContinue 2>&1 }
            $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction SilentlyContinue 2>&1
        } catch { }
    } else {
        Write-IniValue -Path $Path -Name $Name -Value $Value -MatchPattern '=.+$'
    }
}

# --- State subkey (runtime state) ---
function Get-StateDword {
    param([string]$Name, [int]$Default = 0)
    $v = Read-RegValue -Path $RegState -Name $Name
    if ($null -ne $v) { return [int]$v }
    return $Default
}

function Set-StateDword {
    param([string]$Name, [int]$Value)
    Write-RegDword -Path $RegState -Name $Name -Value $Value
    Log "State saved: $Name=$Value"
}

function Get-StateString {
    param([string]$Name, [string]$Default = "")
    $v = Read-RegValue -Path $RegState -Name $Name
    if ($null -ne $v) { return (Normalize-Value $v) }
    return $Default
}

function Set-StateString {
    param([string]$Name, [string]$Value)
    Write-RegString -Path $RegState -Name $Name -Value $Value
    Log "State saved: $Name=$Value"
}

# --- Preferences subkey (GUI user preferences) ---
function Get-PreferenceDword {
    param([string]$Name, [int]$Default = 0)
    $v = Read-RegValue -Path $RegPreferences -Name $Name
    if ($null -ne $v) { return [int]$v }
    # Fallback to INI file when registry unavailable
    if (Test-Path $IniPath) {
        try {
            $escapedName = [regex]::Escape($Name)
            $line = Select-String -Path $IniPath -Pattern "^$escapedName=\d+$" | Select-Object -First 1 -ErrorAction SilentlyContinue
            if ($line) { $val = ($line.Line -split '=')[1]; if ($val -match '^\d+$') { return [int]$val } }
        } catch { }
    }
    return $Default
}

function Get-PreferenceString {
    param([string]$Name, [string]$Default = "")
    $v = Read-RegValue -Path $RegPreferences -Name $Name
    if ($null -ne $v) { return (Normalize-Value $v) }
    return $Default
}

# --- Cache subkey (agent cache, replaces old AgentCache) ---
function Get-CacheValue {
    param([string]$Name, [string]$Default = "")
    $v = Read-RegValue -Path $RegCache -Name $Name
    if ($null -ne $v) { return (Normalize-Value $v) }
    return $Default
}

function Set-CacheValue {
    param([string]$Name, [string]$Value)
    Write-RegString -Path $RegCache -Name $Name -Value $Value
}

# --- TicketFlags subkey (already structured, resolves lazily) ---

function Test-TicketFlag {
    param([string]$Name)
    if ($script:RegistryAllowed) {
        $path = "$RegRoot\TicketFlags"
        if (-not (Test-Path $path)) { return $false }
        try {
            $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            return ($item.PSObject.Properties.Name -contains $Name)
        } catch { return $false }
    }
    # Portable mode: check INI
    if (Test-Path $IniPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($IniPath)
            $escapedName = [regex]::Escape($Name)
            return ($raw -match "(?ms)\[TicketFlags\].*?^$escapedName=1")
        } catch { }
    }
    return $false
}

function Set-TicketFlag {
    param([string]$Name)
    if ($script:RegistryAllowed) {
        $path = "$RegRoot\TicketFlags"
        try {
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -LiteralPath $path -Name $Name -Value 1 -PropertyType DWord -Force | Out-Null
            Log "Ticket flag set: $Name"
            return $true
        } catch {
            Log "ERROR: Failed to set ticket flag '$Name' - $($_.Exception.Message)"
            return $false
        }
    }
    # Portable mode: write to INI
    $content = try { [System.IO.File]::ReadAllText($IniPath) } catch { "" }
    if (-not $content) { $content = "" }
    $escapedName = [regex]::Escape($Name)
    if ($content -match "(?ms)\[TicketFlags\]") {
        if ($content -match "(?m)^$escapedName=\d+$") { $content = $content -replace "(?m)^$escapedName=\d+$", "$Name=1" }
        else { $content = $content -replace "(?m)(\[TicketFlags\])", "`$1`r`n$Name=1" }
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n[TicketFlags]`r`n$Name=1"
    }
    Write-IniFileSafely -Path $IniPath -Content $content
    Log "Ticket flag set: $Name"
    return $true
}

function Clear-TicketFlag {
    param([string]$Name)
    if ($script:RegistryAllowed) {
        $path = "$RegRoot\TicketFlags"
        if (-not (Test-Path $path)) { return }
        try {
            $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if ($item.PSObject.Properties.Name -contains $Name) {
                Remove-ItemProperty -LiteralPath $path -Name $Name -ErrorAction Stop
                Log "Ticket flag cleared: $Name"
            }
        } catch {
            # Quietly ignore
        }
        return
    }
    # Portable mode: remove from INI
    if (Test-Path $IniPath) {
        $content = try { [System.IO.File]::ReadAllText($IniPath) } catch { "" }
        if ($content) {
            $escapedName = [regex]::Escape($Name)
            $content = $content -replace "(?m)^$escapedName=.*`r?`n", ""
            $content = $content -replace "`r`n`r`n\[TicketFlags\]`r`n$", ""
            Write-IniFileSafely -Path $IniPath -Content $content
        }
    }
}

# =====================================================
# INI FILE WRITE HELPER (thread-safe)
# =====================================================
$script:IniMutex = New-Object System.Threading.Mutex($false, "Global\ITFlow-INI-Write")

function Write-IniFileSafely {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content,
        [int]$RetryDelayMs = 200
    )
    $script:IniMutex.WaitOne() | Out-Null
    try {
        Set-Content -Path $Path -Value $Content -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        Start-Sleep -Milliseconds $RetryDelayMs
        try { Set-Content -Path $Path -Value $Content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
    } finally {
        try { $script:IniMutex.ReleaseMutex() } catch {}
    }
}

# --- INI section merge helper (preserves sections not being replaced) ---
function Merge-IniSections {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$SectionNames,
        [Parameter(Mandatory=$true)][string]$NewContent
    )

    if (-not (Test-Path $FilePath)) { return Set-Content -Path $FilePath -Value $NewContent -Encoding UTF8 -Force }

    $existing = [System.IO.File]::ReadAllText($FilePath)

    # Strip old versions of the sections being replaced
    foreach ($section in $SectionNames) {
        $escaped = [regex]::Escape($section)
        $existing = $existing -replace "(?ms)\r?\n\[$escaped\].*?(?=\r?\n\[|\z)", ""
        $existing = $existing -replace "(?ms)^\[$escaped\].*?(?=\r?\n\[|\z)", ""
    }

    # Trim trailing whitespace, append new content
    $existing = $existing.TrimEnd() + "`r`n`r`n$NewContent`r`n"

    Write-IniFileSafely -Path $FilePath -Content $existing
}

# --- One-time migration from flat layout to structured subkeys ---
function Invoke-RegistryMigration {
    if (-not $script:RegistryAllowed) { return }
    $migrated = Get-StateDword -Name 'LayoutMigrated' -Default 0
    if ($migrated -eq 1) { return }

    Log "Migrating registry layout to structured subkeys..."

    # Migration map: flat key name -> target path
    $moves = @(
        @{Name='LastRunAt';              Target=$RegState; Type='String'},
        @{Name='LastEffectiveClientId';   Target=$RegState; Type='String'},
        @{Name='LastAssetId';             Target=$RegState; Type='String'},
        @{Name='LastSyncOK';              Target=$RegState; Type='Dword'},
        @{Name='LastRenameRequired';      Target=$RegState; Type='Dword'},
        @{Name='LastTargetHostname';      Target=$RegState; Type='String'},
        @{Name='CreateTicketsGui';        Target=$RegPreferences; Type='Dword'},
        @{Name='FollowClientTransfers';   Target=$RegPreferences; Type='Dword'},
        @{Name='AutoUpdateClientIdOnTransfer'; Target=$RegPreferences; Type='Dword'}
    )

    foreach ($m in $moves) {
        $val = Read-RegValue -Path $RegRoot -Name $m.Name
        if ($null -ne $val) {
            if (-not (Test-Path $m.Target)) { New-Item -Path $m.Target -Force | Out-Null }
            if ($m.Type -eq 'Dword') {
                Write-RegDword -Path $m.Target -Name $m.Name -Value ([int]$val)
            } else {
                Write-RegString -Path $m.Target -Name $m.Name -Value ([string]$val)
            }
            try { Remove-ItemProperty -LiteralPath $RegRoot -Name $m.Name -ErrorAction Stop } catch {}
        }
    }

    # Migrate old AgentCache -> Cache
    $oldCache = "$RegRoot\AgentCache"
    if (Test-Path $oldCache) {
        try {
            $items = Get-ItemProperty -LiteralPath $oldCache -ErrorAction Stop
            if (-not (Test-Path $RegCache)) { New-Item -Path $RegCache -Force | Out-Null }
            foreach ($prop in $items.PSObject.Properties) {
                if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                Write-RegString -Path $RegCache -Name $prop.Name -Value ([string]$prop.Value)
            }
            Remove-Item -LiteralPath $oldCache -Recurse -Force -ErrorAction SilentlyContinue
            Log "Migrated old AgentCache -> Cache"
        } catch {
            Log "WARN: AgentCache migration skipped: $($_.Exception.Message)"
        }
    }

    Set-StateDword -Name 'LayoutMigrated' -Value 1
    Log "Registry layout migration complete"
}

# =====================================================
# Normalize Values Helpers
# =====================================================
function Normalize-Value {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value.ToString().Trim())
}

function Get-AssetProp {
    param($Asset, [string]$Name)
    if ($null -eq $Asset) { return "" }
    if ($Asset.PSObject.Properties.Name -contains $Name) {
        return (Normalize-Value $Asset.$Name)
    }
    return ""
}


# =====================================================
# Always-on Local vs ITFlow Comparison (Verbose)
# =====================================================
function Log-CompareLine {
    param(
        [Parameter(Mandatory=$true)][string]$Field,
        [string]$LocalValue,
        [string]$ItflowValue
    )

    $l = Normalize-Value $LocalValue
    $r = Normalize-Value $ItflowValue
    Log ("  {0,-10} local='{1}' itflow='{2}'" -f $Field, $l, $r)
}

function Log-LocalVsITFlowVerbose {
    param(
        [Parameter(Mandatory=$true)]$Inv,
        [Parameter(Mandatory=$true)][string]$DetectedAssetType,
        [Parameter(Mandatory=$true)]$Asset,
        [Parameter(Mandatory=$true)][int]$EffectiveClientId
    )

    # Guard: log compare block only once per Run-AssetSync invocation
    if ($script:LoggedLocalVsITFlow) { return }
    $script:LoggedLocalVsITFlow = $true

    Log "Local vs ITFlow (before update):"

    # Local (what the agent sees)
    $localHostname = Normalize-Value $Inv.Hostname
    $localSerial   = Normalize-Value $Inv.Serial
    $localType     = Normalize-Value $DetectedAssetType
    $localMake     = Normalize-Value $Inv.Make
    $localModel    = Normalize-Value $Inv.Model
    $localOS       = Normalize-Value $Inv.OS
    $localStatus   = Normalize-Value $DefaultAssetStatus
    $localIP       = Normalize-Value $Inv.IP
    $localMAC      = Normalize-Value $Inv.MAC

    # ITFlow (what ITFlow has)
    $itHostname = Get-AssetProp $Asset 'asset_name'
    $itSerial   = Get-AssetProp $Asset 'asset_serial'
    $itType     = Get-AssetProp $Asset 'asset_type'
    $itMake     = Get-AssetProp $Asset 'asset_make'
    $itModel    = Get-AssetProp $Asset 'asset_model'
    $itOS       = Get-AssetProp $Asset 'asset_os'
    $itStatus   = Get-AssetProp $Asset 'asset_status'
    $itClientId = Get-AssetProp $Asset 'asset_client_id'

    # Some ITFlow instances don't return IP/MAC via read. Show what we can.
    $itIP  = Get-AssetProp $Asset 'asset_ip'
    $itMAC = Get-AssetProp $Asset 'asset_mac'
    if ([string]::IsNullOrWhiteSpace($itIP))  { $itIP  = '(not returned)' }
    if ([string]::IsNullOrWhiteSpace($itMAC)) { $itMAC = '(not returned)' }

    Log-CompareLine 'Hostname:' $localHostname $itHostname
    Log-CompareLine 'ClientId:' ([string]$EffectiveClientId) $itClientId
    Log-CompareLine 'Status:'   $localStatus   $itStatus
    Log-CompareLine 'Type:'     $localType     $itType
    Log-CompareLine 'Make:'     $localMake     $itMake
    Log-CompareLine 'Model:'    $localModel    $itModel
    Log-CompareLine 'OS:'       $localOS       $itOS
    Log-CompareLine 'Serial:'   $localSerial   $itSerial
    Log-CompareLine 'IP:'       $localIP       $itIP
    Log-CompareLine 'MAC:'      $localMAC      $itMAC

    if ($script:LocalAssetSpecs -and $script:LocalAssetSpecs.Count -gt 0) {
        $itSpecs = ConvertTo-ITFlowSpecMap $Asset
        foreach ($k in $script:LocalAssetSpecs.Keys) {
            $itVal = '(not returned)'
            if ($null -ne $itSpecs) { $itVal = ''; if ($itSpecs.ContainsKey($k)) { $itVal = $itSpecs[$k] } }
            Log-CompareLine ("spec.$k" + ':') (Normalize-Value $script:LocalAssetSpecs[$k]) $itVal
        }
    }

    # Cache context for IP/MAC send logic
    $lastMac = Get-AgentCacheValue -Name 'LastSentMAC' -Default ''
    $lastIp  = Get-AgentCacheValue -Name 'LastSentIP'  -Default ''
    Log ("  {0,-10} local='{1}' lastSent='{2}'" -f 'IPCache:',  $localIP,  (Normalize-Value $lastIp))
    Log ("  {0,-10} local='{1}' lastSent='{2}'" -f 'MACCache:', $localMAC, (Normalize-Value $lastMac))
}


# =====================================================
# CONFIG SOURCES
# =====================================================
$RegRoot          = "HKLM:\SOFTWARE\ITFlow"
$RegState         = "$RegRoot\State"
$RegPreferences   = "$RegRoot\Preferences"
$RegCache         = "$RegRoot\Cache"
$RegTicketFlags   = "$RegRoot\TicketFlags"
$RegistryBasePath = $RegRoot

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Definition) {
    Split-Path -Parent $MyInvocation.MyCommand.Definition
} else { "" }
$IniPath = Join-Path $ScriptRoot "ITFlow-AssetManager.ini"

# =====================================================
# Config defaults
# =====================================================
$Config = @{
    BaseUrl  = ""
    ApiKey   = ""
    ClientId = ""
}


# =====================================================
# Initialize Log Path
# =====================================================
$LogRoot = "C:\ProgramData\ITFlow\Logs"
$script:LogDirEnsured = $false

# If GUI supplies a log path, the worker uses it so the UI can tail it live
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $LogFile = $LogPath
} else {
    $LogFile = Join-Path $LogRoot "$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

function Log {
    param([string]$Message)

    if (-not $LogFile) { return }

    # Create log directory lazily, once per session
    if (-not $script:LogDirEnsured) {
        # Remediation E: under SYSTEM, don't create/follow a reparse point at the log
        # root. Done inline (no Log call) to avoid recursion. If unsafe, leave the dir
        # absent so the file append below simply no-ops instead of writing via a junction.
        $logRootSafe = $true
        if ($script:IsSystemContext) {
            try { $logRootSafe = Test-SafeSystemDir -Path $LogRoot } catch { $logRootSafe = $true }
        }
        if ($logRootSafe) {
            $null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue
        }
        $script:LogDirEnsured = $true
    }

    $line = "$(Get-Date -Format 'HH:mm:ss')  $Message"

    try {
        # Robust append safe with concurrent readers/tailers
        [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        # Never crash the agent due to logging
    }

    # GUI mode: append to the log textbox safely (UI-thread marshaling)
    if ($AllowUserInteraction -and $log) {
        try {
            if ($log.IsHandleCreated -and $log.InvokeRequired) {
                $null = $log.BeginInvoke([Action]{
                    try { $log.AppendText($line + "`r`n") } catch {}
                })
            }
            else {
                $log.AppendText($line + "`r`n")
            }
        } catch {
            # Ignore handle disposal/timing issues
        }
    }
}



$mode = if ($Install) { "Install" } elseif ($Uninstall) { "Uninstall" } elseif ($Worker) { "Worker" } elseif ($Silent) { "Silent" } else { "GUI" }
Log "ITFlow Agent v$AgentVersion starting (mode=$mode, rename=$Rename, elevated=$(if (Test-IsAdmin) { 'yes' } else { 'no' }))"

# =====================================================
# LOAD CONFIG (Registry first, INI fallback)
# =====================================================
$LoadedFromRegistry = $false
$reg = $null

if (Test-Path $RegistryBasePath) {
    try {
        $reg = Get-ItemProperty $RegistryBasePath -ErrorAction Stop

        if ($reg.BaseUrl)  { $Config.BaseUrl  = $reg.BaseUrl }
        if ($reg.ClientId) { $Config.ClientId = $reg.ClientId }
        if ($reg.ApiKey)   { $Config.ApiKey   = Unprotect-String $reg.ApiKey }

        if ($Config.BaseUrl -and $Config.ClientId -and $Config.ApiKey) {
            $LoadedFromRegistry = $true
            Log "Configuration loaded from registry"
        }
    } catch {
        Log "Registry configuration load failed: $($_.Exception.Message)"
    }
}

if (-not $LoadedFromRegistry -and (Test-Path $IniPath)) {
    Get-Content $IniPath | Where-Object { $_ -match "=" } | ForEach-Object {
        $k,$v = $_ -split "=",2
        $Config[$k.Trim()] = $v.Trim()
    }

    if ($Config.ApiKey) { $Config.ApiKey = Unprotect-String $Config.ApiKey }
    Log "Configuration loaded from INI file"
}

# One-time migration from flat registry layout to structured subkeys
Invoke-RegistryMigration

# Ad-hoc / USB mode: don't touch the registry if ITFlow hasn't been installed here
# or the current user doesn't have admin rights to write to it
$script:RegistryAllowed = (Test-Path $RegRoot) -and (Test-IsAdmin)
if (-not $script:RegistryAllowed -and (Test-IsAdmin)) {
    # Admin but no registry key yet - create it so this session and future runs use registry
    try {
        if (-not (Test-Path $RegRoot)) { $null = New-Item -Path $RegRoot -Force -ErrorAction Stop }
        if (-not (Test-Path $RegState)) { $null = New-Item -Path $RegState -Force -ErrorAction Stop }
        if (-not (Test-Path $RegPreferences)) { $null = New-Item -Path $RegPreferences -Force -ErrorAction Stop }
        if (-not (Test-Path $RegCache)) { $null = New-Item -Path $RegCache -Force -ErrorAction Stop }
        if (-not (Test-Path $RegTicketFlags)) { $null = New-Item -Path $RegTicketFlags -Force -ErrorAction Stop }
        $script:RegistryAllowed = $true
        Log "Registry initialized for this session"
    } catch { Log "Registry init failed: $($_.Exception.Message)" }
}
# Remediation D: whenever we hold the key elevated, ensure its DACL is locked
# down (Users read-only). Cheap and idempotent - covers keys created by older
# agent versions that inherited loose parent permissions.
if ($script:RegistryAllowed -and (Test-IsAdmin) -and (Test-Path $RegRoot)) {
    Protect-RegistryKey -RegPath $RegRoot | Out-Null
}
if (-not $script:RegistryAllowed) {
    Log "Portable mode: registry not available, using INI-based config only"
}

if ([string]::IsNullOrWhiteSpace($Config.ClientId)) {
    # Fallback: read ClientId directly from the INI file (portable mode)
    if (($script:RegistryAllowed -or -not $LoadedFromRegistry) -and (Test-Path $IniPath)) {
        try {
            $raw = [System.IO.File]::ReadAllText($IniPath)
            if ($raw -match "(?m)^ClientId\s*=\s*(.+)$") {
                $Config.ClientId = $matches[1].Trim()
                Log "Config ClientId loaded from INI fallback: $($Config.ClientId)"
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($Config.ClientId)) {
        Log "ERROR: ClientId is blank. Required for POST requests when API key is all-client scope."
    }
}

# =====================================================
# HARDEN REGISTRY API KEY (plaintext -> DPAPI)
# =====================================================
if ($reg -and $reg.ApiKey -and -not $Config.ApiKey) {
    $Config.ApiKey = $reg.ApiKey

    if (Test-IsAdmin) {
        Set-ItemProperty `
            -Path $RegistryBasePath `
            -Name ApiKey `
            -Value (Protect-String $Config.ApiKey) `
            -Type String

        Log "Registry ApiKey detected as plaintext and re-encrypted"
    }
    else {
        Log "Registry ApiKey plaintext detected but cannot re-encrypt (not elevated)"
    }
}

# =====================================================
# REMEDIATION D: BASEURL PIN ENFORCEMENT
# The SYSTEM startup run must never send ?api_key=... to an attacker-supplied
# host. Compare the loaded BaseUrl against the value pinned by the last elevated
# admin install/config-save; if they differ under SYSTEM, refuse the tampered
# value and fall back to the trusted pin (neutralises API-key exfiltration even
# where the registry key is user-writable).
# =====================================================
if ($script:RegistryAllowed -and (Test-Path $RegRoot)) {
    try {
        $pinnedBaseUrl = (Get-ItemProperty -LiteralPath $RegRoot -Name "InstalledBaseUrl" -ErrorAction SilentlyContinue).InstalledBaseUrl
    } catch { $pinnedBaseUrl = $null }
    if ($pinnedBaseUrl -and $Config.BaseUrl -and ("$($Config.BaseUrl)".TrimEnd('/') -ne "$pinnedBaseUrl".TrimEnd('/'))) {
        if ($script:IsSystemContext) {
            Log "SECURITY: BaseUrl '$($Config.BaseUrl)' does not match the pinned install value '$pinnedBaseUrl' - config may be tampered. Using the pinned value."
            $Config.BaseUrl = $pinnedBaseUrl
        } else {
            Log "BaseUrl differs from pinned install value (elevated/interactive run; not overriding). Current='$($Config.BaseUrl)' Pinned='$pinnedBaseUrl'"
        }
    }
}


# =====================================================
# Dynamic Contact Assignment from User Logon Activity
# =====================================================

function Get-UserLogonDurations {
    param(
        [int]$LookbackDays = 90,
        [string[]]$AllowedDomains = @(),
        # Recency half-life (days). Session minutes are weighted 0.5^(ageDays/HalfLife)
        # so a device that changes hands re-ranks toward the new owner within a few
        # half-lives instead of staying anchored to the old owner's historical hours.
        # Set to 0 to disable decay (flat cumulative sum, legacy behaviour).
        [double]$HalfLifeDays = 14
    )

    $startTime   = (Get-Date).AddDays(-$LookbackDays)
    $currentTime = Get-Date

    $logonEvents  = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4624; StartTime=$startTime} -ErrorAction SilentlyContinue
    $logoffEvents = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4634; StartTime=$startTime} -ErrorAction SilentlyContinue

    if (-not $logonEvents) {
        Log "No Security logon events found in the last $LookbackDays days"
        return ,@()   # always an array, never $null (avoids null-deref in verbose callers)
    }

    # --- Boot-segment boundaries (fixes LogonId reuse across reboots) ---
    # TargetLogonId (a LUID) is unique only since the last boot; over a long
    # window the same value recurs, so pairing on LogonId alone conflates
    # sessions from different boots. Segment the timeline by boot (4608 =
    # "Windows is starting up") and key every session as "segment|LogonId".
    $bootEvents = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4608; StartTime=$startTime} -ErrorAction SilentlyContinue
    $bootTimes = @()
    if ($bootEvents) { $bootTimes = @($bootEvents | ForEach-Object { $_.TimeCreated } | Sort-Object) }
    $segmentOf = {
        param($when)
        $seg = 0
        foreach ($bt in $bootTimes) { if ($when -ge $bt) { $seg++ } else { break } }
        $seg
    }

    Log-Debug "Raw 4624=$(@($logonEvents).Count)  4634=$(@($logoffEvents).Count)  boots=$($bootTimes.Count)  halfLife=$HalfLifeDays"

    $logons = @{}
    $debugPassedType = 0
    $debugPassedDomain = 0
    foreach ($e in $logonEvents) {
        $xml = [xml]$e.ToXml()
        $data = @{}
        $xml.Event.EventData.Data | ForEach-Object { $data[$_.Name] = $_.'#text' }

        $logonType = $data['LogonType']
        if ($logonType -ne '2' -and $logonType -ne '10') { continue }
        $debugPassedType++

        $logonId = $data['TargetLogonId']
        if (-not $logonId) { continue }

        $domain = $data['TargetDomainName']
        if ($AllowedDomains -and $AllowedDomains.Count -gt 0 -and $AllowedDomains -notcontains $domain) { continue }
        $debugPassedDomain++

        $userName = $data['TargetUserName']
        if (-not $userName) { continue }

        $seg = & $segmentOf $e.TimeCreated
        $logons["$seg|$logonId"] = @{
            UserName   = $userName
            DomainName = $domain
            LogonTime  = $e.TimeCreated
            LogoffTime = $null
            Closed     = $false
        }
    }
    Log-Debug "FILTERS: PassedType=$debugPassedType PassedDomain=$debugPassedDomain LogonsBuilt=$($logons.Count)"

    # Pair logoffs to logons within the same boot segment
    foreach ($e in $logoffEvents) {
        if (-not $e) { continue }
        $xml = [xml]$e.ToXml()
        $data = @{}
        $xml.Event.EventData.Data | ForEach-Object { $data[$_.Name] = $_.'#text' }
        $logonId = $data['TargetLogonId']
        if (-not $logonId) { continue }
        $key = "$(& $segmentOf $e.TimeCreated)|$logonId"
        if ($logons.ContainsKey($key)) {
            $logons[$key]['LogoffTime'] = $e.TimeCreated
            $logons[$key]['Closed']     = $true
        }
    }

    # Group sessions by (lowercased) user
    $userLogons = @{}
    foreach ($k in $logons.Keys) {
        $entry = $logons[$k]
        $key = $entry['UserName'].ToLower()
        if (-not $userLogons.ContainsKey($key)) {
            $userLogons[$key] = @{ DomainName = $entry['DomainName']; Logons = @() }
        }
        $userLogons[$key]['Logons'] += $entry
    }
    Log-Debug "GROUP: $($userLogons.Keys.Count) unique users: $([string]::Join(', ', $userLogons.Keys))"

    foreach ($user in $userLogons.Keys) {
        $logonList = [System.Collections.ArrayList]$userLogons[$user]['Logons']
        $logonList.Sort([System.Collections.Generic.Comparer[object]]::Create({ param($a,$b) $a['LogonTime'].CompareTo($b['LogonTime']) }))
        $userLogons[$user]['Logons'] = $logonList
    }

    # Close orphaned (no-logoff) sessions at the earliest sensible boundary:
    # the first boot after the logon (machine rebooted, logoff never fired),
    # the same user's next logon, or now — whichever comes first.
    foreach ($user in $userLogons.Keys) {
        $logonList = $userLogons[$user]['Logons']
        for ($i = 0; $i -lt $logonList.Count; $i++) {
            if ($logonList[$i]['Closed']) { continue }
            $candidates = New-Object System.Collections.ArrayList
            if ($i + 1 -lt $logonList.Count) { $null = $candidates.Add($logonList[$i + 1]['LogonTime']) }
            foreach ($bt in $bootTimes) { if ($bt -gt $logonList[$i]['LogonTime']) { $null = $candidates.Add($bt); break } }
            $null = $candidates.Add($currentTime)
            $logonList[$i]['LogoffTime'] = ($candidates | Sort-Object | Select-Object -First 1)
            $logonList[$i]['Closed']     = $true
        }
    }

    # Accumulate raw + recency-weighted minutes per user. Weighting is aged from
    # each session's end time, so an idle-but-logged-on session (closed at "now")
    # still counts fully toward its owner.
    $durations = @{}
    foreach ($user in $userLogons.Keys) {
        $rawMinutes = 0.0
        $weightedMinutes = 0.0
        foreach ($entry in $userLogons[$user]['Logons']) {
            if (-not $entry['LogoffTime'] -or -not $entry['LogonTime']) { continue }
            $dur = ($entry['LogoffTime'] - $entry['LogonTime']).TotalMinutes
            if ($dur -le 0 -or $dur -ge 525600) { continue }
            $rawMinutes += $dur
            if ($HalfLifeDays -gt 0) {
                $ageDays = ($currentTime - $entry['LogoffTime']).TotalDays
                if ($ageDays -lt 0) { $ageDays = 0 }
                $weightedMinutes += $dur * [math]::Pow(0.5, $ageDays / $HalfLifeDays)
            } else {
                $weightedMinutes += $dur
            }
        }
        $durations[$user] = [pscustomobject]@{
            UserName        = $user
            DomainName      = $userLogons[$user]['DomainName']
            TotalMinutes    = [math]::Round($rawMinutes, 1)
            WeightedMinutes = [math]::Round($weightedMinutes, 1)
        }
        Log-Debug "DURATION: $user ($($userLogons[$user]['DomainName'])) = raw $([math]::Round($rawMinutes,1))m / weighted $([math]::Round($weightedMinutes,1))m over $($userLogons[$user]['Logons'].Count) sessions"
    }

    # Rank by recency-weighted minutes (== raw when HalfLifeDays=0)
    $result = New-Object System.Collections.ArrayList
    foreach ($obj in $durations.Values) { $null = $result.Add($obj) }
    $result.Sort([System.Collections.Generic.Comparer[object]]::Create({ param($a,$b) $b.WeightedMinutes.CompareTo($a.WeightedMinutes) }))
    if ($result.Count -gt 0) {
        Log-Debug "RETURN: top=$($result[0].UserName) weighted=$($result[0].WeightedMinutes)m raw=$($result[0].TotalMinutes)m domain=$($result[0].DomainName)"
    }
    Write-Output -NoEnumerate ($result.ToArray())
}

function Log-Debug {
    param([string]$Message)
    if ($Script:VerboseLogging) { Log "DEBUG: $Message" }
}

# Resolve a logged-on user's real email address from Active Directory.
# The logon event only gives us sAMAccountName + NetBIOS/DNS domain, and
# "$sam@$dnsdomain" (e.g. jsmith@company.local) almost never equals the user's
# actual email. The userPrincipalName / mail attributes usually do, so those are
# the authoritative fields for contact matching. Returns an ordered, de-duped
# list of candidate email addresses (best first); empty if AD is unavailable.
function Get-ADUserEmailCandidates {
    param([string]$SamAccountName)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not $SamAccountName) { return $candidates }

    # AD lookup only makes sense on domain-joined machines.
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if (-not $cs.PartOfDomain) { Log-Debug "AD email lookup skipped for '$SamAccountName': not domain-joined"; return $candidates }
    } catch { return $candidates }

    try {
        $domain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()).Name
        $root = "LDAP://$domain"
        $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]$root)
        # Strip any domain prefix/suffix; the event's TargetUserName is the bare sAMAccountName.
        $sam = ($SamAccountName -split '\\')[-1]
        $sam = ($sam -split '@')[0]
        $searcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$sam))"
        $searcher.PropertiesToLoad.AddRange(@("userPrincipalName", "mail")) | Out-Null
        $result = $searcher.FindOne()
        if ($result) {
            # UPN first (per operator guidance it is most often == the ITFlow contact email), then mail.
            $upn  = if ($result.Properties["userprincipalname"]) { "$($result.Properties['userprincipalname'][0])".Trim() } else { "" }
            $mail = if ($result.Properties["mail"]) { "$($result.Properties['mail'][0])".Trim() } else { "" }
            if ($upn)  { $candidates.Add($upn) }
            if ($mail) { $candidates.Add($mail) }
            Log-Debug "AD email candidates for '$sam': UPN='$upn' mail='$mail'"
        } else {
            Log-Debug "AD user object not found for '$sam'"
        }
    } catch {
        Log "AD email lookup failed for ${SamAccountName}: $($_.Exception.Message)"
    }
    return $candidates
}

function Test-ContactInClient {
    # A contact read by email can belong to another client: before ITFlow 26.09 there
    # was no way to narrow a read to one client, and a pre-26.09 server ignores the
    # client_id filter we now send. Verify ownership from the returned row itself so
    # the check holds on every server version.
    #
    # Returns $true when the row is confirmed in-client, or when it carries no client
    # field at all - a leaner response must not silently disable contact assignment.
    param($Contact, [int]$ClientId)

    if (-not $Contact) { return $false }

    foreach ($field in 'contact_client_id', 'client_id') {
        $raw = $null
        try { $raw = $Contact.$field } catch { $raw = $null }
        if ($null -eq $raw -or "$raw" -eq "") { continue }
        $cid = 0
        if ([int]::TryParse(("$raw").Trim(), [ref]$cid)) { return ($cid -eq $ClientId) }
    }

    return $true
}

function Get-ITFlowContactsForClient {
    # Reads return 50 records by default, adjustable with limit/offset. A single
    # unpaged call therefore truncates the contact list on any client with more than
    # 50 contacts, and the name-token fallback in Get-ITFlowContactByUser never sees
    # the remainder. Since v7.5.5 raises a ticket when no contact matches, a truncated
    # list does not just miss a match - it files a spurious "primary contact missing"
    # ticket for a contact that exists.
    param(
        [int]$ClientId,
        [int]$PageSize = 100,
        [int]$MaxPages = 50
    )

    $all  = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $page = 0

    while ($page -lt $MaxPages) {
        $offset = $page * $PageSize
        $uri = New-ITFlowReadUri -Endpoint 'contacts/read.php' -Query ([ordered]@{ client_id = $ClientId; limit = $PageSize; offset = $offset })
        $resp = Invoke-ITFlowChecked GET $uri $null "Contacts page $($page + 1) for client $ClientId"

        if (-not $resp -or "$($resp.success)" -ne "True" -or -not $resp.data) { break }
        $rows = @($resp.data)
        if ($rows.Count -eq 0) { break }

        $newInPage = 0
        foreach ($row in $rows) {
            $cid = "$($row.contact_id)"
            if ($cid -and $seen.ContainsKey($cid)) { continue }
            if ($cid) { $seen[$cid] = $true }
            $newInPage++
            if (Test-ContactInClient -Contact $row -ClientId $ClientId) { $all.Add($row) | Out-Null }
        }

        # A page that contributed nothing new means the server ignored offset. Stop
        # rather than re-reading the same page until the cap.
        if ($newInPage -eq 0) {
            Log-Debug "Contact paging: page $($page + 1) returned no new contacts (offset appears unsupported) - stopping"
            break
        }

        # A short page is the last page.
        if ($rows.Count -lt $PageSize) { $page++; break }
        $page++
    }

    if ($page -ge $MaxPages) {
        Log "Contact paging hit the $MaxPages-page cap for client $ClientId ($($all.Count) read) - the name-token fallback may be working from a partial list."
    }
    Log-Debug "Contact paging: read $($all.Count) contact(s) for client $ClientId across $page page(s)"
    return $all
}

function Get-ITFlowContactByUser {
    param(
        [string]$UserName,
        [string]$DomainName,
        [int]$ClientId
    )

    # Build the ordered list of email candidates to try against ITFlow. AD-resolved
    # UPN/mail come first (authoritative); the constructed "$UserName@$DomainName" is
    # only a fallback for non-domain / Entra-joined machines where AD isn't reachable.
    $candidateEmails = New-Object System.Collections.Generic.List[string]
    foreach ($e in (Get-ADUserEmailCandidates -SamAccountName $UserName)) {
        if ($e -and -not $candidateEmails.Contains($e)) { $candidateEmails.Add($e) }
    }
    # If the logon name already looks like a UPN/email (common on Entra-joined devices), use it.
    if ($UserName -like '*@*' -and -not $candidateEmails.Contains($UserName)) { $candidateEmails.Add($UserName) }
    $fallbackEmail = "$UserName@$DomainName"
    if (-not $candidateEmails.Contains($fallbackEmail)) { $candidateEmails.Add($fallbackEmail) }

    foreach ($candidateEmail in $candidateEmails) {
        try {
            # ITFlow 26.09: reads accept an optional client_id filter on top of the
            # key's own scoping, and it can only narrow. Without it an all-clients key
            # matching on email alone can return a contact belonging to a DIFFERENT
            # client and assign it to this asset. Sent as a filter here and verified
            # again below, because a pre-26.09 server ignores the parameter.
            $uri = New-ITFlowReadUri -Endpoint 'contacts/read.php' -Query ([ordered]@{ client_id = $ClientId; contact_email = $candidateEmail })
            $resp = Invoke-ITFlowChecked GET $uri $null "Contact lookup by email"
            if ($resp -and "$($resp.success)" -eq "True" -and $resp.data -and $resp.data.Count -gt 0) {
                $contact = $resp.data | Where-Object { Test-ContactInClient -Contact $_ -ClientId $ClientId } | Select-Object -First 1
                if ($contact) {
                    Log "Contact found by email match: $candidateEmail -> ID $($contact.contact_id)"
                    return [int]$contact.contact_id
                }
                Log "Email lookup for $candidateEmail matched $($resp.data.Count) contact(s), none in client $ClientId - ignoring (cross-client match)"
            }
            Log-Debug "Email lookup did not return a contact for $candidateEmail"
        } catch {
            Log "Email contact lookup failed for ${candidateEmail}: $($_.Exception.Message)"
        }
    }

    try {
        # Reads return 50 records by default, so an unpaged list silently truncates on
        # any client with more than 50 contacts and the name-token fallback below never
        # sees the rest. Page through the whole list instead.
        $contactList = Get-ITFlowContactsForClient -ClientId $ClientId
        if ($contactList -and $contactList.Count -gt 0) {
            Log-Debug "Contact list returned $($contactList.Count) contacts, checking for name match..."
            foreach ($contact in $contactList) {
                $contactName = Normalize-Value $contact.contact_name
                if (-not $contactName) { continue }

                $tokens = $contactName -split '[\s\.\-_]+' | Where-Object { $_.Length -gt 0 }
                $userTokens = $UserName -split '[\s\.\-_]+' | Where-Object { $_.Length -gt 0 }
                if ($tokens.Count -eq 0 -or $userTokens.Count -eq 0) { continue }

                $allMatch = $true
                foreach ($token in $tokens) {
                    $match = $false
                    foreach ($uToken in $userTokens) {
                        if ($token -eq $uToken) {
                            $match = $true
                            break
                        }
                    }
                    if (-not $match) { $allMatch = $false; break }
                }

                if ($allMatch) {
                    foreach ($uToken in $userTokens) {
                        $match = $false
                        foreach ($token in $tokens) {
                            if ($token -eq $uToken) {
                                $match = $true
                                break
                            }
                        }
                        if (-not $match) { $allMatch = $false; break }
                    }
                }

                if ($allMatch) {
                    Log "Contact found by name token match: $contactName -> ID $($contact.contact_id)"
                    return [int]$contact.contact_id
                }
            }
        }
    } catch {
        Log "Contact list lookup failed for client ${ClientId}: $($_.Exception.Message)"
    }

    Log "No ITFlow contact found for $DomainName\$UserName"
    return $null
}

function Set-ITFlowAssetContact {
    param(
        [int]$AssetId,
        [int]$ContactId,
        [int]$ClientId
    )

    $body = @{
        api_key          = $Config.ApiKey
        asset_id         = $AssetId
        client_id        = $ClientId
        asset_contact_id = $ContactId
    }

    try {
        $resp = Invoke-ITFlow POST "$($Config.BaseUrl)/api/v1/assets/update.php" $body
        if ($resp -and "$($resp.success)" -eq "True") {
            Log "Asset $AssetId contact assigned to contact ID $ContactId"
            Set-AgentCacheValue -Name "LastAssignedContactId" -Value $ContactId
            return $true
        } else {
            $msg = if ($resp -and $resp.message) { $resp.message } else { "Unknown error" }
            $null = Register-ITFlowFailure -Text $msg -Action "Asset contact assign"
            Log "Asset contact assignment failed for asset ${AssetId}: $msg"
            return $false
        }
    } catch {
        $err = $_.Exception.Message
        $null = Register-ITFlowFailure -Text $err -Action "Asset contact assign"
        Log "Asset contact assignment API call failed: $err"
        return $false
    }
}

# =====================================================
# INVENTORY
# =====================================================
function Get-PrimaryInterfaceIndex {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1
    if ($route) { $route.InterfaceIndex } else { $null }
}

function Get-PrimaryMAC {
    $ifIndex = Get-PrimaryInterfaceIndex
    if ($ifIndex) {
        $adapter = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.MacAddress) { return Normalize-Mac $adapter.MacAddress }
    }
    # WMI fallback: find the IP-enabled adapter that has a default gateway
    $nic = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.MACAddress -and $_.DefaultIPGateway } |
        Select-Object -First 1
    if ($nic) { return Normalize-Mac $nic.MACAddress }
    return $null
}

function Get-PrimaryIP {
    $ifIndex = Get-PrimaryInterfaceIndex
    if ($ifIndex) {
        $ip = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return [string]$ip }
    }
    # WMI fallback: find the IP-enabled adapter that has a default gateway
    $nic = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.IPAddress -and $_.DefaultIPGateway } |
        Select-Object -First 1
    if ($nic) {
        return ($nic.IPAddress | Where-Object {
            $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and
            $_ -notlike '169.*' -and
            $_ -ne '127.0.0.1'
        } | Select-Object -First 1)
    }
    return $null
}

function Get-OSFeatureVersion {
    # Windows feature update (24H2, 21H2...). DisplayVersion exists from 20H2;
    # ReleaseId (2009, 1909...) is the fallback on older builds. ITFlow's own asset
    # examples carry it ("Windows 11 Pro 24H2"), and it is what tells a supported
    # Windows 11 release from an expired one - the Caption alone cannot.
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $dv = Normalize-Value $cv.DisplayVersion
        if ($dv) { return $dv }
        $rid = Normalize-Value $cv.ReleaseId
        if ($rid) { return $rid }
    } catch { }
    return ""
}

function Get-OSDisplayName {
    # Caption plus feature version, e.g. "Microsoft Windows 11 Pro 24H2". ITFlow's
    # Asset Lifecycle end-of-support patterns (windows 10 not LTSC, server 2012 and
    # older) still match with the suffix appended.
    param([string]$Caption)
    $c = Normalize-Value $Caption
    if (-not $c) { return $c }
    $fv = Get-OSFeatureVersion
    if ($fv -and ($c -notmatch ('\b' + [regex]::Escape($fv) + '\b'))) { return "$c $fv" }
    return $c
}

function Get-LocalInventory {
    param(
        $ComputerSystem = $null,
        $OperatingSystem = $null
    )
    @{
        Serial   = (Get-CimInstance Win32_BIOS).SerialNumber
        Hostname = $env:COMPUTERNAME
        Make     = if ($ComputerSystem) { $ComputerSystem.Manufacturer } else { (Get-CimInstance Win32_ComputerSystem).Manufacturer }
        Model    = if ($ComputerSystem) { $ComputerSystem.Model } else { (Get-CimInstance Win32_ComputerSystem).Model }
        OS       = Get-OSDisplayName $(if ($OperatingSystem) { $OperatingSystem.Caption } else { (Get-CimInstance Win32_OperatingSystem).Caption })
        MAC      = Normalize-Mac (Get-PrimaryMAC)
        IP       = Get-PrimaryIP
    }
}

function Get-QuickLocalDeviceOverview {
    # Fast, local "source of truth" snapshot for the GUI overview.
    # No ITFlow dependency. No registry/cache dependency.
    $inv = $null
    try { $inv = [pscustomobject](Get-LocalInventory) } catch { $inv = $null }

    $type = ""
    try {
        $type = Get-AssetType
    } catch {
        $type = ""
    }

    # Normalize blanks
    if ($null -eq $inv) {
        $inv = [pscustomobject]@{ Serial=''; Hostname=$env:COMPUTERNAME; Make=''; Model=''; OS=''; MAC=''; IP='' }
    }

    return [pscustomobject]@{
        Hostname = [string]$inv.Hostname
        Serial   = [string]$inv.Serial
        Type     = [string]$type
        IP       = [string]$inv.IP
        MAC      = [string]$inv.MAC
    }
}


function Get-AssetType {
    param(
        $ComputerSystem = $null,
        $OperatingSystem = $null
    )
    $type = "Other"
    try {
        if (-not $ComputerSystem) { $ComputerSystem = Get-CimInstance Win32_ComputerSystem }
        if (-not $OperatingSystem) { $OperatingSystem = Get-CimInstance Win32_OperatingSystem }
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue

        $manufacturer = ($ComputerSystem.Manufacturer | ForEach-Object { $_.ToString() })
        $model        = ($ComputerSystem.Model        | ForEach-Object { $_.ToString() })
        $caption      = ($OperatingSystem.Caption      | ForEach-Object { $_.ToString() })

        $vmKeywords = @("VMware","VirtualBox","KVM","QEMU","Xen","HVM","Virtual Machine","Hyper-V","Microsoft Corporation")

        if ($vmKeywords | Where-Object { $model -match $_ }) { return "Virtual Machine" }
        if (($manufacturer -match "Microsoft Corporation") -and ($model -match "Virtual")) { return "Virtual Machine" }
        if ($caption -match "Server") { return "Server" }

        $chassis = @()
        if ($enclosure -and $enclosure.ChassisTypes) { $chassis = @($enclosure.ChassisTypes) }
        $pcSystemType = 0
        try { $pcSystemType = [int]$ComputerSystem.PCSystemType } catch { $pcSystemType = 0 }
        $script:LastChassisInfo = "chassis=$($chassis -join ','), PCSystemType=$pcSystemType"

        # SMBIOS chassis types. ITFlow 26.11 gates CPU/RAM/storage details by asset
        # type and "Other" has none, so every PC form factor must land on Laptop or
        # Desktop. ITFlow has no all-in-one type; Desktop carries the right details.
        # ITFlow's Tablet type is for mobile devices (phone number, carrier, IMEI),
        # so Windows tablets and 2-in-1s are Laptops.
        #   Laptop : 8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 12 Docking
        #            Station, 14 Sub Notebook, 18 Expansion Chassis, 21 Peripheral
        #            Chassis, 30 Tablet, 31 Convertible, 32 Detachable
        #   Desktop: 3 Desktop, 4 Low Profile, 5 Pizza Box, 6 Mini Tower, 7 Tower,
        #            13 All in One, 15 Space-saving, 16 Lunch Box, 24 Sealed-case
        #            PC, 35 Mini PC, 36 Stick PC
        #   Rack   : 17 Main Server Chassis, 23 Rack Mount, 28 Blade - with a client
        #            OS (Server OS returned above) this is a rack workstation: Desktop
        $laptopChassis  = @(8,9,10,11,12,14,18,21,30,31,32)
        $desktopChassis = @(3,4,5,6,7,13,15,16,24,35,36)
        $rackChassis    = @(17,23,28)

        if ($chassis | Where-Object { $laptopChassis -contains $_ })  { return "Laptop"  }
        if ($chassis | Where-Object { $desktopChassis -contains $_ }) { return "Desktop" }
        if ($chassis | Where-Object { $rackChassis -contains $_ })    { return "Desktop" }

        # Firmware reporting chassis 1/2 (Other/Unknown): Windows' own power-profile
        # classification. 2 Mobile, 8 Slate -> Laptop; 1 Desktop, 3 Workstation,
        # 6 Appliance PC -> Desktop. (4/5/7 are server roles, decided by OS above.)
        if (@(2,8) -contains $pcSystemType)   { return "Laptop"  }
        if (@(1,3,6) -contains $pcSystemType) { return "Desktop" }

        if ($model -match "Book|Notebook|Laptop|Ultrabook|ThinkPad|Latitude|EliteBook|ProBook") { return "Laptop" }
        if ($model -match "AIO|All-in-One|AllInOne") { return "Desktop" }
        if ($model -match "Server|PowerEdge|ProLiant|ThinkSystem") { return "Server" }

        return $type
    } catch { return $type }
}


# =====================================================
# LOCAL SYSINFO COLLECTION (Sidecar Snapshot)
# PowerShell 5.1 safe. Silent/GUI safe. No API dependency.
# =====================================================

function Get-CpuInfo {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        [pscustomobject]@{
            Manufacturer = $cpu.Manufacturer
            Name         = $cpu.Name
            CoreCount    = $cpu.NumberOfCores
            LogicalCount = $cpu.NumberOfLogicalProcessors
            MaxClockMHz  = $cpu.MaxClockSpeed
        }
    } catch { $null }
}

function Get-MemoryInfo {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bytes = [int64]$cs.TotalPhysicalMemory
        [pscustomobject]@{
            TotalBytes = $bytes
            TotalGB    = if ($bytes -gt 0) { [math]::Round($bytes / 1GB, 2) } else { $null }
        }
    } catch { $null }
}

function Get-StorageInfo {
    $physicalDisks = @()
    $volumes = @()

    # Prefer MSFT_PhysicalDisk for MediaType (SSD/HDD)
    try {
        $pd = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop
        foreach ($d in $pd) {
            $media = "Unspecified"
            switch ($d.MediaType) {
                3 { $media = "HDD" }  # 3 = HDD
                4 { $media = "SSD" }  # 4 = SSD
                default { $media = "Unspecified" }
            }

            $physicalDisks += [pscustomobject]@{
                FriendlyName      = $d.FriendlyName
                Model             = $d.Model
                Serial            = $d.SerialNumber
                BusType           = $d.BusType
                MediaType         = $media
                SizeBytes         = [int64]$d.Size
                HealthStatus      = $d.HealthStatus
                OperationalStatus = ($d.OperationalStatus -join ",")
            }
        }
    } catch {
        # Fallback: Win32_DiskDrive (MediaType is not always reliable)
        try {
            $dd = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop
            foreach ($d in $dd) {
                $guess = "Unspecified"
                if ($d.Model -match "SSD") { $guess = "SSD" }

                $physicalDisks += [pscustomobject]@{
                    FriendlyName      = $d.Caption
                    Model             = $d.Model
                    Serial            = $null
                    BusType           = $d.InterfaceType
                    MediaType         = $guess
                    SizeBytes         = [int64]$d.Size
                    HealthStatus      = $null
                    OperationalStatus = $null
                }
            }
        } catch { }
    }

    # Logical volumes (fixed disks)
    try {
        $lv = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        foreach ($v in $lv) {
            $volumes += [pscustomobject]@{
                DriveLetter = $v.DeviceID
                Label       = $v.VolumeName
                FileSystem  = $v.FileSystem
                SizeBytes   = [int64]$v.Size
                FreeBytes   = [int64]$v.FreeSpace
            }
        }
    } catch { }

    $physicalTotal = 0
    if ($physicalDisks.Count -gt 0) {
        $physicalTotal = ($physicalDisks | Measure-Object -Property SizeBytes -Sum).Sum
    }

    $volumeTotal = 0
    if ($volumes.Count -gt 0) {
        $volumeTotal = ($volumes | Measure-Object -Property SizeBytes -Sum).Sum
    }

    [pscustomobject]@{
        Totals = [pscustomobject]@{
            PhysicalTotalBytes = [int64]$physicalTotal
            PhysicalTotalGB    = if ($physicalTotal -gt 0) { [math]::Round($physicalTotal / 1GB, 2) } else { $null }
            VolumeTotalBytes   = [int64]$volumeTotal
            VolumeTotalGB      = if ($volumeTotal -gt 0)   { [math]::Round($volumeTotal / 1GB, 2) } else { $null }
        }
        PhysicalDisks = $physicalDisks
        Volumes       = $volumes
    }
}

function Get-DisplayVendorName {
    # EDID ManufacturerName is a 3-letter PNP ID (e.g. "DEL"), not a real vendor
    # name. Map the common ones for a usable asset_make; unknown codes pass through.
    param([string]$PnpId)
    if ([string]::IsNullOrWhiteSpace($PnpId)) { return $PnpId }
    $map = @{
        "DEL" = "Dell"; "SAM" = "Samsung"; "LGD" = "LG"; "GSM" = "LG";
        "AUS" = "ASUS"; "ACI" = "Acer"; "ACR" = "Acer"; "HWP" = "HP";
        "HPN" = "HP"; "BNQ" = "BenQ"; "VSC" = "ViewSonic"; "PHL" = "Philips";
        "LEN" = "Lenovo"; "MSI" = "MSI"; "GBT" = "Gigabyte"; "SNY" = "Sony";
        "SHP" = "Sharp"; "NEC" = "NEC"; "EIZ" = "EIZO"; "IVM" = "Iiyama"
    }
    $key = $PnpId.Trim().ToUpperInvariant()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return $PnpId
}

function Get-DisplayInfo {
    # EDID-based: name, physical size, per-monitor preferred resolution and
    # embedded/external classification. Best-effort - not every GPU driver
    # populates WmiMonitorConnectionParams or WmiMonitorListedSupportedSourceModes.
    $displays = @()

    $monId = $null
    $monSize = $null
    $monConn = $null
    $monModes = $null
    try { $monId = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue } catch { }
    try { $monSize = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue } catch { }
    try { $monConn = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue } catch { }
    try { $monModes = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction SilentlyContinue } catch { }

    # Fallback "current resolution", shared across monitors - used only for a
    # monitor with no listed source modes of its own.
    $fallbackResW = $null
    $fallbackResH = $null
    try {
        $video = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
        if ($video) {
            $primary = $video | Sort-Object CurrentHorizontalResolution -Descending | Select-Object -First 1
            $fallbackResW = $primary.CurrentHorizontalResolution
            $fallbackResH = $primary.CurrentVerticalResolution
        }
    } catch { }

    $sizeByInstance  = @{}
    if ($monSize)  { foreach ($s in $monSize)  { $sizeByInstance[$s.InstanceName]  = $s } }
    $connByInstance  = @{}
    if ($monConn)  { foreach ($c in $monConn)  { $connByInstance[$c.InstanceName]  = $c } }
    $modesByInstance = @{}
    if ($monModes) { foreach ($m in $monModes) { $modesByInstance[$m.InstanceName] = $m } }

    # DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL - reported for a built-in panel.
    $internalVideoOutputTechnology = -2147483648

    if ($monId) {
        foreach ($m in $monId) {
            $inst = $m.InstanceName

            $friendly = Convert-EdidString $m.UserFriendlyName
            $mfg      = Convert-EdidString $m.ManufacturerName
            $serial   = Convert-EdidString $m.SerialNumberID
            $prod     = Convert-EdidString $m.ProductCodeID

            $diagIn = $null
            if ($sizeByInstance.ContainsKey($inst)) {
                $s = $sizeByInstance[$inst]
                if ($s.MaxHorizontalImageSize -gt 0 -and $s.MaxVerticalImageSize -gt 0) {
                    $w = [double]$s.MaxHorizontalImageSize
                    $h = [double]$s.MaxVerticalImageSize
                    $diagIn = [math]::Round(([math]::Sqrt(($w*$w)+($h*$h)) / 2.54), 1)
                }
            }

            # Embedded (built-in laptop/AIO panel) vs external. Fail safe: an
            # unreadable signal defaults to embedded, so it never generates an
            # ITFlow lookup or ticket for a laptop's own screen.
            $isEmbedded = $true
            if ($connByInstance.ContainsKey($inst)) {
                try {
                    $vot = [int64]$connByInstance[$inst].VideoOutputTechnology
                    $isEmbedded = ($vot -eq $internalVideoOutputTechnology)
                } catch { $isEmbedded = $true }
            }

            # This monitor's own preferred resolution, falling back to the shared
            # "current resolution" only when it has no listed source modes.
            $resW = $null
            $resH = $null
            if ($modesByInstance.ContainsKey($inst)) {
                try {
                    $modeInfo = $modesByInstance[$inst]
                    $modes = @($modeInfo.MonitorSourceModes)
                    $prefIdx = [int]$modeInfo.PreferredMonitorSourceModeIndex
                    if ($modes.Count -gt 0 -and $prefIdx -ge 0 -and $prefIdx -lt $modes.Count) {
                        $resW = $modes[$prefIdx].HorizontalActivePixels
                        $resH = $modes[$prefIdx].VerticalActivePixels
                    }
                } catch { }
            }
            if (-not ($resW -and $resH)) { $resW = $fallbackResW; $resH = $fallbackResH }

            $displays += [pscustomobject]@{
                FriendlyName     = if ([string]::IsNullOrWhiteSpace($friendly)) { $null } else { $friendly }
                Manufacturer     = if ([string]::IsNullOrWhiteSpace($mfg)) { $null } else { $mfg }
                ProductCode      = if ([string]::IsNullOrWhiteSpace($prod)) { $null } else { $prod }
                Serial           = if ([string]::IsNullOrWhiteSpace($serial)) { $null } else { $serial }
                SizeInches       = $diagIn
                NativeResolution = if ($resW -and $resH) { [pscustomobject]@{ Width = $resW; Height = $resH } } else { $null }
                IsEmbedded       = $isEmbedded
            }
        }
    }

    # Fallback when EDID isn't available at all: one synthetic entry with no
    # identity to match against ITFlow, so it's marked embedded and never sent.
    if ($displays.Count -eq 0) {
        if ($fallbackResW -and $fallbackResH) {
            $displays += [pscustomobject]@{
                FriendlyName     = $null
                Manufacturer     = $null
                ProductCode      = $null
                Serial           = $null
                SizeInches       = $null
                NativeResolution = [pscustomobject]@{ Width = $fallbackResW; Height = $fallbackResH }
                IsEmbedded       = $true
            }
        }
    }

    return $displays
}

function Get-NetworkInfo {
    $adapters = @()

    $hasNetAdapter = (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -ne $null

    if ($hasNetAdapter) {
        $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue
        foreach ($na in $netAdapters) {
            $ips = @()

            $ipAddrs = Get-NetIPAddress -InterfaceIndex $na.ifIndex -ErrorAction SilentlyContinue |
                       Where-Object { $_.IPAddress -and $_.AddressState -ne "Invalid" }

            foreach ($ip in $ipAddrs) {
                $gw = $null
                try {
                    if ($ip.AddressFamily -eq "IPv4") {
                        $gw = (Get-NetRoute -InterfaceIndex $na.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                               Sort-Object RouteMetric | Select-Object -First 1).NextHop
                    } elseif ($ip.AddressFamily -eq "IPv6") {
                        $gw = (Get-NetRoute -InterfaceIndex $na.ifIndex -DestinationPrefix "::/0" -ErrorAction SilentlyContinue |
                               Sort-Object RouteMetric | Select-Object -First 1).NextHop
                    }
                } catch { }

                $ips += [pscustomobject]@{
                    AddressFamily  = $ip.AddressFamily.ToString()
                    IPAddress      = $ip.IPAddress
                    PrefixLength   = $ip.PrefixLength
                    DefaultGateway = $gw
                }
            }

            $adapters += [pscustomobject]@{
                Name                 = $na.Name
                InterfaceDescription = $na.InterfaceDescription
                Status               = $na.Status.ToString()
                MacAddress           = Normalize-Mac $na.MacAddress
                LinkSpeed            = if ($na.LinkSpeed) { $na.LinkSpeed.ToString() } else { $null }
                IfIndex              = $na.ifIndex
                Ips                  = $ips
            }
        }
    }
    else {
        # WMI fallback
        try {
            $nics = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue
            foreach ($n in $nics) {
                $ips = @()
                if ($n.IPAddress) {
                    foreach ($addr in $n.IPAddress) {
                        $fam = if ($addr -match ":") { "IPv6" } else { "IPv4" }
                        $ips += [pscustomobject]@{
                            AddressFamily  = $fam
                            IPAddress      = $addr
                            PrefixLength   = $null
                            DefaultGateway = ($n.DefaultIPGateway | Select-Object -First 1)
                        }
                    }
                }

                $adapters += [pscustomobject]@{
                    Name                 = $n.Description
                    InterfaceDescription = $n.Description
                    Status               = if ($n.IPEnabled) { "Up" } else { "Down" }
                    MacAddress           = Normalize-Mac $n.MACAddress
                    LinkSpeed            = $null
                    IfIndex              = $n.InterfaceIndex
                    Ips                  = $ips
                }
            }
        } catch { }
    }

    [pscustomobject]@{ Adapters = $adapters }
}

function Get-FullSnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$AgentVersion
    )

    # Query CIM instances once and share across collectors
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    } catch {
        Log "CIM query failed in Get-FullSnapshot: $($_.Exception.Message)"
        throw
    }

    # Existing local inventory + derived type
    $inv = Get-LocalInventory -ComputerSystem $cs -OperatingSystem $os
    $assetType = Get-AssetType -ComputerSystem $cs -OperatingSystem $os

    # Extra collectors
    $cpu      = Get-CpuInfo
    $memory   = Get-MemoryInfo
    $storage  = Get-StorageInfo
    $displays = Get-DisplayInfo
    $network  = Get-NetworkInfo

    [ordered]@{
        Meta = [pscustomobject]@{
            CollectedAt   = (Get-Date).ToString("o")
            Hostname      = $env:COMPUTERNAME
            AgentVersion  = $AgentVersion
            SchemaVersion = 1
        }

        Device = [pscustomobject]@{
            Serial     = $inv.Serial
            Hostname   = $inv.Hostname
            Make       = $inv.Make
            Model      = $inv.Model
            OS         = $inv.OS
            PrimaryMAC = $inv.MAC
            PrimaryIP  = $inv.IP
            AssetType  = $assetType
            AssetStatus = $DefaultAssetStatus
        }

        CPU      = $cpu
        Memory   = $memory
        Storage  = $storage
        Displays = @($displays)
        Network  = $network

        # Expose raw CIM objects so callers avoid re-querying
        _CimComputerSystem    = $cs
        _CimOperatingSystem   = $os
    }
}

# =====================================================
# asset_specs (ITFlow asset details)
# The API takes per-type details as an asset_specs object. Only the keys the
# reference lists for a type are kept: Laptop/Desktop/Server take cpu, ram_gb,
# storage; Virtual Machine takes vcpus, ram_gb, storage (vm_host is left to the
# technician). Updates overlay what is sent, so only changed keys are sent.
# =====================================================

function Format-ITFlowDiskSize {
    # Decimal units, rounded the way drives are labelled (512 GB, 1 TB, 1.9 TB).
    param([int64]$Bytes)
    if ($Bytes -le 0) { return "" }
    $gb = $Bytes / 1000000000
    if ($gb -ge 1000) {
        $tb = [math]::Round($gb / 1000, 1)
        if ($tb -eq [math]::Floor($tb)) { return ("{0} TB" -f [int64]$tb) }
        return ("{0} TB" -f $tb.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    }
    return ("{0} GB" -f [int64][math]::Round($gb, 0))
}

function Get-ITFlowAssetSpecs {
    # Map the local snapshot to the asset_specs keys for this asset type.
    # Returns an ordered hashtable; empty when the type has no keys we can fill.
    param(
        [Parameter(Mandatory=$true)]$Snapshot,
        [string]$AssetType
    )

    $specs = [ordered]@{}
    $isPhysical = @("Laptop","Desktop","Server") -contains $AssetType
    $isVm = ($AssetType -eq "Virtual Machine")
    if (-not $isPhysical -and -not $isVm) { return $specs }

    $cs = $null
    try { $cs = $Snapshot._CimComputerSystem } catch { $cs = $null }

    # cpu (physical) / vcpus (VM)
    if ($isPhysical -and $Snapshot.CPU -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.CPU.Name)) {
        $cpuName = (([string]$Snapshot.CPU.Name) -replace '\s+', ' ').Trim()
        $sockets = 0
        try { if ($cs) { $sockets = [int]$cs.NumberOfProcessors } } catch { $sockets = 0 }
        if ($sockets -gt 1) { $cpuName = "$sockets x $cpuName" }
        $specs.cpu = $cpuName
    }
    if ($isVm) {
        # Get-CpuInfo reads only the first Win32_Processor; a VM often presents one
        # socket per vCPU, so take the total from Win32_ComputerSystem.
        $vcpus = 0
        try { if ($cs) { $vcpus = [int]$cs.NumberOfLogicalProcessors } } catch { $vcpus = 0 }
        if ($vcpus -le 0 -and $Snapshot.CPU) { try { $vcpus = [int]$Snapshot.CPU.LogicalCount } catch { $vcpus = 0 } }
        if ($vcpus -gt 0) { $specs.vcpus = $vcpus }
    }

    # ram_gb: installed modules first (TotalPhysicalMemory is net of hardware
    # reservations, e.g. 16 GB with shared graphics reads as ~14), then fallback.
    $ramGb = 0
    try {
        $mods = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        $sum = [int64]0
        foreach ($m in $mods) { try { $sum += [int64]$m.Capacity } catch { } }
        if ($sum -gt 0) { $ramGb = [int][math]::Round($sum / 1GB, 0) }
    } catch { $ramGb = 0 }
    if ($ramGb -le 0 -and $Snapshot.Memory -and $Snapshot.Memory.TotalGB) {
        try { $ramGb = [int][math]::Round([double]$Snapshot.Memory.TotalGB, 0) } catch { $ramGb = 0 }
    }
    if ($ramGb -gt 0) { $specs.ram_gb = $ramGb }

    # storage: internal physical disks, e.g. "512 GB SSD, 2 TB HDD". USB disks
    # (MSFT_PhysicalDisk BusType 7, or Win32_DiskDrive InterfaceType 'USB') are
    # removable media, not part of the machine's spec.
    $diskParts = New-Object System.Collections.Generic.List[string]
    if ($Snapshot.Storage -and $Snapshot.Storage.PhysicalDisks) {
        foreach ($d in @($Snapshot.Storage.PhysicalDisks)) {
            $bus = "$($d.BusType)"
            if ($bus -eq "7" -or $bus -match '(?i)^usb$') { continue }
            $size = Format-ITFlowDiskSize ([int64]$d.SizeBytes)
            if (-not $size) { continue }
            $media = "$($d.MediaType)"
            if ($media -eq "SSD" -or $media -eq "HDD") { $size = "$size $media" }
            $diskParts.Add($size) | Out-Null
        }
    }
    if ($diskParts.Count -gt 0) { $specs.storage = ($diskParts -join ', ') }

    return $specs
}

function Get-ITFlowDisplaySpecs {
    # Map one Get-DisplayInfo record to the Display asset_specs keys: size_in and
    # resolution. Returns an ordered hashtable; empty when neither is known.
    param($Display)

    $specs = [ordered]@{}
    if ($Display.SizeInches) {
        $sizeStr = ([double]$Display.SizeInches).ToString("0.#", [System.Globalization.CultureInfo]::InvariantCulture)
        $specs.size_in = $sizeStr
    }
    if ($Display.NativeResolution -and $Display.NativeResolution.Width -and $Display.NativeResolution.Height) {
        $specs.resolution = "$($Display.NativeResolution.Width)x$($Display.NativeResolution.Height)"
    }
    return $specs
}

function ConvertTo-ITFlowSpecMap {
    # Normalise asset_specs from a read row into a hashtable. Returns $null when
    # the row has no asset_specs property at all (a server that predates specs),
    # so the caller can tell "no details yet" from "this server has no details".
    # PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, hence the walk.
    param($Asset)

    if ($null -eq $Asset) { return $null }
    if (-not ($Asset.PSObject.Properties.Name -contains 'asset_specs')) { return $null }

    $raw = $Asset.asset_specs
    $map = @{}
    if ($null -eq $raw) { return $map }

    if ($raw -is [string]) {
        $t = $raw.Trim()
        if ($t -eq "" -or $t -eq "[]" -or $t -eq "{}") { return $map }
        try { $raw = $t | ConvertFrom-Json -ErrorAction Stop } catch { return $map }
    }
    # PHP encodes an empty associative array as [] - nothing to read.
    if ($raw -is [System.Array]) { return $map }

    foreach ($p in $raw.PSObject.Properties) {
        $map[[string]$p.Name] = Normalize-Value $p.Value
    }
    return $map
}

function Test-ITFlowSpecValueEqual {
    # Numbers compare numerically ("16" vs 16 vs "16.0"); text case-insensitively
    # with whitespace collapsed, since ITFlow may normalise either.
    param([string]$Local, [string]$Remote)
    $l = ($Local  -replace '\s+', ' ').Trim()
    $r = ($Remote -replace '\s+', ' ').Trim()
    $ld = 0.0; $rd = 0.0
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $ns = [System.Globalization.NumberStyles]::Float
    if ([double]::TryParse($l, $ns, $ci, [ref]$ld) -and [double]::TryParse($r, $ns, $ci, [ref]$rd)) {
        return ($ld -eq $rd)
    }
    return ($l -eq $r)
}

function Get-ITFlowAssetSpecsDelta {
    # Keys of $Local whose value differs from what the asset already has.
    param($Local, $Remote)
    $delta = [ordered]@{}
    if (-not $Local) { return $delta }
    foreach ($k in $Local.Keys) {
        $lv = Normalize-Value $Local[$k]
        $rv = ""
        if ($Remote -and $Remote.ContainsKey($k)) { $rv = $Remote[$k] }
        if (-not (Test-ITFlowSpecValueEqual $lv $rv)) { $delta[$k] = $Local[$k] }
    }
    return $delta
}

function Write-ITFlowSpecsNotKept {
    # The server reports specs it refused (wrong key for the type, value out of
    # range) as asset_specs_not_kept, at the top level or inside data[0].
    param($Response, [string]$Action = "Asset update")
    if ($null -eq $Response) { return }
    $nk = $null
    try { if ($Response.PSObject.Properties.Name -contains 'asset_specs_not_kept') { $nk = $Response.asset_specs_not_kept } } catch { }
    if ($null -eq $nk) {
        try {
            $first = @($Response.data)[0]
            if ($first -and $first.PSObject.Properties.Name -contains 'asset_specs_not_kept') { $nk = $first.asset_specs_not_kept }
        } catch { }
    }
    if ($null -eq $nk) { return }

    if ($nk -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($nk)) { Log "ASSET SPECS NOT KEPT ($Action): $nk" }
        return
    }
    if ($nk -is [System.Array]) {
        foreach ($item in $nk) { Log "ASSET SPECS NOT KEPT ($Action): $item" }
        return
    }
    foreach ($p in $nk.PSObject.Properties) {
        Log "ASSET SPECS NOT KEPT ($Action): $($p.Name) - $($p.Value)"
    }
}

function Sync-ITFlowDisplayAssets {
    # Enrichment only, never creation: for each external monitor with a readable
    # EDID serial, look for an existing Display asset with that serial in this
    # client and update its make/model/asset_specs. A monitor with no match is
    # left alone unless TicketUnmatchedDisplays opts into a one-time-per-serial
    # ticket, so a technician can label/create the asset through the org's own
    # process. Embedded panels (laptops, AIOs, tablets) are the caller's job to
    # filter out via Display.IsEmbedded before this is reached.
    param(
        [Parameter(Mandatory=$true)]$Displays,
        [Parameter(Mandatory=$true)][int]$ClientId,
        [string]$HostHostname,
        [string]$HostSerial,
        [bool]$PushDisplaySpecs = $true,
        [bool]$TicketUnmatchedDisplays = $false,
        [bool]$TicketingEnabled = $false
    )

    if (-not $PushDisplaySpecs) { return }
    if (-not $Displays) { return }

    foreach ($display in @($Displays)) {
        if ($display.IsEmbedded) { continue }
        if ([string]::IsNullOrWhiteSpace($display.Serial)) { continue }

        $safeSerial  = ($display.Serial -replace '[^A-Za-z0-9]', '_')
        $seenKey     = "DisplayUnmatchedSeenAt_$safeSerial"
        $notifiedKey = "DisplayUnmatchedNotified_$safeSerial"

        $liveRow = $null
        try {
            $uri = New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ client_id = $ClientId; asset_serial = $display.Serial })
            $resp = Invoke-ITFlowChecked GET $uri $null "Display asset lookup by serial"
            if ($resp -and "$($resp.success)" -eq "True" -and $resp.count -gt 0 -and $resp.data) {
                $sel = Select-ITFlowAssetRow -Rows $resp.data
                # Only a live row of type Display is a match; an archived row or a
                # live row of a different type is treated the same as "not found".
                if ($sel.Active -and ((Get-AssetProp $sel.Active "asset_type") -eq "Display")) {
                    $liveRow = $sel.Active
                }
            }
        } catch {
            Log "Display asset lookup failed for serial '$($display.Serial)': $($_.Exception.Message)"
            continue
        }

        if ($liveRow) {
            $vendor     = Get-DisplayVendorName $display.Manufacturer
            $localMake  = Normalize-Value $vendor
            $localModel = Normalize-Value $display.FriendlyName
            $itMake     = Get-AssetProp $liveRow "asset_make"
            $itModel    = Get-AssetProp $liveRow "asset_model"

            $update = [ordered]@{
                api_key   = $Config.ApiKey
                client_id = [int]$ClientId
                asset_id  = [int]$liveRow.asset_id
            }

            $update.asset_description = "Last Seen: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') By $HostHostname (Agent v$AgentVersion)"

            if ($localMake  -and ($itMake  -ne $localMake))  { $update.asset_make  = $vendor }
            if ($localModel -and ($itModel -ne $localModel)) { $update.asset_model = $display.FriendlyName }

            $localSpecs = Get-ITFlowDisplaySpecs -Display $display
            if ($localSpecs.Count -gt 0) {
                $remoteSpecs = ConvertTo-ITFlowSpecMap $liveRow
                if ($null -ne $remoteSpecs) {
                    $specDelta = Get-ITFlowAssetSpecsDelta -Local $localSpecs -Remote $remoteSpecs
                    if ($specDelta.Count -gt 0) { $update.asset_specs = $specDelta }
                }
            }

            try {
                $dresp = Invoke-ITFlow POST "$($Config.BaseUrl)/api/v1/assets/update.php" $update
                Write-ITFlowSpecsNotKept -Response $dresp -Action "Display asset update"
                $changedKeys = ($update.Keys | Where-Object { $_ -notin @('api_key','client_id','asset_id') }) -join ', '
                Log "Display asset updated (serial '$($display.Serial)', asset_id $($liveRow.asset_id)): $changedKeys"
            } catch {
                # Invoke-ITFlow (not -Checked): a 'no rows changed' success=False
                # answer is normal here, same reasoning as the host asset update.
                $err = $_.Exception.Message
                $null = Register-ITFlowFailure -Text $err -Action "Display asset update"
                Log "Display asset update API call failed (serial '$($display.Serial)'): $err"
            }

            # Re-arm unmatched-ticket dedup in case this serial goes unmatched again later.
            Set-CacheValue -Name $seenKey -Value ""
            Set-CacheValue -Name $notifiedKey -Value ""
            continue
        }

        # No live Display asset with this serial in this client.
        if (-not $TicketUnmatchedDisplays -or -not $TicketingEnabled) { continue }
        if ((Get-CacheValue -Name $notifiedKey -Default "") -eq "1") { continue }

        $firstSeen = Get-CacheValue -Name $seenKey -Default ""
        if ([string]::IsNullOrWhiteSpace($firstSeen)) {
            # Seen unmatched for the first time - don't ticket yet, so a monitor
            # that's only briefly connected (a dongle, a one-off demo) never raises
            # a ticket from a single sync.
            Set-CacheValue -Name $seenKey -Value (Get-Date).ToString("o")
            Log "Display serial '$($display.Serial)' has no matching ITFlow Display asset in this client - will ticket on a later sync if still unmatched"
            continue
        }

        $vendor = Get-DisplayVendorName $display.Manufacturer
        $specs  = Get-ITFlowDisplaySpecs -Display $display
        $displayPairs = [ordered]@{
            "Detected on host" = "$HostHostname (serial $HostSerial)"
            "Name"             = $display.FriendlyName
            "Make"             = $vendor
            "Serial"           = $display.Serial
            "Size"             = $(if ($specs.size_in) { "$($specs.size_in) in" } else { $null })
            "Resolution"       = $specs.resolution
        }
        $details = New-ITFlowTicketBody -Sections @(
            (New-ITFlowTicketParagraph "No ITFlow Display asset found with serial '$($display.Serial)' in this client."),
            (New-ITFlowTicketSection -Title "Unrecognised Display" -Icon "🖼️" -InnerHtml (New-ITFlowTicketKeyValueTable $displayPairs)),
            (New-ITFlowTicketParagraph "If this is an org-owned external monitor, label/create a Display asset with this serial so future syncs keep it updated.")
        )

        try {
            Create-ITFlowTicket -Title "Unrecognised external display on $HostHostname" -ClientId $ClientId -Details $details | Out-Null
            Log "Ticketed unmatched display serial '$($display.Serial)' (host $HostHostname)"
        } catch {
            Log "Create ticket for unmatched display failed (serial '$($display.Serial)'): $($_.Exception.Message)"
        }
        # One ticket ever per serial, regardless of which host sees it next.
        Set-CacheValue -Name $notifiedKey -Value "1"
    }
}

function Write-LocalSysInfoFromSnapshot {
    param(
        [Parameter(Mandatory=$true)] $Snapshot,
        [int]$Keep = 20
    )

    $hostname   = $env:COMPUTERNAME
    $root       = $script:SysInfoRoot
    $archiveDir = $script:SysInfoArchiveDir

    # Remediation E: never let a SYSTEM write follow a planted reparse point or
    # write into a non-admin-owned directory (arbitrary-overwrite-as-SYSTEM).
    if ($script:IsSystemContext -and -not (Test-SafeSystemDir -Path $root)) {
        Log "SECURITY: sysinfo root '$root' is a reparse point or not admin-owned - skipping local sysinfo write"
        return
    }

    if (-not (Test-Path $root))       { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $archiveDir)) { New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null }

    $currentFile = Join-Path $root "sysinfo_$hostname.json"
    $tmpFile     = "$currentFile.tmp"

    $stamp       = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $archiveFile = Join-Path $archiveDir "sysinfo_$hostname`_$stamp.json"

    $snapshotForJson = [ordered]@{}
    $Snapshot.Keys | Where-Object { $_ -notlike '_Cim*' } | ForEach-Object { $snapshotForJson[$_] = $Snapshot[$_] }
    $json = $snapshotForJson | ConvertTo-Json -Depth 12

    # Atomic write
    Set-Content -Path $tmpFile -Value $json -Encoding UTF8 -Force
    Move-Item -Path $tmpFile -Destination $currentFile -Force

    # Archive
    Copy-Item -Path $currentFile -Destination $archiveFile -Force

    # Retention (keep last N for hostname)
    Get-ChildItem -Path $archiveDir -Filter "sysinfo_$hostname`_*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep |
        ForEach-Object {
            try { Remove-Item -Path $_.FullName -Force -ErrorAction Stop } catch { }
        }

    Log "Local sysinfo written: $currentFile (archived: $archiveFile, keep=$Keep)"
}

# =====================================================
# ITFLOW API Functions
# =====================================================
# =====================================================
# ITFlow 26.08 API COMPATIBILITY
# ---------------------------------------------------------------------------
# 26.08 changed two things this agent depends on:
#
#   1. Every pre-existing API key was deleted by the update and had to be
#      reissued. A fleet upgraded past 26.08 therefore fails authentication on
#      every endpoint until each agent is given a new key. Without the helpers
#      below that surfaces as a generic "HTTP request failed", five pointless
#      30-second connectivity retries, and no indication of the real cause.
#   2. Keys are now owned by a user and inherit that user's role, module and
#      client permissions instead of carrying their own client scope. A key can
#      now silently see fewer clients than the administrator intended, which
#      matters because cross-client transfer detection reads by serial with no
#      client_id and treats an empty result as "this asset exists nowhere".
#
# Keys also carry an expiry date from 26.08, so authentication can start failing
# on a fleet that was working yesterday and was not touched.
# =====================================================

function Get-ITFlowHttpErrorDetail {
    # Pull the HTTP status code and response body out of a failed web request.
    # Windows PowerShell 5.1 throws a WebException carrying an HttpWebResponse
    # whose stream still holds the JSON error body; PowerShell 7 surfaces the same
    # body on $_.ErrorDetails.Message. ITFlow answers a rejected key with that body
    # ("Authentication failed. API key is invalid or has expired."), so it is the
    # only place the real reason can be read from.
    param($ErrorRecord)

    $detail = [pscustomobject]@{ StatusCode = 0; Body = "" }
    if (-not $ErrorRecord) { return $detail }

    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $detail.Body = [string]$ErrorRecord.ErrorDetails.Message
        }
    } catch { }

    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            try { $detail.StatusCode = [int]$resp.StatusCode } catch { }
            if ([string]::IsNullOrWhiteSpace($detail.Body)) {
                $stream = $null
                try { $stream = $resp.GetResponseStream() } catch { $stream = $null }
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try { $detail.Body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
        }
    } catch { }

    return $detail
}

function Test-IsAuthFailureText {
    # True when a message (exception text, or an ITFlow success=False message)
    # indicates the key itself was rejected rather than the request being wrong.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # A 403 is a permission-level denial for a key that DID authenticate; it is
    # classified separately (Get-ITFlowFailureKind) and must not read as a dead key.
    if ($Text -match '\(HTTP 403\)' -or $Text -match '\(403\)') { return $false }
    return (
        $Text -match 'Authentication failed' -or
        $Text -match 'API key is invalid' -or
        $Text -match 'invalid or has expired' -or
        $Text -match '\(401\)' -or
        $Text -match '(?i)\bunauthorized\b'
    )
}

function Set-ITFlowAuthFailure {
    # Record a rejected key once, loudly and in one place, so the log says what to
    # do about it instead of leaving a generic transport error behind.
    param([string]$Reason, [string]$Action = "API call")

    $script:AuthFailureReason = $Reason
    try {
        $script:LastRunState.AuthFailed        = $true
        $script:LastRunState.AuthFailureReason = $Reason
    } catch { }

    Log "AUTH FAILURE ($Action): $Reason"
    Log "AUTH: the ITFlow API rejected this key. ITFlow 26.08 deleted every key that existed before the update, and keys issued since carry an expiry date."
    Log "AUTH: issue a new key under Admin Settings > API Keys owned by a user holding asset read/write, contact read and ticket create on this client, then save it in the agent (GUI) or re-run the installer with the new key."
    try { Set-StateDword -Name 'LastAuthOK' -Value 0 } catch { }
}

function New-ITFlowReadUri {
    # Build a GET URI for an api/v1 read endpoint with every value URL-escaped.
    # Lookups match the WHOLE value, so a serial or hostname containing '&', '#',
    # '+' or a space that is sent raw gets cut short or rewritten, reads as "not
    # found", and the caller's next step is to create a duplicate asset.
    # Null/empty values are omitted rather than sent as empty filters.
    param(
        [Parameter(Mandatory=$true)][string]$Endpoint,
        $Query = $null
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("api_key=" + [System.Uri]::EscapeDataString([string]$Config.ApiKey)) | Out-Null
    if ($Query) {
        foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($null -eq $v) { continue }
            $sv = [string]$v
            if ($sv -eq "") { continue }
            $parts.Add(([System.Uri]::EscapeDataString([string]$k) + "=" + [System.Uri]::EscapeDataString($sv))) | Out-Null
        }
    }
    return "$($Config.BaseUrl)/api/v1/$($Endpoint)?" + ($parts -join '&')
}

function Get-ITFlowFailureKind {
    # Classify a failure message from Invoke-ITFlow / Invoke-ITFlowChecked using the
    # status codes the API reference documents: 400 missing parameters, 401 missing/
    # invalid/expired key, 403 permission denied, 405 wrong method, 500 server error.
    # Invoke-ITFlow appends " (HTTP NNN)" to what it throws; a success=False body
    # (HTTP 200) carries no code, so text is the fallback.
    # Returns: Auth | Permission | BadRequest | Method | Server | Transport | None
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "None" }

    $code = 0
    if ($Text -match '\(HTTP (\d{3})\)') { $code = [int]$Matches[1] }
    elseif ($Text -match 'error: \((\d{3})\)') { $code = [int]$Matches[1] }

    if ($code -eq 401) { return "Auth" }
    if ($code -eq 403) { return "Permission" }
    if ($code -eq 400) { return "BadRequest" }
    if ($code -eq 405) { return "Method" }
    if ($code -ge 500 -and $code -le 599) { return "Server" }

    if (Test-IsAuthFailureText $Text) { return "Auth" }
    if ($Text -match '(?i)permission denied|insufficient permission|not have permission|\bforbidden\b|This needs (Read|Modify|Full) on ') { return "Permission" }
    if ($code -gt 0) { return "Transport" }
    if ($Text -match '(?i)HTTP request failed|timed out|unable to connect|could not be resolved|underlying connection') { return "Transport" }
    return "None"
}

function Get-ITFlowPermissionHint {
    # Which module/level the key's user needs for a given agent action, per the
    # API reference: reads need Read, create/update need Modify. Assets and tickets
    # are the Support module; clients and contacts are the Clients module.
    param([string]$Action)
    $a = "$Action"
    $level = "Read"
    if ($a -match '(?i)create|update|assign') { $level = "Modify" }
    $module = "Support"
    if ($a -match '(?i)contact|client|key scope') { $module = "Clients" }
    return "$module module, $level level"
}

function Set-ITFlowPermissionFailure {
    # The key authenticated but its user's role lacks the module level the call
    # needs. Unlike an auth failure, other calls in the same run may still work,
    # so this records and explains rather than aborting.
    param([string]$Reason, [string]$Action = "API call")

    $script:PermissionFailureReason = $Reason
    try {
        $script:LastRunState.PermissionDenied = $true
        $script:LastRunState.PermissionReason = "${Action}: $Reason"
    } catch { }

    Log "PERMISSION DENIED ($Action): $Reason"
    # ITFlow 26.11 states exactly what is missing: "This needs Modify on Support -
    # the key's user, Tess Tech (Technician), has Read." Older servers say only
    # "does not have permission", so fall back to the agent's own mapping.
    if ($Reason -match "This needs (Read|Modify|Full) on (.+?) - the key's user, (.+?), has (\w+)") {
        Log "PERMISSION: grant $($Matches[3]) $($Matches[1]) on $($Matches[2]) (has $($Matches[4])) under Admin > Roles - the key itself is valid, no new key is needed."
    } else {
        Log "PERMISSION: the key is valid but its user's role does not allow this call. Grant that user at least the $(Get-ITFlowPermissionHint $Action) (Admin > Roles) for this client."
    }
}

function Register-ITFlowFailure {
    # Single place that turns a failure message into the right loud log line.
    # Returns the failure kind so callers can decide whether retrying is useful.
    param([string]$Text, [string]$Action = "API call")

    $kind = Get-ITFlowFailureKind $Text
    switch ($kind) {
        "Auth"       { $null = Set-ITFlowAuthFailure -Reason $Text -Action $Action }
        "Permission" { $null = Set-ITFlowPermissionFailure -Reason $Text -Action $Action }
        "BadRequest" { Log "API REQUEST REJECTED ($Action, HTTP 400 missing/invalid parameters): $Text" }
        "Method"     { Log "API METHOD REJECTED ($Action, HTTP 405): $Text - the endpoint does not accept this HTTP method on this ITFlow version." }
        default      { }
    }
    return $kind
}

function Get-ITFlowKeyScope {
    # 26.08 made keys user-owned, and nothing in the API reports the resulting
    # scope, so it is inferred from what clients/read.php will hand back. The
    # answer decides whether an empty cross-client serial lookup can be trusted as
    # proof that an asset exists nowhere else: with a key that can only see one
    # client, it cannot, and treating it as proof re-creates the asset locally.
    param([int]$ConfiguredClientId)

    $scope = [pscustomobject]@{
        ClientsReadable    = $false
        ClientsVisible     = 0
        SeesConfigured     = $false
        CrossClientVisible = $false
        Detail             = ""
    }

    try {
        $resp = Invoke-ITFlow GET (New-ITFlowReadUri -Endpoint 'clients/read.php' -Query ([ordered]@{ limit = 100 }))
        if ($resp -and "$($resp.success)" -eq "True" -and $resp.data) {
            $rows = @($resp.data)
            $scope.ClientsReadable = $true
            $scope.ClientsVisible  = $rows.Count
            foreach ($c in $rows) {
                $cid = try { [int](Normalize-Value $c.client_id) } catch { 0 }
                if ($cid -eq $ConfiguredClientId) { $scope.SeesConfigured = $true }
            }
            # More than one visible client is the only positive evidence available
            # that this key is not pinned to a single client.
            $scope.CrossClientVisible = ($rows.Count -gt 1)
            $scope.Detail = "clients visible=$($rows.Count); configured client $ConfiguredClientId visible=$($scope.SeesConfigured)"
        } else {
            $msg = if ($resp -and $resp.message) { $resp.message } else { "no data returned" }
            $scope.Detail = "clients/read returned nothing usable ($msg)"
            $null = Register-ITFlowFailure -Text $msg -Action "Key scope probe"
        }
    } catch {
        $err = $_.Exception.Message
        $scope.Detail = "clients/read unavailable ($err)"
        $null = Register-ITFlowFailure -Text $err -Action "Key scope probe"
    }

    return $scope
}

function Write-ITFlowKeyScopeLog {
    param($Scope)
    if (-not $Scope) { return }

    if ($Scope.ClientsReadable) {
        Log "API key scope: $($Scope.Detail)"
        if (-not $Scope.SeesConfigured) {
            Log "API key scope WARNING: the configured client is not in this key's visible client list. Asset sync will fail until the key's user is granted access to that client."
        }
        if (-not $Scope.CrossClientVisible) {
            Log "API key scope NOTE: this key can see a single client, so cross-client transfer detection is degraded - an asset moved to a client this key cannot see reads as absent and will be re-created here."
        }
    } else {
        Log "API key scope: undetermined ($($Scope.Detail)). The key's user may lack Clients module read; transfer detection cannot be verified this run."
    }
}

function Write-TransferLookupScopeCaveat {
    # Called when a cross-client lookup by serial came back empty. Before 26.08 an
    # all-clients key made that conclusive. Now the key sees only its user's
    # clients, so "found nowhere" may mean "found nowhere I am allowed to look" -
    # and the caller's next move is to create the asset, i.e. a duplicate.
    param([string]$Serial)

    if ($script:ApiKeyScope -and $script:ApiKeyScope.CrossClientVisible) { return }

    $seen = if ($script:ApiKeyScope -and $script:ApiKeyScope.ClientsReadable) {
        "$($script:ApiKeyScope.ClientsVisible) client(s)"
    } else {
        "an undetermined set of clients"
    }
    Log "TRANSFER_LOOKUP_INCONCLUSIVE serial='$Serial' - this key can see $seen, so 'not found in any client' only rules out the clients it is permitted to read. If the asset was moved to a client outside that scope, enrolling now creates a duplicate. Widen the key user's client access to restore full transfer detection."
}

function Test-ITFlowApiCapabilities {
    # Preflight used by the GUI Test API button. Since 26.08 a key inherits its
    # user's module permissions, so "the key works" is no longer one question -
    # asset sync, contact assignment and ticketing can each be permitted or not
    # independently. Probes only reads; ticket create is reported as untested
    # because testing it would raise a real ticket.
    param([int]$ConfiguredClientId)

    $results = New-Object System.Collections.Generic.List[object]
    $probes = @(
        @{ Name = "Assets read (required)";   Uri = (New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ client_id = $ConfiguredClientId; limit = 1 })) },
        @{ Name = "Contacts read (contact assignment)"; Uri = (New-ITFlowReadUri -Endpoint 'contacts/read.php' -Query ([ordered]@{ client_id = $ConfiguredClientId; limit = 1 })) },
        @{ Name = "Clients read (transfer detection)";  Uri = (New-ITFlowReadUri -Endpoint 'clients/read.php' -Query ([ordered]@{ limit = 1 })) }
    )

    $authFailed = $false
    foreach ($probe in $probes) {
        $entry = [pscustomobject]@{ Name = $probe.Name; Ok = $false; Note = "" }
        try {
            $resp = Invoke-ITFlow GET $probe.Uri
            if ($resp -and "$($resp.success)" -eq "True") {
                $entry.Ok = $true
                $entry.Note = "count=$($resp.count)"
            } else {
                $msg = if ($resp -and $resp.message) { $resp.message } else { "success=False" }
                # "No resource" means permitted but empty - that is a pass for a probe.
                if ($msg -match 'No resource') {
                    $entry.Ok = $true
                    $entry.Note = "permitted (no rows)"
                } else {
                    $kind = Get-ITFlowFailureKind $msg
                    if ($kind -eq "Auth") { $authFailed = $true }
                    if ($kind -eq "Permission") { $entry.Note = "permission denied (403): $msg" } else { $entry.Note = $msg }
                }
            }
        } catch {
            $err = $_.Exception.Message
            $kind = Get-ITFlowFailureKind $err
            if ($kind -eq "Auth") { $authFailed = $true }
            if ($kind -eq "Permission") { $entry.Note = "permission denied (403): $err" } else { $entry.Note = $err }
        }
        $results.Add($entry) | Out-Null
    }

    return [pscustomobject]@{
        AuthFailed = $authFailed
        Probes     = $results
    }
}

function Invoke-ITFlow {
    param($Method, $Uri, $Body = $null)

    try {
        if ($Body) {
            # PS 5.1 encodes a string -Body as Latin-1 unless the ContentType
            # charset says otherwise, corrupting any non-Latin-1 character
            # (emoji, accents) into literal '?' bytes. Encode explicitly.
            $json = $Body | ConvertTo-Json -Depth 6
            $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri `
                -Body $jsonBytes `
                -ContentType "application/json; charset=utf-8" `
                -TimeoutSec 90 `
                -ErrorAction Stop
        } else {
            Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri `
                -TimeoutSec 90 `
                -ErrorAction Stop
        }
    } catch {
        # Carry the HTTP status and response body into the message. A rejected key
        # returns 401 with the reason in the body; without this the caller only
        # ever sees "The remote server returned an error: (401) Unauthorized."
        $detail = Get-ITFlowHttpErrorDetail $_
        $suffix = ""
        if ($detail.StatusCode) { $suffix += " (HTTP $($detail.StatusCode))" }
        if (-not [string]::IsNullOrWhiteSpace($detail.Body)) {
            $short = ($detail.Body -replace '\s+', ' ').Trim()
            if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '...' }
            $suffix += " body: $short"
        }
        throw "HTTP request failed: $($_.Exception.Message)$suffix"
    }
}

function Invoke-ITFlowChecked {
    param(
        [string]$Method,
        [string]$Uri,
        $Body = $null,
        [string]$Action = "API call"
    )

    Log "Calling ITFlow API: $Action"

    # Cancellation checkpoints around REST calls (best practice)
    Throw-IfCancelRequested
    try {
        $resp = Invoke-ITFlow $Method $Uri $Body
    } catch {
        $err = $_.Exception.Message
        # Separate "the key was rejected" (401) and "the key's user lacks the
        # module level" (403) from every other transport failure. Neither is fixed
        # by retrying; each is fixed by a different change in ITFlow.
        $null = Register-ITFlowFailure -Text $err -Action $Action
        Log "ITFlow API threw exception ($Action): $err"
        throw "ITFlow API call threw ($Action): $err"
    }
    Throw-IfCancelRequested

    if (-not $resp) {
        Log "ITFlow API returned null response ($Action)"
        throw "ITFlow API returned null ($Action)"
    }

    if ("$($resp.success)" -ne "True") {
        $msg = if ($resp.message) { $resp.message } else { "success=false, no message" }

        # Treat "No resource" (not found) as an empty result, not a failure
        if ($msg -match 'No resource') {
            Log "ITFlow API: resource not found ($Action) - treating as empty result"
            return [pscustomobject]@{ success = "True"; count = 0; data = @(); message = $msg }
        }

        # A rejected key or permission denial can also arrive as HTTP 200 with success=False.
        $null = Register-ITFlowFailure -Text $msg -Action $Action

        Log "ITFlow API returned failure ($Action): $msg"
        throw "ITFlow API failed ($Action): $msg"
    }
    Log "ITFlow API success: $Action (count=$($resp.count))"
    return $resp
}


# =====================================================
# Ticket Body HTML Helpers
# Every ticket's -Details is built from these, so every ticket the agent
# raises gets the same card/table look instead of a wall of escaped plain
# text. Every helper emits only inline style="..." attributes (no <style>
# blocks, no external resources) since the body is rendered standalone.
# =====================================================

$script:TicketAccentColor = "#6c3ce9"

function Protect-ITFlowHtml {
    # Null/blank-safe HTML encoding for one dynamic value. The table helpers
    # below call this on every cell so call sites never hand-escape anything.
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($text)
}

function New-ITFlowTicketKeyValueTable {
    # Renders an ordered set of label/value pairs as a compact two-column
    # table. Blank/null values are skipped so a row never renders empty.
    param([System.Collections.Specialized.OrderedDictionary]$Pairs)

    $rows = New-Object System.Text.StringBuilder
    $any = $false
    foreach ($label in $Pairs.Keys) {
        $value = $Pairs[$label]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $any = $true
        $null = $rows.Append("<tr>")
        $null = $rows.Append("<td style=`"padding:3px 14px 3px 0;color:#6b7280;font-size:13px;white-space:nowrap;vertical-align:top;`">$(Protect-ITFlowHtml $label)</td>")
        $null = $rows.Append("<td style=`"padding:3px 0;color:#1f2937;font-size:13px;`">$(Protect-ITFlowHtml $value)</td>")
        $null = $rows.Append("</tr>")
    }
    if (-not $any) { return "" }
    return "<table style=`"border-collapse:collapse;margin:0;`">$($rows.ToString())</table>"
}

function New-ITFlowTicketListTable {
    # Renders a list of same-shaped rows (one per disk/display/adapter, etc.)
    # as a table with a header row. Each entry in $Rows is an array of cell
    # values in the same order as $Columns.
    param(
        [string[]]$Columns,
        [object[]]$Rows
    )

    if (-not $Rows -or $Rows.Count -eq 0) { return "" }

    $headerCells = ($Columns | ForEach-Object {
        "<th style=`"text-align:left;padding:5px 14px 5px 0;border-bottom:2px solid $($script:TicketAccentColor);color:#1f2937;font-size:12px;text-transform:uppercase;letter-spacing:.03em;white-space:nowrap;`">$(Protect-ITFlowHtml $_)</th>"
    }) -join ""

    $bodyRows = New-Object System.Text.StringBuilder
    foreach ($row in $Rows) {
        $null = $bodyRows.Append("<tr>")
        foreach ($cell in $row) {
            $null = $bodyRows.Append("<td style=`"padding:4px 14px 4px 0;border-bottom:1px solid #eee;color:#1f2937;font-size:13px;white-space:nowrap;`">$(Protect-ITFlowHtml $cell)</td>")
        }
        $null = $bodyRows.Append("</tr>")
    }

    return "<table style=`"border-collapse:collapse;margin:0;`"><thead><tr>$headerCells</tr></thead><tbody>$($bodyRows.ToString())</tbody></table>"
}

function New-ITFlowTicketParagraph {
    # One free-text lead-in line (e.g. an explanation sentence), encoded.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return "<p style=`"margin:0 0 10px 0;font-size:13px;color:#1f2937;line-height:1.5;`">$(Protect-ITFlowHtml $Text)</p>"
}

function New-ITFlowTicketSection {
    # Wraps inner HTML (from the helpers above) as one titled card: a small
    # icon + heading with a purple underline, consistent spacing so sections
    # stack cleanly. Returns "" (nothing rendered) when there's no content.
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$Icon = "",
        [Parameter(Mandatory=$true)][string]$InnerHtml
    )

    if ([string]::IsNullOrWhiteSpace($InnerHtml)) { return "" }

    $iconPrefix = if ($Icon) { "$Icon " } else { "" }
    return "<div style=`"margin:0 0 18px 0;`"><div style=`"font-size:13px;font-weight:600;color:#1f2937;letter-spacing:.03em;text-transform:uppercase;border-bottom:2px solid $($script:TicketAccentColor);padding-bottom:5px;margin-bottom:8px;`">$iconPrefix$(Protect-ITFlowHtml $Title)</div>$InnerHtml</div>"
}

function New-ITFlowDeviceReportBanner {
    # A quiet divider (muted grey, thin rule, small caps) - deliberately NOT
    # styled like New-ITFlowTicketSection's purple-underlined cards, so the
    # device spec that follows reads as reference/footer material rather than
    # another primary section competing with the ticket's actual purpose.
    return "<div style=`"margin:26px 0 14px 0;padding-top:12px;border-top:1px solid #e5e7eb;`"><div style=`"font-size:11px;font-weight:600;color:#9ca3af;letter-spacing:.08em;text-transform:uppercase;`">📋 Device Report</div></div>"
}

function New-ITFlowTicketBody {
    # Wraps one or more section/paragraph HTML blocks (already built by the
    # helpers above) in the outer container shared by every ticket type.
    # -DeviceSpec is optional: when given, it's appended after a de-emphasized
    # banner so it reads as footer material below the ticket's own purpose.
    param([string[]]$Sections, [string]$DeviceSpec = "")

    $inner = ($Sections | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ""
    if (-not [string]::IsNullOrWhiteSpace($DeviceSpec)) {
        $inner += (New-ITFlowDeviceReportBanner) + $DeviceSpec
    }
    return "<div style=`"font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:640px;`">$inner</div>"
}

function ConvertFrom-ITFlowHtmlToPlainText {
    # The device spec is HTML (for tickets); AD's Notes field needs readable
    # plain text. Turns row/list boundaries into line breaks, strips the rest
    # of the markup, and decodes entities.
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $text = $Html -replace '(?i)<tr[^>]*>', "`r`n" -replace '(?i)<li[^>]*>', "`r`n - " -replace '(?i)<[^>]+>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $lines = ($text -split "`r`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    return ($lines -join "`r`n").Trim()
}

# =====================================================
# Ticket Creation Function
# =====================================================

function Create-ITFlowTicket {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][int]$ClientId,

        # Optional: pass explicit asset id if you already have it
        [Nullable[int]]$AssetId = $null,

        # Optional: pass serial to resolve asset id if needed
        [string]$Serial = $null,

        # Optional: ticket body text (ticket_details)
        [string]$Details = ""
    )

    # Base payload. ticket_priority is stated explicitly: 26.09 changed the default
    # for tickets that omit it, so leaving it out makes the priority of agent tickets
    # depend on the server version.
    $payload = @{
        api_key         = $Config.ApiKey
        client_id       = $ClientId
        ticket_subject  = $Title
        ticket_priority = $(if ([string]::IsNullOrWhiteSpace($TicketPriority)) { "Low" } else { $TicketPriority })
    }

    # Include ticket_details when provided. $Details is always pre-built HTML
    # from the ticket body helpers above (New-ITFlowTicketBody etc.), which
    # already HTML-encode every dynamic value they embed - so it's sent as-is.
    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $payload.ticket_details = $Details
    }

    # Determine best asset_id to attach (in order of preference)
    $resolvedAssetId = $null

    if ($AssetId.HasValue -and $AssetId.Value -gt 0) {
        $resolvedAssetId = [int]$AssetId.Value
    }
    elseif ($script:CurrentAssetId -and [int]$script:CurrentAssetId -gt 0) {
        $resolvedAssetId = [int]$script:CurrentAssetId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Serial)) {
        $resolvedAssetId = Resolve-AssetIdBySerial -Serial $Serial -ClientId $ClientId
    }

    # Attach ticket_asset_id when known (new ITFlow feature)
    if ($resolvedAssetId -and $resolvedAssetId -gt 0) {
        $payload.ticket_asset_id = $resolvedAssetId
    }

    try {
        $response = Invoke-ITFlowChecked POST "$($Config.BaseUrl)/api/v1/tickets/create.php" $payload "Ticket create"
        Log "Ticket created successfully: $Title (ticket_asset_id=$resolvedAssetId)"
        return $response
    }
    catch {
        # Backward compatibility: if ticket_asset_id isn't supported yet, retry without it.
        if ($payload.ContainsKey("ticket_asset_id")) {
            $err = $_.Exception.Message
            Log "Ticket create failed with ticket_asset_id (likely unsupported on this ITFlow version). Error: $err"
            Log "Retrying ticket create without ticket_asset_id..."

            try {
                $payload.Remove("ticket_asset_id")
                $response2 = Invoke-ITFlowChecked POST "$($Config.BaseUrl)/api/v1/tickets/create.php" $payload "Ticket create (fallback)"
                Log "Ticket created successfully (fallback, no asset link): $Title"
                return $response2
            }
            catch {
                Log "ERROR: Ticket creation failed even after fallback: $Title | $($_.Exception.Message)"
                return $null
            }
        }

        Log "ERROR: Ticket creation exception: $Title | $($_.Exception.Message)"
        return $null
    }
}

# =====================================================
# Local Agent Cache (delegates to structured Cache subkey)
# Stores last-sent MAC/IP locally to avoid constant updates while still writing on all updates.
# =====================================================

function Get-AgentCacheValue {
    param([string]$Name, [string]$Default = "")
    Get-CacheValue -Name $Name -Default $Default
}

function Set-AgentCacheValue {
    param([string]$Name, [string]$Value)
    Set-CacheValue -Name $Name -Value $Value
}

# =====================================================
# Rename state helpers (available before Run-AssetSync)
# =====================================================

function Test-PendingComputerRename {
    try {
        $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName' -ErrorAction Stop).ComputerName
        $pending = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName' -ErrorAction Stop).ComputerName
        if ($active -ne $pending) { return $pending }
    } catch {}
    return $null
}

function Get-QueuedRenameTarget {
    try {
        $req = Get-StateDword -Name 'LastRenameRequired' -Default 0
        $tgt = Get-StateString -Name 'LastTargetHostname' -Default ''
        if ($req -eq 1 -and -not [string]::IsNullOrWhiteSpace($tgt)) { return $tgt }
    } catch { }
    return $null
}

function Clear-QueuedRename {
    try {
        Set-StateDword -Name 'LastRenameRequired' -Value 0
        Set-StateString -Name 'LastTargetHostname' -Value ''
    } catch { }
    try {
        $script:LastRunState.RenameRequired = $false
        $script:LastRunState.TargetHostname = ''
    } catch { }
}

function Test-InteractiveUserPresent {
    # True if someone is logged on at the console. Used to keep the unattended
    # auto-rename from firing (and force-rebooting) while a user is working.
    # Console session is the right signal for 1:1 workstations (RDS is out of scope).
    try {
        $u = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if (-not [string]::IsNullOrWhiteSpace($u)) { return $true }
    } catch {
        # WMI unavailable: fall through. Fail SAFE (assume present) so we never
        # force-reboot a machine we can't inspect.
        return $true
    }
    return $false
}

function Invoke-HostnameRenameSafe {
    param(
        [Parameter(Mandatory=$true)][string]$DesiredHostname,
        [switch]$Force,
        [string]$Serial = ""
    )

    if (-not $Serial) {
        try { $Serial = $script:LastRunState.Serial } catch { $Serial = "" }
    }

    Log "Rename requested: current='$env:COMPUTERNAME' target='$DesiredHostname' Force=$($Force.IsPresent)"
    try {
        if ($Force) {
            Rename-Computer -NewName $DesiredHostname -Force -Restart:$false -ErrorAction Stop
        } else {
            Rename-Computer -NewName $DesiredHostname -Restart:$false -ErrorAction Stop
        }
        Log "Rename-Computer succeeded (no reboot triggered)"
        Clear-QueuedRename
        return $true
    } catch {
        Log "Rename-Computer failed: $($_.Exception.Message)"
        # Fallback to netdom if Rename-Computer fails with credential/auth errors
        $credErr = $_.Exception.Message -match 'user name or password|access denied|credentials'
        if ($credErr -and (Get-Command netdom -ErrorAction SilentlyContinue)) {
            Log "Trying netdom fallback..."
            try {
                $null = netdom renamecomputer $env:COMPUTERNAME /NewName:$DesiredHostname /Force /Reboot:0 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Log "netdom rename succeeded (no reboot triggered)"
                    Clear-QueuedRename
                    return $true
                }
                Log "netdom failed with exit code $LASTEXITCODE"
            } catch {
                Log "netdom fallback also failed: $($_.Exception.Message)"
            }
        }
        # Always set the failure flag to prevent re-attempting (portable-mode safe)
        Set-TicketFlag "RenameFailed_$DesiredHostname" | Out-Null
        if ($EnableRenameFailureTicketing) {
            $renameFailFlag = "RenameFailed_$DesiredHostname"
            if (-not (Test-TicketFlag $renameFailFlag)) {
                $ticketTitle = "[RENAME FAILED] $($env:COMPUTERNAME) -> $DesiredHostname | Serial: $Serial | Error: $($_.Exception.Message)"
                try { $assetIdForTicket = $script:CurrentAssetId } catch { $assetIdForTicket = $null }
                $ticketClientId = if ($Config.ClientId) { [int]$Config.ClientId } else { 0 }
                $renamePairs = [ordered]@{
                    "Current Hostname" = $env:COMPUTERNAME
                    "Desired Hostname" = $DesiredHostname
                    "Serial"           = $Serial
                    "Error"            = $_.Exception.Message
                }
                $renameDetails = New-ITFlowTicketBody -Sections @(
                    (New-ITFlowTicketSection -Title "Rename Failed" -Icon "⚠️" -InnerHtml (New-ITFlowTicketKeyValueTable $renamePairs))
                )
                Create-ITFlowTicket -Title $ticketTitle -ClientId $ticketClientId -AssetId $assetIdForTicket -Details $renameDetails | Out-Null
                Set-TicketFlag $renameFailFlag | Out-Null
            }
        }
        return $false
    }
}

# =====================================================
# Asset Enrollment (separate from sync to keep flow clean)
# =====================================================
function Start-AssetEnrollment {
    param(
        [pscustomobject]$Inv,
        [string]$DetectedAssetType,
        [int]$EffectiveClientId,

        # Enrollment ticket body (built from full snapshot in Run-AssetSync)
        [string]$Details = "",

        # Device specification block (appended to transfer tickets for forensic record)
        [string]$DeviceSpec = "",

        # Recursion depth guard — prevents infinite re-entry when API persistently rejects creation
        [int]$Depth = 0
    )

    if ($Depth -ge 1) {
        Log "Enrollment recursion limit reached — giving up (serial='$($Inv.Serial)')"
        $script:LastSyncOK = $false
        return
    }

    Log "Enrollment (create): no existing asset found for serial '$($Inv.Serial)' - creating new asset in client_id=$EffectiveClientId"
    Log ("Enrollment (create): payload name='{0}' type='{1}' make='{2}' model='{3}' os='{4}' ip='{5}' mac='{6}' status='{7}'" -f $Inv.Hostname,$DetectedAssetType,$Inv.Make,$Inv.Model,$Inv.OS,$Inv.IP,$Inv.MAC,$DefaultAssetStatus)

    $createBody = @{
        api_key      = $Config.ApiKey
        client_id    = [int]$EffectiveClientId
        asset_name   = $Inv.Hostname
        # Same check-in line the update path writes, so a new asset shows it from the first run
        asset_description = "Last Check-In: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (Agent v$AgentVersion)"
        asset_serial = $Inv.Serial
        asset_make   = $Inv.Make
        asset_model  = $Inv.Model
        asset_os     = $Inv.OS
        asset_mac    = $Inv.MAC
        asset_ip     = $Inv.IP
        asset_type   = $DetectedAssetType
        asset_status = $DefaultAssetStatus
    }
    # A server without asset_specs ignores the unknown field.
    if ($script:LocalAssetSpecs -and $script:LocalAssetSpecs.Count -gt 0) {
        $createBody.asset_specs = $script:LocalAssetSpecs
    }

    try {
        $result = Invoke-ITFlowChecked POST "$($Config.BaseUrl)/api/v1/assets/create.php" $createBody "Asset create"
        Write-ITFlowSpecsNotKept -Response $result -Action "Asset create"
    } catch {
        Log "Asset create failed, checking for existing serial in other clients..."
        try {
            $globalLookup = Invoke-ITFlowChecked GET (New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ asset_serial = $Inv.Serial })) $null "Transfer lookup by serial"
            $globalSel = $null
            if ("$($globalLookup.success)" -eq "True" -and ($globalLookup.data -and $globalLookup.data.Count -gt 0)) {
                $globalSel = Select-ITFlowAssetRow -Rows $globalLookup.data
                if (-not $globalSel.Active) {
                    Invoke-ArchivedAssetNotice -Inv $Inv -TicketClientId ([int]$EffectiveClientId) -ArchivedRow $globalSel.Archived[0] -FlagName "TransferTargetArchived" -LogTag "TRANSFER_TARGET_ARCHIVED" -DeviceSpec $DeviceSpec
                    $script:LastSyncOK = $false
                    return
                }
            }
            if ($globalSel -and $globalSel.Active) {
                $moved = $globalSel.Active
                $discoveredClientId = try { [int](Normalize-Value $moved.asset_client_id) } catch { 0 }
                $discoveredAssetId  = try { [int](Normalize-Value $moved.asset_id) } catch { 0 }
                $followResult = Invoke-AssetTransferFollow -Inv $Inv -DiscoveredClientId $discoveredClientId -DiscoveredAssetId $discoveredAssetId -DeviceSpec $DeviceSpec
                if ($followResult.Followed) {
                    $EffectiveClientId = $followResult.DiscoveredClientId
                    $result = [pscustomobject]@{ success = "True"; data = @(@{ insert_id = $followResult.DiscoveredAssetId }) }
                } else {
                    $script:LastSyncOK = $false
                    return
                }
            } else {
                Write-TransferLookupScopeCaveat -Serial $Inv.Serial
                Log "Serial '$($Inv.Serial)' not found in any client. Proceeding with enrollment."
                Start-AssetEnrollment -Inv $inv -DetectedAssetType $DetectedAssetType -EffectiveClientId $EffectiveClientId -Details $Details -DeviceSpec $DeviceSpec -Depth ($Depth + 1)
            }
        } catch {
            Log "Transfer lookup failed: serial not found in any client"
            $script:LastSyncOK = $false
            return
        }
    }

    # Process the result
    $assetId = $null
    if ($result.data -and $result.data.Count -gt 0 -and $result.data[0].insert_id) {
        $assetId = $result.data[0].insert_id
        Log "Asset created (insert_id=$assetId)"
    } else {
        Log "Asset created (insert_id not returned by API)"
    }
    if ($assetId) {
        $script:CurrentAssetId = [int]$assetId
        Log "CurrentAssetId set (created): $script:CurrentAssetId"
    }

    # Enrollment ticket
    if ((($Silent -and $EnableTicketingSilent) -or (-not $Silent -and $EnableTicketingGui))) {
        if (-not (Test-TicketFlag "Enrollment")) {
            $ticketTitle = "[ENROLL] $($Inv.Hostname) | Serial: $($Inv.Serial) | $($Inv.OS)"
            Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -Serial $Inv.Serial -Details $Details | Out-Null
            Set-TicketFlag "Enrollment" | Out-Null
        } else {
            Log "Enrollment ticket already created - skipping"
        }
    } else {
        Log "Enrollment ticketing disabled for this run - skipping"
    }
}

# =====================================================
# Function Run-AssetSync
# =====================================================
function Run-AssetSync {
        param([bool]$AllowSilentRename = $false)


        # Reset per-run guard (prevents duplicate compare logging)
$script:LoggedLocalVsITFlow = $false
$script:SetAssetNameOnce = $false
        # Reset per run to prevent GUI session bleed
        # --- Cancellation checkpoint (Added) ---
        Throw-IfCancelRequested

    # =============================
    # 1) Interrogate Machine (once)
    # =============================
    $snapshot = Get-FullSnapshot -AgentVersion $AgentVersion

    # Build device specification block for tickets (preserved when asset is archived/deleted).
    # Rendered as HTML cards/tables (New-ITFlowTicketSection etc.) rather than
    # plain text, since Create-ITFlowTicket no longer re-escapes -Details itself.
    $deviceSections = New-Object System.Collections.Generic.List[string]

    if ($snapshot.CPU) {
        $cpuPairs = [ordered]@{
            "Name"    = $snapshot.CPU.Name
            "Cores"   = "$($snapshot.CPU.CoreCount) / $($snapshot.CPU.LogicalCount)"
            "Max MHz" = $snapshot.CPU.MaxClockMHz
        }
        $deviceSections.Add((New-ITFlowTicketSection -Title "CPU" -Icon "🖥️" -InnerHtml (New-ITFlowTicketKeyValueTable $cpuPairs)))
    }

    if ($snapshot.Memory -and $snapshot.Memory.TotalGB) {
        $memPairs = [ordered]@{ "Total GB" = $snapshot.Memory.TotalGB }
        $deviceSections.Add((New-ITFlowTicketSection -Title "Memory" -Icon "🧠" -InnerHtml (New-ITFlowTicketKeyValueTable $memPairs)))
    }

    if ($snapshot.Storage -and $snapshot.Storage.Totals) {
        $storagePairs = [ordered]@{
            "Physical" = "$($snapshot.Storage.Totals.PhysicalTotalGB) GB"
            "Volumes"  = "$($snapshot.Storage.Totals.VolumeTotalGB) GB"
        }
        $storageHtml = New-ITFlowTicketKeyValueTable $storagePairs
        if ($snapshot.Storage.PhysicalDisks -and $snapshot.Storage.PhysicalDisks.Count -gt 0) {
            $diskRows = New-Object System.Collections.Generic.List[object]
            foreach ($disk in $snapshot.Storage.PhysicalDisks) {
                $diskRows.Add(@(
                    $disk.Model,
                    $(if ($disk.Serial) { $disk.Serial } else { "" }),
                    "$([math]::Round($disk.SizeBytes / 1GB, 2)) GB",
                    $disk.MediaType,
                    $(if ($disk.HealthStatus) { $disk.HealthStatus } else { "" })
                ))
            }
            $storageHtml += New-ITFlowTicketListTable -Columns @("Model", "Serial", "Size", "Media", "Health") -Rows $diskRows
        }
        $deviceSections.Add((New-ITFlowTicketSection -Title "Storage" -Icon "💾" -InnerHtml $storageHtml))
    }

    if ($snapshot.Displays -and $snapshot.Displays.Count -gt 0) {
        $displayRows = New-Object System.Collections.Generic.List[object]
        foreach ($display in $snapshot.Displays) {
            $displayRows.Add(@(
                $(if ($display.FriendlyName) { $display.FriendlyName } else { "" }),
                $(if ($display.Manufacturer) { Get-DisplayVendorName $display.Manufacturer } else { "" }),
                $(if ($display.ProductCode) { $display.ProductCode } else { "" }),
                $(if ($display.Serial) { $display.Serial } else { "" }),
                $(if ($display.SizeInches) { "$($display.SizeInches) in" } else { "" }),
                $(if ($display.NativeResolution) { "$($display.NativeResolution.Width) x $($display.NativeResolution.Height)" } else { "" })
            ))
        }
        $displayHtml = New-ITFlowTicketListTable -Columns @("Name", "Make", "Product Code", "Serial", "Size", "Resolution") -Rows $displayRows
        $deviceSections.Add((New-ITFlowTicketSection -Title "Displays" -Icon "🖼️" -InnerHtml $displayHtml))
    }

    if ($snapshot.Network -and $snapshot.Network.Adapters) {
        $netRows = New-Object System.Collections.Generic.List[object]
        foreach ($adapter in $snapshot.Network.Adapters) {
            $adapterLabel = $adapter.Name
            if ($adapter.InterfaceDescription -and $adapter.InterfaceDescription -ne $adapter.Name) {
                $adapterLabel = "$($adapter.Name) ($($adapter.InterfaceDescription))"
            }
            $ipParts = New-Object System.Collections.Generic.List[string]
            if ($adapter.Ips -and $adapter.Ips.Count -gt 0) {
                foreach ($ip in $adapter.Ips) {
                    $part = "$($ip.IPAddress)/$($ip.PrefixLength) ($($ip.AddressFamily))"
                    if ($ip.DefaultGateway) { $part += ", gw $($ip.DefaultGateway)" }
                    $ipParts.Add($part)
                }
            }
            $netRows.Add(@(
                $adapterLabel,
                $adapter.MacAddress,
                $adapter.Status,
                $(if ($adapter.LinkSpeed) { $adapter.LinkSpeed } else { "" }),
                ($ipParts -join "; ")
            ))
        }
        $netHtml = New-ITFlowTicketListTable -Columns @("Adapter", "MAC", "Status", "Speed", "IP(s)") -Rows $netRows
        $deviceSections.Add((New-ITFlowTicketSection -Title "Network" -Icon "🌐" -InnerHtml $netHtml))
    }

    # Left un-wrapped (just the concatenated section cards, not a full
    # New-ITFlowTicketBody): every call site below combines this with its own
    # header section(s) and wraps the result once via New-ITFlowTicketBody.
    $DeviceSpec = ($deviceSections | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ""

    # Keep existing variables for minimal downstream code changes
    $inv = [pscustomobject]@{
        Serial   = $snapshot.Device.Serial
        Hostname = $snapshot.Device.Hostname
        Make     = $snapshot.Device.Make
        Model    = $snapshot.Device.Model
        OS       = $snapshot.Device.OS
        MAC      = $snapshot.Device.PrimaryMAC
        IP       = $snapshot.Device.PrimaryIP
    }

    Log "Serial: $($inv.Serial)"
    Log "Hostname: $($inv.Hostname)"
    Log "MAC: $($inv.MAC)"
    Log "IP: $($inv.IP)"

    # Snapshot-first AssetType, fallback to recompute if missing/blank
    $DetectedAssetType = $snapshot.Device.AssetType
    if ([string]::IsNullOrWhiteSpace($DetectedAssetType)) {
        $DetectedAssetType = Get-AssetType -ComputerSystem $snapshot._CimComputerSystem -OperatingSystem $snapshot._CimOperatingSystem
        $snapshot.Device.AssetType = $DetectedAssetType
    }
    Log "Detected Asset Type: $DetectedAssetType"
    if ($script:LastChassisInfo) { Log-Debug "Asset type detail: $DetectedAssetType ($($script:LastChassisInfo))" }

    # asset_specs for this run (empty when disabled or the type has no keys we fill)
    $script:LocalAssetSpecs = [ordered]@{}
    $script:AssetSpecsUnsupportedLogged = $false
    if ($PushAssetSpecs) {
        try {
            $script:LocalAssetSpecs = Get-ITFlowAssetSpecs -Snapshot $snapshot -AssetType $DetectedAssetType
        } catch {
            Log "asset_specs collection failed (non-fatal): $($_.Exception.Message)"
            $script:LocalAssetSpecs = [ordered]@{}
        }
        if ($script:LocalAssetSpecs.Count -gt 0) {
            Log ("Local asset_specs: " + (($script:LocalAssetSpecs.Keys | ForEach-Object { "$_='$($script:LocalAssetSpecs[$_])'" }) -join ' '))
        } else {
            Log "Local asset_specs: none for type '$DetectedAssetType'"
        }
    } else {
        Log "asset_specs push disabled (PushAssetSpecs=0)"
    }

    # Effective client_id for this run (may change if asset was transferred)
    $EffectiveClientId = if ($Config.ClientId) { [int]$Config.ClientId } else { 0 }


    # Reset per-run UI state (ALWAYS do this once per run)
    $script:LastRunState.TransferFollowed     = $false
    $script:LastRunState.ClientIdAutoUpdated  = $false
    $script:LastRunState.AssetArchived        = $false


    # =============================
    # 2) Write sysinfo snapshot file
    # =============================
    if ($EnableLocalSysInfo) {
        try {
            Write-LocalSysInfoFromSnapshot -Snapshot $snapshot -Keep $SysInfoKeep
        } catch {
            Log "Local sysinfo write failed: $($_.Exception.Message)"
        }
    }

    # --- Cancellation checkpoint (Added) ---
    Throw-IfCancelRequested



    # =============================
    # 3) Sync to ITFlow (existing logic continues below)
    # =============================

        # Connectivity probe
        $maxAttempts  = 5
        $sleepSeconds = 30
        $attempt      = 1
        $connected    = $false
        $startTime    = Get-Date

        Log "Starting ITFlow connectivity check (max $maxAttempts attempts, $sleepSeconds sec interval)"

        while ($attempt -le $maxAttempts) {
            Throw-IfCancelRequested
            try {
                Log "Connectivity attempt ${attempt} of ${maxAttempts}"
                Invoke-ITFlowChecked GET (New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ limit = 1 })) $null "Connectivity probe" | Out-Null
                $connected = $true
                $elapsed = (Get-Date) - $startTime
                Log "ITFlow reachable after ${attempt} attempt(s) (elapsed: $([int]$elapsed.TotalSeconds)s)"
                break
            }
            catch {
                Throw-IfCancelRequested
                $probeErr = $_.Exception.Message
                Log "ITFlow not reachable on attempt ${attempt}: $probeErr"
                # ITFlow 26.08: a deleted or expired key is rejected identically on
                # every attempt. Retrying for two and a half minutes cannot fix it and
                # only delays the log line that says what actually needs doing.
                # Likewise 403 (permission), 400 (bad parameters) and 405 (wrong
                # method) are deterministic answers from a reachable server. Only
                # transport errors and 5xx are worth waiting out.
                $probeKind = Get-ITFlowFailureKind $probeErr
                if ($probeKind -eq "Auth") {
                    Log "Aborting connectivity retries: the server is reachable but rejected the API key, which retrying cannot resolve."
                    break
                }
                if ($probeKind -eq "Permission" -or $probeKind -eq "BadRequest" -or $probeKind -eq "Method") {
                    Log "Aborting connectivity retries: the server is reachable and answered '$probeKind', which retrying cannot resolve."
                    break
                }
                if ($attempt -lt $maxAttempts) {
                    Log "Retrying in ${sleepSeconds} seconds..."
                    Start-SleepCancelAware -Seconds $sleepSeconds
                }
                $attempt++
            }
        }

        if (-not $connected) {
            $elapsed = (Get-Date) - $startTime
            if ($script:AuthFailureReason) {
                Log "Aborting sync after $([int]$elapsed.TotalSeconds)s - ITFlow rejected the API key. See the AUTH lines above."
            } elseif ($script:PermissionFailureReason) {
                Log "Aborting sync after $([int]$elapsed.TotalSeconds)s - the API key's user lacks permission to read assets. See the PERMISSION lines above."
            } else {
                Log "ITFlow unavailable after ${maxAttempts} attempts (elapsed: $([int]$elapsed.TotalSeconds)s) - aborting sync"
            }
            $script:LastSyncOK = $false
            return
        }

        Log "Connectivity check passed, starting asset sync"

        # ITFlow 26.08: establish what this user-owned key can actually see before
        # anything relies on a cross-client lookup being authoritative.
        if ($null -eq $script:ApiKeyScope) {
            $script:ApiKeyScope = Get-ITFlowKeyScope -ConfiguredClientId ([int]$EffectiveClientId)
            Write-ITFlowKeyScopeLog $script:ApiKeyScope
            try { $script:LastRunState.KeyScope = $script:ApiKeyScope.Detail } catch { }
        }

        # Lookup asset by serial in the configured client
        $lookup = Invoke-ITFlowChecked GET (New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ client_id = $EffectiveClientId; asset_serial = $inv.Serial })) $null "Asset lookup by serial+client"

        Log "Asset lookup returned data count: $(if ($null -ne $lookup.data) { $lookup.data.Count } else { 'null' })"

        # Archived rows come back too (oldest asset_id first). Use the live asset.
        # If this client only has archived ones, that is what an ITFlow Transfer to
        # Client leaves behind (it copies the asset to the new client and archives
        # the original), so run transfer detection - but never enrol a duplicate.
        $archivedInClient = $null
        if ("$($lookup.success)" -eq "True" -and $lookup.data -and @($lookup.data).Count -gt 0) {
            $lookupSel = Select-ITFlowAssetRow -Rows $lookup.data
            if ($lookupSel.Active) {
                if ($lookupSel.Archived.Count -gt 0) {
                    Log "Asset lookup: using active asset_id=$($lookupSel.Active.asset_id); ignoring $($lookupSel.Archived.Count) archived record(s) with the same serial"
                }
                [object[]]$activeRows = @($lookupSel.Active)
                $lookup = [pscustomobject]@{ success = "True"; count = 1; data = $activeRows }
                Clear-TicketFlag "AssetArchived"
                Clear-TicketFlag "TransferOutOfScope"
            } else {
                $archivedInClient = $lookupSel.Archived[0]
                Log "Asset lookup: only archived record(s) in client $EffectiveClientId (asset_id=$($archivedInClient.asset_id)) - checking whether it was transferred"
                [object[]]$noRows = @()
                $lookup = [pscustomobject]@{ success = "True"; count = 0; data = $noRows }
            }
        }

        # Loop allows one re-entry after transfer follow so rename+update happen in the same sync
        $retrySyncAfterTransfer = $false
        $lastCheckIn = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        do {
        if ("$($lookup.success)" -eq "True" -and ($lookup.data -and $lookup.data.Count -gt 0)) {
            $asset = $lookup.data[0]

            $script:CurrentAssetId = [int]$asset.asset_id
            # ---- Update LastRunState for UI ----
                $script:LastRunState.RanAt             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                $script:LastRunState.Hostname          = $inv.Hostname
                $script:LastRunState.Serial            = $inv.Serial
                $script:LastRunState.DetectedType      = $DetectedAssetType
                $script:LastRunState.PrimaryIP         = $inv.IP
                $script:LastRunState.PrimaryMAC        = $inv.MAC
                $script:LastRunState.ConfigClientId    = $Config.ClientId
                $script:LastRunState.EffectiveClientId = $EffectiveClientId.ToString()
                $script:LastRunState.AssetId           = $script:CurrentAssetId.ToString()
                $script:LastRunState.SysInfoPath       = "C:\ProgramData\ITFlow\sysinfo_$($env:COMPUTERNAME).json"

                # Pull sysinfo timestamp if present
                try {
                    $raw = Get-Content -Path $script:LastRunState.SysInfoPath -Raw -ErrorAction Stop
                    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($obj -and $obj.Meta -and $obj.Meta.CollectedAt) {
                        $script:LastRunState.SysInfoCollectedAt = $obj.Meta.CollectedAt
                    }
                } catch {}

                # Persist a couple of "last run" UI values in HKLM so the GUI can show them even before running
                Set-StateString -Name "LastRunAt" -Value $script:LastRunState.RanAt
                Set-StateString -Name "LastEffectiveClientId" -Value $script:LastRunState.EffectiveClientId
                Set-StateString -Name "LastAssetId" -Value $script:LastRunState.AssetId

            Log "CurrentAssetId set: $script:CurrentAssetId"


                Log "Asset lookup succeeded, asset_id=$script:CurrentAssetId"

                $cid = Get-AssetProp $asset "asset_client_id"
            # ALWAYS-ON verbose comparison (like original .0015)
            try {
                Log-LocalVsITFlowVerbose -Inv $inv -DetectedAssetType $DetectedAssetType -Asset $asset -EffectiveClientId $EffectiveClientId
            } catch {
                Log "WARN: Verbose compare logging failed: $($_.Exception.Message)"
            }
            # Hostname sync (Hostname = ITFlow Asset Name)
            if (-not [string]::IsNullOrWhiteSpace($asset.asset_name)) {

                $DesiredHostname = $asset.asset_name.ToUpper() -replace '[^A-Z0-9\-]', ''
                if ($DesiredHostname.Length -gt 15) { $DesiredHostname = $DesiredHostname.Substring(0, 15) }

                $renameFlag = "RenameInitiated_$DesiredHostname"

                if ($env:COMPUTERNAME -eq $DesiredHostname) {
                    Clear-TicketFlag $renameFlag
                    Clear-TicketFlag "RenameInitiated"

                    # Auto-clear any previous conflict/failure flags for this desired hostname
                    Clear-RenameFlags -DesiredHostname $DesiredHostname
                    }

                if ($env:COMPUTERNAME -ne $DesiredHostname) {

                    Log "Hostname mismatch: $($env:COMPUTERNAME) -> $DesiredHostname"

                    $adCleanupLog = ""

                    Set-StateDword -Name 'LastRenameRequired' -Value 1
                    Set-StateString -Name 'LastTargetHostname' -Value $DesiredHostname
                    # -----------------------------------------
                    # Rename Preflight Checks (ITFlow + AD)
                    # -----------------------------------------
                    $renameConflictFlag = "RenameConflict_$DesiredHostname"

                    # Auto-clear previous RenameFailed flag for this target (conditions may have changed since last attempt)
                    $renameRetryCount = [int](Get-AgentCacheValue -Name "RenameRetry_$DesiredHostname" -Default 0)
                    if ($renameRetryCount -ge 3) {
                        Log "Rename retry limit reached for '$DesiredHostname' ($renameRetryCount attempts) - giving up"
                    } elseif (Test-TicketFlag "RenameFailed_$DesiredHostname") {
                        $renameRetryCount++
                        Set-AgentCacheValue -Name "RenameRetry_$DesiredHostname" -Value $renameRetryCount
                        Log "Auto-clearing previous RenameFailed flag for '$DesiredHostname' (re-attempting, attempt $renameRetryCount)"
                        Clear-TicketFlag "RenameFailed_$DesiredHostname"
                    }

                    # 1) ITFlow duplicate-name guard
                    $dup_check_serial = $snapshot.Device.Serial
                    if ($EnableRenamePreflightITFlowDupCheck) {
                        $dup = Test-ITFlowDuplicateAssetName -DesiredHostname $DesiredHostname -EffectiveClientId $EffectiveClientId -CurrentAssetId ([int]$asset.asset_id)
                        if ($dup.IsDuplicate) {
                            $serialMatch = ($dup.OtherAssetSerials | Where-Object { $_ -eq $dup_check_serial }) -ne $null
                            if ($serialMatch) {
                                Log "ITFlow duplicate asset_name='$DesiredHostname' found but serial matches ($dup_check_serial) - reimage scenario, proceeding with rename"
                            } else {
                                $otherIdsStr = $dup.OtherAssetIds -join ', '
                                Log "RENAME BLOCKED: ITFlow duplicate asset_name='$DesiredHostname' found. Other asset_ids: $otherIdsStr. Serials do not match local device serial ($dup_check_serial)"

                                Clear-QueuedRename

                                if (-not (Test-TicketFlag $renameConflictFlag)) {
                                    $currentAssetId = $asset.asset_id
                                    $currentSerial = $inv.Serial
                                    $currentHostname = $env:COMPUTERNAME
                                    $ticketTitle = "[RENAME CONFLICT] Duplicate ITFlow asset_name '$DesiredHostname' detected. Current asset_id=$currentAssetId. Others: $otherIdsStr | Serial: $currentSerial"
                                    $conflictPairs = [ordered]@{
                                        "Current Hostname"       = $currentHostname
                                        "Desired Hostname"       = $DesiredHostname
                                        "Serial"                 = $currentSerial
                                        "Current Asset ID"       = $currentAssetId
                                        "Conflicting Asset IDs"  = $otherIdsStr
                                    }
                                    $detailStr = New-ITFlowTicketBody -Sections @(
                                        (New-ITFlowTicketSection -Title "Rename Conflict" -Icon "⚠️" -InnerHtml (New-ITFlowTicketKeyValueTable $conflictPairs))
                                    )
                                    Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$currentAssetId) -Details $detailStr | Out-Null
                                    Set-TicketFlag $renameConflictFlag | Out-Null
                                } else {
                                    Log "Rename conflict ticket already raised for '$DesiredHostname' - skipping"
                                }

                                $script:LastSyncOK = $false
                                return
                            }
                        }
                    }

                    # 2) AD name-exists guard (domain joined)
                    if ($EnableRenamePreflightADCheck) {
                        $ad = Test-ADComputerNameExists -DesiredHostname $DesiredHostname
                        if ($ad.IsDomainJoined -and $ad.Exists) {
                            if ($ad.ExistingSerial -and $ad.ExistingSerial -eq $dup_check_serial) {
                                Log "AD computer account already exists for '$DesiredHostname' but serial matches ($dup_check_serial) - reimage scenario, attempting cleanup"
                                try {
                                    $dnParts = $ad.ExistingDN -split ','
                                    $cn = $dnParts[0] -replace '^CN='
                                    $parentDN = ($dnParts[1..($dnParts.Length - 1)] -join ',')
                                    $parent = [ADSI]"LDAP://$parentDN"
                                    $parent.Delete("computer", "CN=$cn")
                                    $adCleanupLog = "Old AD account '$($ad.ExistingDN)' deleted"
                                    Log "AD old computer account deleted: $($ad.ExistingDN)"
                                } catch {
                                    Log "AD old computer account delete failed (non-fatal): $($_.Exception.Message)"
                                    try {
                                        $oldComputer = [ADSI]"LDAP://$($ad.ExistingDN)"
                                        $oldComputer.Put("userAccountControl", 4096)
                                        $oldComputer.SetInfo()
                                        $adCleanupLog = "Old AD account '$($ad.ExistingDN)' disabled (delete not permitted)"
                                        Log "AD old computer account disabled: $($ad.ExistingDN)"
                                    } catch {
                                        $adCleanupLog = "Old AD account '$($ad.ExistingDN)' could not be cleaned up - manual intervention required"
                                        Log "AD old computer account cleanup failed entirely: $($_.Exception.Message)"
                                    }
                                }
                            } else {
                                $adDN = $ad.ExistingDN
                                $adSerial = $ad.ExistingSerial
                                Log "RENAME BLOCKED: AD computer account already exists for '$DesiredHostname' (DN='$adDN'). AD serial='$adSerial' does not match local device serial ($dup_check_serial)"

                                Clear-QueuedRename

                                if (-not (Test-TicketFlag $renameConflictFlag)) {
                                    $currentHostname = $env:COMPUTERNAME
                                    $currentSerial = $inv.Serial
                                    $currentAssetId = $asset.asset_id
                                    $ticketTitle = "[RENAME CONFLICT] AD computer account already exists for '$DesiredHostname'. Rename blocked. DN='$adDN' | Serial: $currentSerial"
                                    $conflictPairs = [ordered]@{
                                        "Current Hostname" = $currentHostname
                                        "Desired Hostname" = $DesiredHostname
                                        "Serial"           = $currentSerial
                                        "Current Asset ID" = $currentAssetId
                                        "AD DN"            = $adDN
                                    }
                                    $detailStr = New-ITFlowTicketBody -Sections @(
                                        (New-ITFlowTicketSection -Title "Rename Conflict" -Icon "⚠️" -InnerHtml (New-ITFlowTicketKeyValueTable $conflictPairs))
                                    )
                                    Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$currentAssetId) -Details $detailStr | Out-Null
                                    Set-TicketFlag $renameConflictFlag | Out-Null
                                } else {
                                    Log "Rename conflict ticket already raised for '$DesiredHostname' - skipping"
                                }

                                $script:LastSyncOK = $false
                                return
                            }
                        }
                    }


                    # If we reached here, preflight checks did not block rename.
                    # Auto-clear previous conflict flag if conditions are now OK.
                    if (Test-TicketFlag $renameConflictFlag) {
                    # Only clear if AD check didn't fail (avoid clearing when AD status is unknown)
                    if (-not ($ad -and $ad.PSObject.Properties.Name -contains "ADCheckFailed" -and $ad.ADCheckFailed)) {
                        Clear-TicketFlag $renameConflictFlag
                            Log "Auto-cleared rename conflict flag for '$DesiredHostname' (preflight OK)."
                        } else {
                            Log "AD check unavailable; leaving rename conflict flag intact for '$DesiredHostname'."
                        }
                    }

                    $currentHostname = $env:COMPUTERNAME
                    $currentSerial = $inv.Serial
                    $currentAssetId = $asset.asset_id
                    if ($AllowUserInteraction) {
        # UI prompts MUST occur after sync completes (UI thread).
        Log "Interactive context: queuing hostname rename to '$DesiredHostname' for post-sync prompt."
        $script:LastRunState.RenameRequired = $true
        $script:LastRunState.TargetHostname = $DesiredHostname
        Set-StateDword -Name "LastRenameRequired" -Value 1
        Set-StateString -Name "LastTargetHostname" -Value $DesiredHostname
        if ($EnableTicketingGui) {
            if (-not (Test-TicketFlag $renameFlag)) {
                $ticketTitle = "[RENAME] $currentHostname -> $DesiredHostname | Serial: $currentSerial"
                $renamePairs = [ordered]@{
                    "Current Hostname" = $currentHostname
                    "Desired Hostname" = $DesiredHostname
                    "Serial"           = $currentSerial
                    "Mode"             = "GUI"
                    "AD Cleanup"       = $adCleanupLog
                }
                $detailStr = New-ITFlowTicketBody -Sections @(
                    (New-ITFlowTicketSection -Title "Rename Queued" -Icon "✏️" -InnerHtml (New-ITFlowTicketKeyValueTable $renamePairs))
                )
                Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$currentAssetId) -Details $detailStr | Out-Null
                Set-TicketFlag $renameFlag | Out-Null
            } else {
                Log "Rename ticket already raised for '$DesiredHostname' - skipping"
            }
        } else {
            Log "Rename ticketing disabled in GUI - skipping"
        }
    }
    else {
        if ($IsHeadlessExecution -and $AllowSilentRename) {
            # Domain membership decides whether a signed-in user blocks the rename.
            # The "no interactive user" rule protects the AD trust window (AD object
            # renamed, local name waiting on a reboot). A workgroup or Entra-only
            # machine has no on-prem AD object, so there is no window to protect -
            # and a single passwordless account is signed in automatically at boot,
            # so on those machines a user-free window never comes. Unknown = domain
            # (the safe path).
            $isDomainJoined = $true
            try {
                $csRename = $snapshot._CimComputerSystem
                if ($null -eq $csRename) { $csRename = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
                if ($null -ne $csRename -and $null -ne $csRename.PartOfDomain) { $isDomainJoined = [bool]$csRename.PartOfDomain }
            } catch { $isDomainJoined = $true }

            $pending = Test-PendingComputerRename
            if ($pending) {
                if ($Reboot -and -not (Test-InteractiveUserPresent)) {
                    # A previous run renamed the AD object but the completing reboot
                    # never happened (cancelled/blocked). That is the trust window.
                    # Self-heal: force the restart now while no user is present.
                    Log "Reboot-pending rename to '$pending' found with no interactive user - forcing restart to complete it"
                    shutdown.exe /r /t 15 /c "This PC is being renamed by IT and will restart shortly to finish. Please save any work."
                } elseif (-not $isDomainJoined) {
                    Log "Rename to '$pending' is pending; it applies at the next restart."
                } else {
                    Log "Headless rename skipped: reboot-pending rename to '$pending' already exists"
                }
            } else {
                if ($EnableTicketingSilent) {
                    if (-not (Test-TicketFlag $renameFlag)) {
                        $ticketTitle = "[RENAME] $currentHostname -> $DesiredHostname | Serial: $currentSerial"
                        $renamePairs = [ordered]@{
                            "Current Hostname" = $currentHostname
                            "Desired Hostname" = $DesiredHostname
                            "Serial"           = $currentSerial
                            "Mode"             = "Headless"
                            "AD Cleanup"       = $adCleanupLog
                        }
                        $detailStr = New-ITFlowTicketBody -Sections @(
                            (New-ITFlowTicketSection -Title "Rename Queued" -Icon "✏️" -InnerHtml (New-ITFlowTicketKeyValueTable $renamePairs))
                        )
                        Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -Serial $inv.Serial -Details $detailStr | Out-Null
                        Set-TicketFlag $renameFlag | Out-Null
                    } else {
                        Log "Rename ticket already raised for '$DesiredHostname' - skipping"
                    }
                } else {
                    Log "Rename ticketing disabled in silent mode - skipping"
                }
                if ($renameRetryCount -ge 3) {
                    Log "Rename skipped for '$DesiredHostname' ($renameRetryCount previous failures)"
                } elseif ($Reboot -and (Test-InteractiveUserPresent) -and -not $isDomainJoined) {
                    # Workgroup / Entra-only machine with a signed-in user: rename now,
                    # no forced restart. The new name applies at the next natural
                    # reboot; the GUI shows "Rename pending - reboot required" meanwhile.
                    Log "Workgroup machine with a signed-in user: renaming to '$DesiredHostname' now; it takes effect at the next restart (no AD object, so no trust window to protect)."
                    $ok = Invoke-HostnameRenameSafe -DesiredHostname $DesiredHostname -Force
                    if ($ok) {
                        Clear-QueuedRename
                        Set-AgentCacheValue -Name "RenameRetry_$DesiredHostname" -Value 0
                        $script:LastRunState.RenameRequired = $false
                        $script:LastRunState.TargetHostname = $DesiredHostname
                        Log "Rename to '$DesiredHostname' staged - no restart forced; it completes when the user next restarts."
                    }
                } elseif ($Reboot -and (Test-InteractiveUserPresent)) {
                    # Unattended auto-rename mode, but a user is at the console.
                    # Renaming the AD object now and deferring the reboot is exactly
                    # the domain-trust window we are trying to close, so DON'T rename.
                    # Keep it queued; the next startup (before logon) applies it.
                    Log "Auto-rename to '$DesiredHostname' deferred: interactive user present. Queued for the next startup (no-user) window."
                    $script:LastRunState.RenameRequired = $true
                    $script:LastRunState.TargetHostname = $DesiredHostname
                    Set-StateDword -Name "LastRenameRequired" -Value 1
                    Set-StateString -Name "LastTargetHostname" -Value $DesiredHostname
                } else {
                    $ok = Invoke-HostnameRenameSafe -DesiredHostname $DesiredHostname -Force
                    if ($ok) {
                        Clear-QueuedRename
                        Set-AgentCacheValue -Name "RenameRetry_$DesiredHostname" -Value 0
                        if ($Reboot) {
                            # Rename + reboot are kept atomic: force the restart now
                            # (no interactive user present) so the local name catches
                            # up to the AD object immediately.
                            Log "Auto-reboot after rename (no interactive user) - restarting in 15 seconds"
                            shutdown.exe /r /t 15 /c "This PC is being renamed by IT and will restart shortly to finish. Please save any work."
                        }
                    }
                }
            }
        } else {
            Log "Non-interactive context - hostname rename queued for GUI"
            $script:LastRunState.RenameRequired = $true
            $script:LastRunState.TargetHostname = $DesiredHostname
            Set-StateDword -Name "LastRenameRequired" -Value 1
            Set-StateString -Name "LastTargetHostname" -Value $DesiredHostname
        }
    }
    }
            else {
                # Set asset_name once if blank (do not rename computer based on blank)
                Log "Asset name empty in ITFlow - setting it to local hostname once"
                $script:SetAssetNameOnce = $true
            }

            # =============================
            # ENFORCEMENT UPDATE (local truth)
            # =============================
            $update = @{
                api_key   = $Config.ApiKey
                client_id = [int]$EffectiveClientId
                asset_id  = [int]$asset.asset_id
            }

            $update.asset_description = "Last Check-In: $lastCheckIn (Agent v$AgentVersion)"

            # Local normalized values
            $localStatus = Normalize-Value $DefaultAssetStatus
            $localType   = Normalize-Value $DetectedAssetType
            $localOS     = Normalize-Value $inv.OS
            $localMake   = Normalize-Value $inv.Make
            $localModel  = Normalize-Value $inv.Model

            # ITFlow values (verifiable via read payload)
            $itStatus = Get-AssetProp $asset "asset_status"
            $itType   = Get-AssetProp $asset "asset_type"
            $itOS     = Get-AssetProp $asset "asset_os"
            $itMake   = Get-AssetProp $asset "asset_make"
            $itModel  = Get-AssetProp $asset "asset_model"

            # Enforce local truth for verifiable fields
            if ($itStatus -ne $localStatus) { $update.asset_status = $DefaultAssetStatus }
            if ($itType   -ne $localType)   { $update.asset_type   = $DetectedAssetType }
            if ($itOS     -ne $localOS)     { $update.asset_os     = $inv.OS }
            if ($localMake  -and ($itMake  -ne $localMake))  { $update.asset_make  = $inv.Make }
            if ($localModel -and ($itModel -ne $localModel)) { $update.asset_model = $inv.Model }

            # Set asset_name once if blank (in-memory flag, not persisted — the
            # blank/non-blank state of ITFlow's asset_name itself drives retry)
            if ($script:SetAssetNameOnce) { $update.asset_name = $inv.Hostname; $script:SetAssetNameOnce = $false }

            # asset_specs: compared against what the read returned, and only the
            # differing keys sent (the server overlays them). A read row with no
            # asset_specs property means the server predates specs - skip.
            if ($script:LocalAssetSpecs -and $script:LocalAssetSpecs.Count -gt 0) {
                $remoteSpecs = ConvertTo-ITFlowSpecMap $asset
                if ($null -eq $remoteSpecs) {
                    if (-not $script:AssetSpecsUnsupportedLogged) {
                        Log "asset_specs: not present in this server's asset read - skipping (ITFlow version without asset details)"
                        $script:AssetSpecsUnsupportedLogged = $true
                    }
                } else {
                    $specDelta = Get-ITFlowAssetSpecsDelta -Local $script:LocalAssetSpecs -Remote $remoteSpecs
                    if ($specDelta.Count -gt 0) {
                        $update.asset_specs = $specDelta
                        Log ("asset_specs changed: " + (($specDelta.Keys | ForEach-Object { "$_ '$($remoteSpecs[$_])' -> '$($specDelta[$_])'" }) -join '; '))
                    }
                }
            }

            # ===== MAC/IP WRITE-ONLY =====
            # - Do NOT read/compare from ITFlow: a filtered assets/read (by serial, name
            #   or id) does not join the primary interface, so interface_mac/ip are absent
            #   from the row this compares against (ITFlow 26.11 api/v1/assets/read.php).
            # - Track last-sent values locally; include MAC/IP on any update.
            $localMac = Normalize-Value $inv.MAC
            $localIp  = Normalize-Value $inv.IP

            $lastMac = Get-AgentCacheValue -Name "LastSentMAC" -Default ""
            $lastIp  = Get-AgentCacheValue -Name "LastSentIP"  -Default ""

            $macChanged = ($localMac -and ($localMac -ne $lastMac))
            $ipChanged  = ($localIp  -and ($localIp  -ne $lastIp))

            # Include MAC/IP if they changed OR if any other field triggers an update
            $otherChanges = ($update.Count -gt 3)
            if ($macChanged -or $ipChanged -or $otherChanges) {
                if ($localMac) { $update.asset_mac = $inv.MAC }
                if ($localIp)  { $update.asset_ip  = $inv.IP  }
            }

            if ($update.Count -gt 3) {
                try {
                    $resp = Invoke-ITFlow POST "$($Config.BaseUrl)/api/v1/assets/update.php" $update
                } catch {
                    # Invoke-ITFlow (not -Checked) because success=False 'no rows
                    # changed' is a normal answer here, but a thrown 401/403 still
                    # needs to be named as a key or permission problem.
                    $err = $_.Exception.Message
                    $null = Register-ITFlowFailure -Text $err -Action "Asset update"
                    Log "Asset update API call failed: $err"
                    $resp = $null
                }
                if ($resp) {
                Log ("Asset update API response: " + ($resp | ConvertTo-Json -Depth 4 -Compress))
                Write-ITFlowSpecsNotKept -Response $resp -Action "Asset update"
                }

                if ($resp -and "$($resp.success)" -eq "True") {
                    $changed = $update.Keys | Where-Object { $_ -notin @('api_key','asset_id','client_id') }
                    Log ("Asset updated fields: " + ($changed -join ', '))

                    # Update local cache only after success
                    if ($localMac) { Set-AgentCacheValue -Name "LastSentMAC" -Value $localMac }
                    if ($localIp)  { Set-AgentCacheValue -Name "LastSentIP"  -Value $localIp  }
                }
                else {
                    $msg = if ($resp -and $resp.message) { $resp.message } else { "" }
                    if ($msg -match 'no rows changed') {
                        Log "Asset already up to date (server returned 'no rows changed')."
                    } elseif ($msg) {
                        $null = Register-ITFlowFailure -Text $msg -Action "Asset update"
                        Log "Asset update failed: $msg"
                    }
                }
            }
        }

        # ===== Dynamic Contact Assignment =====
        if ($AssignContactFromLogons) {
            $allowedDomains = @()
            $rawDomains = @()
            if ($AssignContactAllowedDomain) {
                $rawDomains = $AssignContactAllowedDomain -split ','
            } else {
                try {
                    $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop
                    if ($cs.PartOfDomain) {
                        $rawDomains += $cs.Domain
                        Log "Allowed domain auto-detected: $($cs.Domain)"
                    }
                } catch {
                    Log "WARN: Could not detect domain membership: $($_.Exception.Message)"
                }
                $rawDomains += 'AzureAD'
            }
            foreach ($d in $rawDomains) {
                $d = $d.Trim()
                if ($d) {
                    $allowedDomains += $d
                    $short = ($d -split '\.')[0]
                    if ($short -and $short -ne $d) { $allowedDomains += $short }
                }
            }
            $allowedDomains = $allowedDomains | Select-Object -Unique
            Log "Allowed domains for logon filtering: $($allowedDomains -join ', ')"
            $durations = Get-UserLogonDurations -LookbackDays $AssignContactLookbackDays -AllowedDomains $allowedDomains -HalfLifeDays $AssignContactHalfLifeDays
            Log-Debug "RESULT: count=$(@($durations).Count)"
            if ($durations -and $durations.Count -gt 0) {
                $topUser = $durations[0]

                # Hysteresis: don't reassign on a transient logon. Keep the current
                # primary user unless the new leader clears the incumbent's *current*
                # weighted score by a margin. If the incumbent no longer appears
                # (device genuinely handed over), switch immediately.
                $marginFactor = 1.25
                $lastPrimaryUser = Get-AgentCacheValue -Name "PrimaryUser" -Default ""
                $effectiveUser = $topUser
                if ($lastPrimaryUser -and $lastPrimaryUser -ne $topUser.UserName) {
                    $incumbent = $durations | Where-Object { $_.UserName -eq $lastPrimaryUser } | Select-Object -First 1
                    if ($incumbent) {
                        if ($topUser.WeightedMinutes -lt ($incumbent.WeightedMinutes * $marginFactor)) {
                            Log "Primary-user change held by hysteresis: $($topUser.UserName) ($($topUser.WeightedMinutes)m) has not cleared $marginFactor x incumbent $lastPrimaryUser ($($incumbent.WeightedMinutes)m)"
                            $effectiveUser = $incumbent
                        } else {
                            Log "Primary user changing: $lastPrimaryUser -> $($topUser.UserName) (cleared ${marginFactor}x margin)"
                        }
                    } else {
                        Log "Previous primary user $lastPrimaryUser no longer active; switching to $($topUser.UserName)"
                    }
                }
                Set-AgentCacheValue -Name "PrimaryUser" -Value $effectiveUser.UserName
                Log "Primary user by weighted logon time: $($effectiveUser.DomainName)\$($effectiveUser.UserName) (weighted $($effectiveUser.WeightedMinutes)m / raw $($effectiveUser.TotalMinutes)m)"

                # AD userPrincipalName/mail are matched first inside Get-ITFlowContactByUser;
                # this constructed domain is only the fallback when AD is unreachable.
                $emailDomain = ($allowedDomains | Where-Object { $_ -like '*.*' } | Select-Object -First 1)
                if (-not $emailDomain) { $emailDomain = $effectiveUser.DomainName }
                Log "Contact lookup for $($effectiveUser.UserName) (AD UPN/mail preferred; fallback domain: $emailDomain)"
                $contactId = Get-ITFlowContactByUser -UserName $effectiveUser.UserName -DomainName $emailDomain -ClientId $EffectiveClientId
                $lastAssignedContactId = Get-AgentCacheValue -Name "LastAssignedContactId" -Default ""

                # Stable dedup key for the "contact missing" ticket: one per asset + primary user.
                $userKey = ($effectiveUser.UserName.ToLower() -replace '[^a-z0-9]', '')
                if ($userKey.Length -gt 40) { $userKey = $userKey.Substring(0, 40) }
                $missingContactFlag = "ContactMissing_$($asset.asset_id)_$userKey"

                if ($contactId -and "$contactId" -ne "$lastAssignedContactId") {
                    $assignResult = Set-ITFlowAssetContact -AssetId $asset.asset_id -ContactId $contactId -ClientId $EffectiveClientId
                    Log-Debug "Set-ITFlowAssetContact returned: $assignResult"
                    # Contact now exists and is assigned - retire any open missing-contact ticket flag.
                    if ($assignResult) { Clear-TicketFlag -Name $missingContactFlag }
                } elseif ($contactId) {
                    Log-Debug "Contact ID $contactId already assigned to this asset, skipping update"
                    Clear-TicketFlag -Name $missingContactFlag
                } else {
                    # ===== v7.5.5: Missing-contact ticket =====
                    # The device exists in ITFlow as an asset, but its primary user has no
                    # matching contact. Raise a ticket so a tech can create the contact and
                    # set it as the asset's primary. Fires whenever contact assignment is
                    # enabled (independent of the general ticketing toggle) and is deduped
                    # per asset + user via a ticket flag, cleared once a contact is assigned.
                    Log "No matching ITFlow contact found for primary user $($effectiveUser.DomainName)\$($effectiveUser.UserName)"
                    if (Test-TicketFlag -Name $missingContactFlag) {
                        Log-Debug "Missing-contact ticket already raised ($missingContactFlag) - not duplicating"
                    } else {
                        # Rebuild the email candidates that were tried, for the ticket body.
                        $triedEmails = New-Object System.Collections.Generic.List[string]
                        foreach ($e in (Get-ADUserEmailCandidates -SamAccountName $effectiveUser.UserName)) {
                            if ($e -and -not $triedEmails.Contains($e)) { $triedEmails.Add($e) }
                        }
                        if ($effectiveUser.UserName -like '*@*' -and -not $triedEmails.Contains($effectiveUser.UserName)) { $triedEmails.Add($effectiveUser.UserName) }
                        $fallbackEmail = "$($effectiveUser.UserName)@$emailDomain"
                        if (-not $triedEmails.Contains($fallbackEmail)) { $triedEmails.Add($fallbackEmail) }

                        $userPairs = [ordered]@{
                            "Username"       = "$($effectiveUser.DomainName)\$($effectiveUser.UserName)"
                            "Weighted usage" = "$($effectiveUser.WeightedMinutes) min (raw $($effectiveUser.TotalMinutes) min) over the last $AssignContactLookbackDays days"
                        }
                        $triedEmailItems = ($triedEmails | ForEach-Object { "<li>$(Protect-ITFlowHtml $_)</li>" }) -join ""
                        $triedEmailsHtml = "<p style=`"margin:8px 0 0 0;font-size:13px;color:#6b7280;`">Email lookups tried (none matched a contact):</p><ul style=`"margin:4px 0 0 0;padding-left:18px;font-size:13px;color:#1f2937;`">$triedEmailItems</ul>"
                        $devicePairs = [ordered]@{
                            "Hostname"   = $inv.Hostname
                            "Serial"     = $inv.Serial
                            "Make/Model" = "$($inv.Make) / $($inv.Model)"
                            "Asset ID"   = $asset.asset_id
                        }

                        $tb = New-ITFlowTicketBody -Sections @(
                            (New-ITFlowTicketParagraph "The ITFlow agent identified a primary user for this device, but no matching contact exists in ITFlow. The device is already recorded as an asset; please create the contact (or correct their email) and set them as this asset's primary contact."),
                            (New-ITFlowTicketSection -Title "Primary User" -Icon "👤" -InnerHtml ((New-ITFlowTicketKeyValueTable $userPairs) + $triedEmailsHtml)),
                            (New-ITFlowTicketSection -Title "Device" -Icon "🖥️" -InnerHtml (New-ITFlowTicketKeyValueTable $devicePairs)),
                            (New-ITFlowTicketParagraph "Suggested action: create or verify the contact above under this client, then set them as the asset's primary contact. The agent stops raising this ticket once a matching contact is assigned.")
                        )

                        $ticketTitle = "Primary contact missing for $($inv.Hostname): $($effectiveUser.UserName)"
                        $ticketResp = Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$asset.asset_id) -Details $tb
                        if ($ticketResp) {
                            Set-TicketFlag -Name $missingContactFlag | Out-Null
                            Log "Missing-contact ticket raised for $($effectiveUser.UserName) (asset $($asset.asset_id))"
                        } else {
                            Log "Missing-contact ticket creation failed for $($effectiveUser.UserName); will retry next sync"
                        }
                    }
                }
            } else {
                Log-Debug "No logon duration data to assign a contact"
            }
        } else {
            Log-Debug "Contact assignment disabled (AssignContactFromLogons=$AssignContactFromLogons)"
        }

        $retrySyncAfterTransfer = $false
    }
    else {
        if ($archivedInClient) {
            Log "Asset archived in configured client, checking for a live transferred copy..."
        } else {
            Log "Asset not found in configured client, checking for transferred copy..."
        }
        $foundTransferred = $false
        try {
            $transferLookup = Invoke-ITFlowChecked GET (New-ITFlowReadUri -Endpoint 'assets/read.php' -Query ([ordered]@{ asset_serial = $inv.Serial })) $null "Transfer lookup by serial"
            $foundTransferred = "$($transferLookup.success)" -eq "True" -and ($transferLookup.data -and $transferLookup.data.Count -gt 0)
        } catch {
            Log "Transfer lookup: serial not found in any client"
        }
        $transferSel = $null
        if ($foundTransferred) {
            $transferSel = Select-ITFlowAssetRow -Rows $transferLookup.data
            if (-not $transferSel.Active) {
                if ($archivedInClient) {
                    # This client's record is archived and no live copy is visible:
                    # transferred out of this key's scope, or simply archived.
                    Invoke-ArchivedInClientDecision -Inv $inv -ClientId ([int]$EffectiveClientId) -ArchivedRow $archivedInClient -DeviceSpec $DeviceSpec
                } else {
                    # Only an archived record elsewhere: following it would sync into an
                    # archived asset, and enrolling would duplicate its serial.
                    Invoke-ArchivedAssetNotice -Inv $inv -TicketClientId ([int]$EffectiveClientId) -ArchivedRow $transferSel.Archived[0] -FlagName "TransferTargetArchived" -LogTag "TRANSFER_TARGET_ARCHIVED" -DeviceSpec $DeviceSpec
                }
                $script:LastSyncOK = $false
                return
            }
            # A live copy exists (for an ITFlow transfer: the new asset in the new
            # client, the archived original here being ignored) - follow it.
            Clear-TicketFlag "TransferTargetArchived"
            Clear-TicketFlag "AssetArchived"
            Clear-TicketFlag "TransferOutOfScope"
        } elseif ($archivedInClient) {
            # Transfer lookup failed or saw nothing, yet this client has an archived
            # record for the serial: never fall through to enrolment.
            Invoke-ArchivedInClientDecision -Inv $inv -ClientId ([int]$EffectiveClientId) -ArchivedRow $archivedInClient -DeviceSpec $DeviceSpec
            $script:LastSyncOK = $false
            return
        }
        if ($foundTransferred) {
            $moved = $transferSel.Active
            $discoveredClientId = try { [int](Normalize-Value $moved.asset_client_id) } catch { 0 }
            $discoveredAssetId  = try { [int](Normalize-Value $moved.asset_id) } catch { 0 }
            $followResult = Invoke-AssetTransferFollow -Inv $inv -DiscoveredClientId $discoveredClientId -DiscoveredAssetId $discoveredAssetId -DeviceSpec $DeviceSpec
            if ($followResult.Followed) {
                $EffectiveClientId = $followResult.DiscoveredClientId
                $asset = $moved
                $lookup = [pscustomobject]@{ success = "True"; data = @($asset) }
                $retrySyncAfterTransfer = $true
            } else {
                $script:LastSyncOK = $false
                return
            }
        } else {
            Write-TransferLookupScopeCaveat -Serial $inv.Serial
            $enrollPairs = [ordered]@{
                "Hostname"   = $snapshot.Device.Hostname
                "Serial"     = $snapshot.Device.Serial
                "Make/Model" = "$($snapshot.Device.Make) / $($snapshot.Device.Model)"
                "OS"         = $snapshot.Device.OS
                "Type"       = $snapshot.Device.AssetType
                "MAC"        = $snapshot.Device.PrimaryMAC
                "IP"         = $snapshot.Device.PrimaryIP
            }
            $enrollDetails = New-ITFlowTicketBody -DeviceSpec $DeviceSpec -Sections @(
                (New-ITFlowTicketSection -Title "Device Information" -Icon "🆕" -InnerHtml (New-ITFlowTicketKeyValueTable $enrollPairs))
            )
            $retrySyncAfterTransfer = $false
            Start-AssetEnrollment -Inv $inv -DetectedAssetType $DetectedAssetType -EffectiveClientId $EffectiveClientId -Details $enrollDetails -DeviceSpec $DeviceSpec
        }
    }
    } while ($retrySyncAfterTransfer)
    $retrySyncAfterTransfer = $false

    # Sync AD computer attributes (works when running as SYSTEM via scheduled task)
    try {
        Sync-ADComputerAttributes -Snapshot $snapshot -DeviceSpec $DeviceSpec -LastCheckIn $lastCheckIn -ComputerSystem $snapshot._CimComputerSystem
    } catch {
        Log "Sync-ADComputerAttributes threw (non-fatal): $($_.Exception.Message)"
    }

    # Device Report trigger (GPO registry key)
    Invoke-DeviceReportCheck -Hostname $inv.Hostname -Serial $inv.Serial -ClientId $EffectiveClientId -DeviceSpec $DeviceSpec

    # Enrichment only: match external monitors to existing ITFlow Display assets
    # and update make/model/asset_specs. Never creates an asset - see
    # Sync-ITFlowDisplayAssets for the matching rules.
    try {
        $displayTicketingEnabled = (($Silent -and $EnableTicketingSilent) -or (-not $Silent -and $EnableTicketingGui))
        Sync-ITFlowDisplayAssets -Displays $snapshot.Displays -ClientId ([int]$EffectiveClientId) -HostHostname $inv.Hostname -HostSerial $inv.Serial -PushDisplaySpecs $PushDisplaySpecs -TicketUnmatchedDisplays $TicketUnmatchedDisplays -TicketingEnabled $displayTicketingEnabled
    } catch {
        Log "Sync-ITFlowDisplayAssets threw (non-fatal): $($_.Exception.Message)"
    }

    # Persist success flag for silent-mode retry logic
    $script:LastSyncOK = $true
    Set-StateDword -Name 'LastSyncOK' -Value 1
}

# =====================================================
# SCHEDULED TASK INSTALL/UNINSTALL
# =====================================================

function Install-ITFlowScheduledTask {
    # Use explicit path if provided, otherwise auto-detect
    $scriptPath = $TaskScriptPath
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }
    if (-not $scriptPath) { Log "ERROR: Cannot determine script path for scheduled task. Use -TaskScriptPath to specify."; return $false }

    # Resolve to absolute path and validate
    $resolvedPath = try { [System.IO.Path]::GetFullPath($scriptPath) } catch { $null }
    if (-not $resolvedPath) { Log "ERROR: Invalid -TaskScriptPath '$scriptPath'"; return $false }

    # -Reboot puts the startup sync in unattended auto-rename mode: when a rename
    # is required it renames and immediately restarts (only if no interactive user
    # is present), so the AD object rename and the local reboot that completes it
    # happen back-to-back. This avoids the domain-trust window that opens when a
    # renamed-in-AD machine sits pending-reboot waiting for a user who never restarts.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$resolvedPath`" -Silent -Rename -Reboot -Worker" -WorkingDirectory (Split-Path $resolvedPath -Parent)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Compatibility Win8 -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Log "Scheduled task '$TaskName' installed (triggers at startup, script='$resolvedPath', runs as SYSTEM)"
        return $true
    } catch {
        Log "ERROR: Failed to install scheduled task: $($_.Exception.Message)"
        return $false
    }
}

function Uninstall-ITFlowScheduledTask {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Log "Scheduled task '$TaskName' not found - nothing to uninstall"
            return $true
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop | Out-Null
        Log "Scheduled task '$TaskName' uninstalled"
        return $true
    } catch {
        Log "ERROR: Failed to uninstall scheduled task: $($_.Exception.Message)"
        return $false
    }
}

# Switch the main task trigger between startup and hourly retry
function Set-ITFlowTaskTrigger {
    param([switch]$Startup, [switch]$Hourly)

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }

    if ($Startup) {
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $task.Triggers = @($trigger)
        $task | Set-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        Log "Scheduled task '$TaskName' set to startup trigger"
    } elseif ($Hourly) {
        # Don't re-apply if already hourly - preserves the 24h duration countdown
        $hasRepetition = $task.Triggers -and $task.Triggers[0].Repetition -and $task.Triggers[0].Repetition.Interval
        if ($hasRepetition) {
            Log "Scheduled task '$TaskName' already on hourly retry - keeping existing trigger"
            return
        }
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 1)
        $task.Triggers = @($trigger)
        $task | Set-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        Log "Scheduled task '$TaskName' set to hourly retry (max 24h)"
    }
}

# =====================================================
# Mutex-safe exit helper
# =====================================================
function Exit-WithMutexRelease {
    param([int]$ExitCode = 0)
    if (-not $Worker -and $script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch {}
        try { $script:mutex.Dispose() } catch {}
    }
    exit $ExitCode
}

# Handle -Install / -Uninstall before anything else (even before silent mode)
if ($Install) {
    $installDir = "C:\ProgramData\ITFlow"
    $installPath = Join-Path $installDir "ITFlow-Agent.ps1"

    # Check if already installed
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $installedVersion = $null
    if (Test-Path $installPath) {
        try {
            $installedLine = Get-Content $installPath -TotalCount 50 | Where-Object { $_ -match '^\$AgentVersion\s*=' } | Select-Object -First 1
            if ($installedLine) { $installedVersion = ($installedLine -split '=')[1].Trim().Trim('"') }
        } catch { }
    }

    if ($existingTask -and $installedVersion -eq $AgentVersion) {
        Log "Agent v$AgentVersion already installed - triggering scheduled task"
            try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { try { schtasks.exe /run /tn $TaskName *>$null } catch { Log "Task trigger failed: $($_.Exception.Message)" } }
        Exit-WithMutexRelease
    }

    if ($existingTask -and $installedVersion -and $installedVersion -ne $AgentVersion) {
        # Protect against downgrade: skip if installed version is newer
        try {
            $installedVer = [version]$installedVersion
            $currentVer = [version]$AgentVersion
            if ($installedVer -gt $currentVer) {
                Log "Skipping downgrade: installed v$installedVersion is newer than this script v$AgentVersion"
                Exit-WithMutexRelease
            }
        } catch {
            Log "Version comparison failed (non-fatal): installed='$installedVersion' current='$AgentVersion' - proceeding with update"
        }
        Log "Updating agent v$installedVersion -> v$AgentVersion..."
    } else {
        Log "Installing agent v$AgentVersion to $installPath..."
    }

    try { Write-ConfigToRegistry | Out-Null; Log "Registry config written" } catch { Log "Registry config write failed: $($_.Exception.Message)" }
    try {
        # SECURITY (v7.5.5): reset a planted reparse point and lock down the install
        # directory owner+DACL *before* trusting it, then copy in the script and
        # harden the file too. Converts "any user + reboot = SYSTEM" into
        # "requires admin to tamper".
        Protect-InstallPath -InstallDir $installDir
        Copy-Item -Path $PSCommandPath -Destination $installPath -Force -ErrorAction Stop
        Set-ITFlowHardenedAcl -Path $installPath | Out-Null
        Log "Script copied to $installPath (hardened ACL applied)"
    } catch { Log "ERROR: Failed to copy script: $($_.Exception.Message)" }
    if (-not $TaskScriptPath) { $TaskScriptPath = $installPath }
    Install-ITFlowScheduledTask
    try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { try { schtasks.exe /run /tn $TaskName *>$null } catch { Log "Task trigger fallback failed: $($_.Exception.Message)" } }
    Log "Scheduled task triggered for first sync"
    Exit-WithMutexRelease
}
if ($Uninstall) {
    Uninstall-ITFlowScheduledTask
    try { Remove-Item -LiteralPath "HKLM:\SOFTWARE\ITFlow" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath "C:\ProgramData\ITFlow" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Log "ITFlow agent fully uninstalled"
    Exit-WithMutexRelease
}

# GUI ticket preference applies to all modes - read early for silent/worker contexts
$script:EnableTicketingGui = (Get-PreferenceDword -Name "CreateTicketsGui" -Default 1) -ne 0
# Sync silent ticket flags with the GUI preference so the checkbox controls all tickets
$EnableTicketingSilent = $script:EnableTicketingGui
$EnableRenameFailureTicketing = $script:EnableTicketingGui
# Read transfer/update preferences early too (worker doesn't reach the form section)
$AllowFollowClientTransfer = (Get-PreferenceDword -Name "FollowClientTransfers" -Default 1) -ne 0
$PushAssetSpecs = (Get-PreferenceDword -Name "PushAssetSpecs" -Default 1) -ne 0
$PushDisplaySpecs = (Get-PreferenceDword -Name "PushDisplaySpecs" -Default 1) -ne 0
$TicketUnmatchedDisplays = (Get-PreferenceDword -Name "TicketUnmatchedDisplays" -Default 0) -ne 0
$AutoUpdateClientIdOnTransfer = (Get-PreferenceDword -Name "AutoUpdateClientIdOnTransfer" -Default 1) -ne 0

# Dynamic Contact Assignment preferences
$AssignContactFromLogons = (Get-PreferenceDword -Name "AssignContactFromLogons" -Default 0) -ne 0
$AssignContactLookbackDays = (Get-PreferenceDword -Name "AssignContactLookbackDays" -Default 90)
$AssignContactHalfLifeDays = (Get-PreferenceDword -Name "AssignContactHalfLifeDays" -Default 14)
$AssignContactAllowedDomain = Get-PreferenceString -Name "AssignContactAllowedDomain" -Default ""
$VerboseLogging = (Get-PreferenceDword -Name "VerboseLogging" -Default 0) -ne 0
# =====================================================
# REMEDIATION C: RUNTIME SELF-DEFENCE (SYSTEM run only)
# Before the SYSTEM/startup task does any privileged work, verify the running
# script cannot be modified by a non-administrator. If it can, refuse to run
# (log and skip the sync) so a tampered script never executes as SYSTEM. GUI and
# portable runs are never SYSTEM, so they are unaffected.
# =====================================================
if ($script:IsSystemContext) {
    if (-not (Test-ScriptIntegrity -Path $PSCommandPath)) {
        Log "SECURITY: aborting SYSTEM run - script integrity check failed for '$PSCommandPath'. Re-run install as administrator to restore a safe ACL."
        $script:LastSyncOK = $false
        try { Set-StateDword -Name 'LastSyncOK' -Value 0 } catch { }
        Exit-WithMutexRelease 1
    }
    Log-Debug "Script integrity check passed for SYSTEM run"
}

# =====================================================
# SILENT MODE (NO GUI)
# - In Worker mode, NEVER call exit (it can kill the hosting runspace/pipeline).
# =====================================================
if ($Silent) {
    try {
        Run-AssetSync -AllowSilentRename:$Rename
    }
    catch {
        Log ($_ | Out-String)
        $script:LastSyncOK = $false
    }

    # Persist result to registry for cross-session tracking
    if ($script:LastSyncOK) {
        Set-StateDword -Name 'LastSyncOK' -Value 1
    } else {
        Set-StateDword -Name 'LastSyncOK' -Value 0
    }

    # Switch task trigger based on sync outcome
    if ($script:LastSyncOK) {
        Set-ITFlowTaskTrigger -Startup
    } else {
        Set-ITFlowTaskTrigger -Hourly
    }

    if ($Worker) { return } else { Exit-WithMutexRelease }
}

# =====================================================
# MAIN FORM (Compact start; width locked; expand changes height only)
# =====================================================
$form = New-Object Windows.Forms.Form
$form.Text = "ITFlow Agent"
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font

# Temporary size (we snap to computed compact size on Shown)
$form.Size = New-Object Drawing.Size(900, 600)

# =====================================================
# Apply GUI-mode preferences at startup (no UI required)
# - Tickets GUI default OFF
# - Follow transfers default ON
# - Auto-update ClientId default ON
# =====================================================
$script:EnableTicketingGui     = (Get-PreferenceDword -Name "CreateTicketsGui" -Default 1) -ne 0
$AllowFollowClientTransfer     = (Get-PreferenceDword -Name "FollowClientTransfers" -Default 1) -ne 0
$PushAssetSpecs                = (Get-PreferenceDword -Name "PushAssetSpecs" -Default 1) -ne 0
$PushDisplaySpecs              = (Get-PreferenceDword -Name "PushDisplaySpecs" -Default 1) -ne 0
$TicketUnmatchedDisplays       = (Get-PreferenceDword -Name "TicketUnmatchedDisplays" -Default 0) -ne 0
$AutoUpdateClientIdOnTransfer  = (Get-PreferenceDword -Name "AutoUpdateClientIdOnTransfer" -Default 1) -ne 0
$AssignContactFromLogons       = (Get-PreferenceDword -Name "AssignContactFromLogons" -Default 0) -ne 0
$AssignContactLookbackDays     = (Get-PreferenceDword -Name "AssignContactLookbackDays" -Default 90)
$AssignContactHalfLifeDays     = (Get-PreferenceDword -Name "AssignContactHalfLifeDays" -Default 14)
$AssignContactAllowedDomain     = Get-PreferenceString -Name "AssignContactAllowedDomain" -Default ""
$VerboseLogging                 = (Get-PreferenceDword -Name "VerboseLogging" -Default 0) -ne 0
# =====================================================
# Root layout: Header / Status / Details (details row collapses to 0 when hidden)
# =====================================================
$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 3
$null = $root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))          # header
$null = $root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))          # status
$null = $root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 0)))       # details collapsed by default
$form.Controls.Add($root)

# =====================================================
# HEADER: left buttons + spacer + fixed-right Config
# - Buttons remain on ONE LINE (no wrapping)
# =====================================================
$headerTable = New-Object Windows.Forms.TableLayoutPanel
$headerTable.Dock = 'Top'
$headerTable.AutoSize = $true
$headerTable.ColumnCount = 3
$headerTable.RowCount = 1
$null = $headerTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))     # left buttons
$null = $headerTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100))) # spacer
$null = $headerTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))     # config
$headerTable.Padding = New-Object Windows.Forms.Padding(10,6,10,0)
$headerTable.Margin  = New-Object Windows.Forms.Padding(0)
$root.Controls.Add($headerTable, 0, 0)

$headerLeftFlow = New-Object Windows.Forms.FlowLayoutPanel
$headerLeftFlow.AutoSize = $true
$headerLeftFlow.WrapContents = $false
$headerLeftFlow.FlowDirection = 'LeftToRight'
$headerLeftFlow.Margin = New-Object Windows.Forms.Padding(0)
$headerTable.Controls.Add($headerLeftFlow, 0, 0)

$headerSpacer = New-Object Windows.Forms.Panel
$headerSpacer.Dock = 'Fill'
$headerSpacer.Margin = New-Object Windows.Forms.Padding(0)
$headerTable.Controls.Add($headerSpacer, 1, 0)

$headerRightFlow = New-Object Windows.Forms.FlowLayoutPanel
$headerRightFlow.AutoSize = $true
$headerRightFlow.WrapContents = $false
$headerRightFlow.FlowDirection = 'LeftToRight'
$headerRightFlow.Margin = New-Object Windows.Forms.Padding(0)
$headerTable.Controls.Add($headerRightFlow, 2, 0)

# --- Header buttons (left)
$btnTest = New-Object Windows.Forms.Button
$btnTest.Text = "Test API"
$btnTest.Width = 90
$btnTest.Height = 32
$headerLeftFlow.Controls.Add($btnTest)

$btnRun = New-Object Windows.Forms.Button
$btnRun.Text = "Run / Sync"
$btnRun.Width = 100
$btnRun.Height = 32
$headerLeftFlow.Controls.Add($btnRun)

$btnInstall = New-Object Windows.Forms.Button
$btnInstall.Text = "Install"
$btnInstall.Width = 100
$btnInstall.Height = 32
$headerLeftFlow.Controls.Add($btnInstall)

$script:IsInstalled = $false
$script:InstallPollIsUninstall = $null
$script:RenamePollTimer = $null

function Update-InstallButton {
    $script:IsInstalled = Test-Path "C:\ProgramData\ITFlow\ITFlow-Agent.ps1" -ErrorAction SilentlyContinue
    $btnInstall.Text = if ($script:IsInstalled) { "Uninstall" } else { "Install" }
}

$btnSysinfoOpen = New-Object Windows.Forms.Button
$btnSysinfoOpen.Text = "Open SysInfo"
$btnSysinfoOpen.Width = 100
$btnSysinfoOpen.Height = 32
$headerLeftFlow.Controls.Add($btnSysinfoOpen)

$btnSysinfoView = New-Object Windows.Forms.Button
$btnSysinfoView.Text = "View SysInfo"
$btnSysinfoView.Width = 100
$btnSysinfoView.Height = 32
$headerLeftFlow.Controls.Add($btnSysinfoView)

$script:btnRename = New-Object Windows.Forms.Button
$script:btnRename.Text = "Rename"
$script:btnRename.Width = 100
$script:btnRename.Height = 32
$script:btnRename.Enabled = $false
$headerLeftFlow.Controls.Add($script:btnRename)
$script:btnRename.Add_Click({ Invoke-GuiRenameFromButton })

# --- Config (fixed right)
$btnConfig = New-Object Windows.Forms.Button
$btnConfig.Text = "Config"
$btnConfig.Width = 90
$btnConfig.Height = 32
$headerRightFlow.Controls.Add($btnConfig)


# =====================================================
# STATUS ROW (status label truncates so Show Details never gets pushed off)
# =====================================================
$statusTable = New-Object Windows.Forms.TableLayoutPanel
$statusTable.Dock = 'Top'
$statusTable.AutoSize = $true
$statusTable.ColumnCount = 2
$statusTable.RowCount = 1
$null = $statusTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
$null = $statusTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$statusTable.Padding = New-Object Windows.Forms.Padding(10,2,10,2)
$statusTable.Margin  = New-Object Windows.Forms.Padding(0)
$root.Controls.Add($statusTable, 0, 1)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text = "STATUS: Idle"
$statusLabel.Font = New-Object Drawing.Font("Segoe UI",10,[Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::Gray
$statusLabel.AutoSize = $false
$statusLabel.AutoEllipsis = $true
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.Margin = New-Object Windows.Forms.Padding(0,2,10,2)
$statusTable.Controls.Add($statusLabel, 0, 0)

$btnToggle = New-Object Windows.Forms.Button
$btnToggle.Text = "Show Details"
$btnToggle.Width = 140
$btnToggle.Height = 28
$btnToggle.Margin = New-Object Windows.Forms.Padding(0,2,0,2)
$statusTable.Controls.Add($btnToggle, 1, 0)

function Set-Status {
    param([string]$Text,[System.Drawing.Color]$Color = [System.Drawing.Color]::Gray)
    $statusLabel.Text = "STATUS: $Text"
    $statusLabel.ForeColor = $Color
}

# =====================================================
# DETAILS AREA (Overview + Log stacked) - collapsed by default
# =====================================================
$detailsPanel = New-Object Windows.Forms.Panel

$detailsPanel.BorderStyle = 'FixedSingle'
$detailsPanel.BackColor = [System.Drawing.Color]::WhiteSmoke

$detailsPanel.Dock = 'Fill'
$detailsPanel.Padding = New-Object Windows.Forms.Padding(10,8,10,10)
$detailsPanel.Margin  = New-Object Windows.Forms.Padding(0)
$detailsPanel.Visible = $false
$root.Controls.Add($detailsPanel, 0, 2)


$detailsLayout = New-Object Windows.Forms.TableLayoutPanel
$detailsLayout.Dock = 'Fill'
$detailsLayout.ColumnCount = 1
$detailsLayout.RowCount = 2
$null = $detailsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))         # overview
$null = $detailsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))    # log
$detailsLayout.Padding = New-Object Windows.Forms.Padding(0)
$detailsLayout.Margin  = New-Object Windows.Forms.Padding(0)
$detailsPanel.Controls.Add($detailsLayout)

# -------------------------
# Device Overview (Details)
# -------------------------
$overviewGroup = New-Object Windows.Forms.GroupBox
$overviewGroup.Text = "Device Overview"
$overviewGroup.Dock = 'Top'
$overviewGroup.AutoSize = $true
$overviewGroup.Padding = New-Object Windows.Forms.Padding(10,20,10,10)
$overviewGroup.Margin  = New-Object Windows.Forms.Padding(0,0,0,8)
$detailsLayout.Controls.Add($overviewGroup, 0, 0)

$overviewGrid = New-Object Windows.Forms.TableLayoutPanel
$overviewGrid.Dock = 'Top'
$overviewGrid.AutoSize = $true
$overviewGrid.ColumnCount = 4
$overviewGrid.RowCount = 6
$null = $overviewGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$null = $overviewGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 50)))
$null = $overviewGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$null = $overviewGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 50)))
$overviewGroup.Controls.Add($overviewGrid)

function Add-GridField {
    param($grid,[int]$row,[int]$colCaption,[string]$caption,[int]$colValue)

    $cap = New-Object Windows.Forms.Label
    $cap.Text = $caption
    $cap.AutoSize = $true
    $cap.Margin = New-Object Windows.Forms.Padding(0,4,10,4)
    $grid.Controls.Add($cap, $colCaption, $row)

    $val = New-Object Windows.Forms.Label
    $val.Text = "-"
    $val.AutoEllipsis = $true
    $val.Dock = 'Fill'
    $val.Margin = New-Object Windows.Forms.Padding(0,4,10,4)
    $grid.Controls.Add($val, $colValue, $row)

    return $val
}

$ovHostname  = Add-GridField $overviewGrid 0 0 "Hostname:" 1
$ovSerial    = Add-GridField $overviewGrid 1 0 "Serial:"   1
$ovType      = Add-GridField $overviewGrid 2 0 "Type:"     1
$ovIpMac     = Add-GridField $overviewGrid 3 0 "IP / MAC:" 1

$ovClientCfg = Add-GridField $overviewGrid 0 2 "ClientId (Configured):" 3
$ovClientEff = Add-GridField $overviewGrid 1 2 "ClientId (Effective):"  3
$ovAssetId   = Add-GridField $overviewGrid 2 2 "AssetId:"               3
$ovTransfer  = Add-GridField $overviewGrid 3 2 "Transfer Followed / ClientId Updated:" 3

$sysCap = New-Object Windows.Forms.Label
$sysCap.Text = "Sysinfo:"
$sysCap.AutoSize = $true
$sysCap.Margin = New-Object Windows.Forms.Padding(0,4,10,4)
$overviewGrid.Controls.Add($sysCap, 0, 4)

$ovSysinfo = New-Object Windows.Forms.Label
$ovSysinfo.Text = "-"
$ovSysinfo.AutoEllipsis = $true
$ovSysinfo.Dock = 'Fill'
$ovSysinfo.Margin = New-Object Windows.Forms.Padding(0,4,10,4)
$overviewGrid.Controls.Add($ovSysinfo, 1, 4)
$overviewGrid.SetColumnSpan($ovSysinfo, 3)


function Refresh-OverviewUI {
    # Always show a fast local snapshot first (source of truth before any sync)
    $local = Get-QuickLocalDeviceOverview

    $ovHostname.Text = if ($local.Hostname) { $local.Hostname } else { $env:COMPUTERNAME }
    $ovSerial.Text   = if ($local.Serial)   { $local.Serial }   else { "-" }
    $ovType.Text     = if ($local.Type)     { $local.Type }     else { "-" }

    if ($local.IP -or $local.MAC) {
        $ip  = if ($local.IP)  { $local.IP }  else { "-" }
        $mac = if ($local.MAC) { $local.MAC } else { "-" }
        $ovIpMac.Text = "$ip / $mac"
    } else {
        $ovIpMac.Text = "-"
    }

    # Configured values (static)
    $ovClientCfg.Text = $Config.ClientId

    # Last-known ITFlow context (light read; does not affect local snapshot)
    $ovClientEff.Text = "-"
    $ovAssetId.Text   = "-"

    $lastEff = Get-StateString -Name "LastEffectiveClientId" -Default ""
    $lastAid = Get-StateString -Name "LastAssetId" -Default ""
    if ($lastEff) { $ovClientEff.Text = "$lastEff (last)" }
    if ($lastAid) { $ovAssetId.Text   = "$lastAid (last)" }

    # Transfer flags (default)
    $ovTransfer.Text  = "No / No"

    # Sysinfo path (local expectation)
    $sysPath = "C:\ProgramData\ITFlow\sysinfo_$($env:COMPUTERNAME).json"
    $ovSysinfo.Text = $sysPath

    # If we have a last-run state in THIS runspace (e.g., after sync), annotate transfer flags + sysinfo timestamp.
    if ($script:LastRunState -and $script:LastRunState.Serial) {
        $follow = if ($script:LastRunState.TransferFollowed) { "Yes" } else { "No" }
        $auto   = if ($script:LastRunState.ClientIdAutoUpdated) { "Yes" } else { "No" }
        $ovTransfer.Text = "$follow / $auto"

        if ($script:LastRunState.SysInfoPath) {
            if ($script:LastRunState.SysInfoCollectedAt) {
                $ovSysinfo.Text = "$($script:LastRunState.SysInfoPath) (Collected: $($script:LastRunState.SysInfoCollectedAt))"
            } else {
                $ovSysinfo.Text = $script:LastRunState.SysInfoPath
            }
        }
    }
}
Refresh-OverviewUI

# -------------------------
# Log (Details)
# -------------------------
$logGroup = New-Object Windows.Forms.GroupBox
$logGroup.Text = "Log"
$logGroup.Dock = 'Fill'
$logGroup.Padding = New-Object Windows.Forms.Padding(10,20,10,10)
$logGroup.Margin  = New-Object Windows.Forms.Padding(0)

# Minimum visible log height when expanded (tune if desired)
$logGroup.MinimumSize = New-Object Drawing.Size(0, 180)

$detailsLayout.Controls.Add($logGroup, 0, 1)

# IMPORTANT: same $log variable used by Log()
$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Dock = 'Fill'
$log.Font = New-Object Drawing.Font("Consolas", 9)
$logGroup.Controls.Add($log)


# =====================================================
# =====================================================
# POST-SYNC SAFE RENAME (NO REBOOT)
# -----------------------------------------------------
# New behavior:
# - No automatic prompts
# - No reboot prompts
# - Silent mode: rename allowed only when -Rename switch is provided
# - GUI mode: Rename button becomes enabled after sync detects mismatch
# =====================================================

function Update-RenameButtonState {
    param([switch]$AfterSync)

    if (-not $AllowUserInteraction) { return }
    if (-not $script:btnRename) { return }

    # Check for pending reboot rename from a previous session
    $pendingRename = Test-PendingComputerRename
    if ($pendingRename) {
        Set-Status "Rename pending - reboot required" ([System.Drawing.Color]::DarkOrange)
        $script:btnRename.Enabled = $false
        $script:btnRename.Tag = $null
        return
    }

    # Enabled only when mismatch is queued and sync is not running
    $target = Get-QueuedRenameTarget
    $enable = (-not $script:SyncRunning) -and ($null -ne $target)

    # Don't enable the button if the previous rename attempt failed
    if ($enable -and $target) {
        $failedFlag = "RenameFailed_$target"
        if (Test-TicketFlag $failedFlag) {
            Set-Status "Previous rename failed - manual intervention required" ([System.Drawing.Color]::DarkRed)
            $script:btnRename.Enabled = $false
            $script:btnRename.Tag = $null
            return
        }
    }

    $script:btnRename.Enabled = $enable
    if ($enable) {
        $script:btnRename.Tag = $target
        $script:btnRename.Text = "Rename"
        if ($AfterSync) {
            Log "Rename available: queued target hostname '$target'"
            Set-Status "Rename available: $target" ([System.Drawing.Color]::DarkOrange)
        }
    } else {
        $script:btnRename.Tag = $null
        if ($AfterSync) {
            Set-Status "Idle"
        }
    }
}

function Invoke-GuiRenameFromButton {
    if (-not $AllowUserInteraction) { return }

    # Resolve target first (needed by both elevation and direct paths)
    $target = $null
    try { $target = [string]$script:btnRename.Tag } catch { $target = $null }

    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = Get-QueuedRenameTarget
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        Log "Rename button clicked but no queued target found."
        Update-RenameButtonState
        return
    }

    # Self-elevate if needed
    if (-not (Test-IsAdmin)) {
        $resp = [System.Windows.Forms.MessageBox]::Show(
            "Renaming the computer requires administrator privileges. Restart as administrator?",
            "Elevation Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent -Rename -Worker" -ErrorAction Stop | Out-Null
                # Poll for rename completion by monitoring the queued-rename state
                $script:RenamePollTarget = $target
                $script:RenamePollCount = 0
                $script:RenamePollTimer = New-Object System.Windows.Forms.Timer
                $script:RenamePollTimer.Interval = 1000
                $script:RenamePollTimer.Add_Tick({
                    $script:RenamePollCount++
                    $remaining = Get-QueuedRenameTarget
                    if (-not $remaining) {
                        $script:RenamePollTimer.Stop()
                        $script:RenamePollTimer.Dispose()
                        $script:RenamePollCount = 0
                        $tgt = $script:RenamePollTarget
                        $script:RenamePollTarget = $null
                        Update-RenameButtonState
                        Update-InstallButton
                        Set-Status "Rename completed. Reboot pending." ([System.Drawing.Color]::ForestGreen)
                        try {
                            $rebootNow = [System.Windows.Forms.MessageBox]::Show(
                                "Rename completed successfully to '$tgt'.`r`n`r`nA reboot is required for the change to fully apply. Reboot now?",
                                "Rename Completed",
                                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                                [System.Windows.Forms.MessageBoxIcon]::Question
                            )
                            if ($rebootNow -eq [System.Windows.Forms.DialogResult]::Yes) {
                                Log "User chose to reboot immediately after rename"
                                shutdown.exe /r /t 30 /c "ITFlow Agent: Rename to '$tgt' completed. Rebooting to apply."
                            } else {
                                Log "User deferred reboot after rename"
                            }
                        } catch { }
                    } elseif ($script:RenamePollCount -ge 30) {
                        $script:RenamePollTimer.Stop()
                        $script:RenamePollTimer.Dispose()
                        $script:RenamePollCount = 0
                        $script:RenamePollTarget = $null
                        Update-RenameButtonState
                        Set-Status "Rename check complete" ([System.Drawing.Color]::Gray)
                        [System.Windows.Forms.MessageBox]::Show(
                            "Rename operation may have failed or completed silently. Check the logs for details.",
                            "Rename Check",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information
                        ) | Out-Null
                    }
                })
                $script:RenamePollTimer.Start()
            } catch {
                Log "Rename elevation failed: $($_.Exception.Message)"
            }
        }
        return
    }

    try { $serialForRename = $script:LastRunState.Serial } catch { $serialForRename = "" }
    $ok = Invoke-HostnameRenameSafe -DesiredHostname $target -Serial $serialForRename

    if ($ok) {
        Clear-QueuedRename
        Update-RenameButtonState
        Set-Status "Rename completed. Reboot pending." ([System.Drawing.Color]::ForestGreen)
        try {
            $rebootNow = [System.Windows.Forms.MessageBox]::Show(
                "Rename completed successfully to '$target'.`r`n`r`nA reboot is required for the change to fully apply. Reboot now?",
                "Rename Completed",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($rebootNow -eq [System.Windows.Forms.DialogResult]::Yes) {
                Log "User chose to reboot immediately after rename"
                shutdown.exe /r /t 30 /c "ITFlow Agent: Rename to '$target' completed. Rebooting to apply."
            } else {
                Log "User deferred reboot after rename"
            }
        } catch { }
    }
}


# ASYNC ENGINE (RunspacePool) - PowerShell 5.1 SAFE
# -----------------------------------------------------
# - Starts worker run in a background runspace
# - Cancels by calling $ps.Stop() (interrupts retry sleep)
# - Tails shared log file into UI in real time
# =====================================================
Add-Type -AssemblyName System.Management.Automation

$script:SyncPS       = $null
$script:SyncHandle   = $null
$script:SyncPool     = $null
$script:SyncRunning  = $false

# Log tail state
$script:TailTimer    = New-Object System.Windows.Forms.Timer
$script:TailTimer.Interval = 250
$script:TailPos      = 0

# Completion poll timer
$script:PollTimer    = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 200

function Set-UiRunningState {
    param([bool]$Running)

    $script:SyncRunning = $Running

    if ($Running) {
        $btnRun.Text = "Cancel Sync"
        $btnTest.Enabled = $false
        $btnInstall.Enabled = $false
        $btnConfig.Enabled = $false
        $btnSysinfoOpen.Enabled = $false
        $btnSysinfoView.Enabled = $false
    }
    else {
        $btnRun.Text = "Run / Sync"
        $btnTest.Enabled = $true
        $btnInstall.Enabled = $true
        $btnConfig.Enabled = $true
        $btnSysinfoOpen.Enabled = $true
        $btnSysinfoView.Enabled = $true
    }
}

function Start-LogTail {
    # Start tailing from current end (so we only show new lines)
    try {
        if (Test-Path $LogFile) {
            $script:TailPos = (Get-Item $LogFile).Length
        } else {
            $script:TailPos = 0
        }
    } catch { $script:TailPos = 0 }

    $script:TailTimer.Start()
}

function Stop-LogTail {
    $script:TailTimer.Stop()
}

$script:TailTimer.Add_Tick({
    try {
        if (-not (Test-Path $LogFile)) { return }

        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -le $script:TailPos) { return }
            $fs.Seek($script:TailPos, [System.IO.SeekOrigin]::Begin) | Out-Null
            $sr = New-Object System.IO.StreamReader($fs)
            $newText = $sr.ReadToEnd()
            $script:TailPos = $fs.Position

            if (-not [string]::IsNullOrWhiteSpace($newText)) {
                $log.AppendText($newText)
            }
        }
        finally {
            $fs.Close()
            $fs.Dispose()
        }
    } catch {
        # ignore tail errors
    }
})

function Start-SyncAsync {

    if ($script:SyncRunning) { return }

    Set-UiRunningState $true
    Set-Status "Running sync..." ([System.Drawing.Color]::DarkGoldenrod)
    Log "Sync started (runspacepool)."

    # Create pool (1 runspace only; prevents overlapping runs)
    $script:SyncPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1,1)
    $script:SyncPool.ApartmentState = [System.Threading.ApartmentState]::STA
    $script:SyncPool.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:SyncPool.Open()

    $script:SyncPS = [System.Management.Automation.PowerShell]::Create()
    $script:SyncPS.RunspacePool = $script:SyncPool

    # IMPORTANT:
    # We run THIS SAME script in Worker+Silent mode inside the background runspace.
    # - Worker skips mutex and avoids exit
    # - Silent prevents GUI creation in the worker
    # - LogPath forces the worker to write into the same log file so UI can tail it
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    $script:SyncPS.AddScript({
        param($path, $logPath)
        & $path -Silent -Worker -LogPath $logPath
    }).AddArgument($scriptPath).AddArgument($LogFile) | Out-Null

    Start-LogTail

    # Start async pipeline
    $script:SyncHandle = $script:SyncPS.BeginInvoke()

    $script:PollTimer.Start()
}

function Cancel-SyncAsync {
    if (-not $script:SyncRunning) { return }

    Set-Status "Cancelling..." ([System.Drawing.Color]::DarkGoldenrod)
    Log "Cancel requested..."

    try {
        # Stop the pipeline: this interrupts Start-Sleep and most script execution quickly
        if ($script:SyncPS) { $script:SyncPS.Stop() }
    } catch {}
}

$script:PollTimer.Add_Tick({
    if (-not $script:SyncHandle) { return }

    if ($script:SyncHandle.IsCompleted) {

        $script:PollTimer.Stop()
        Stop-LogTail

        try {
            # EndInvoke will throw if pipeline failed/cancelled
            $null = $script:SyncPS.EndInvoke($script:SyncHandle)

            Refresh-OverviewUI
            Set-Status "Success" ([System.Drawing.Color]::DarkGreen)
        }
        catch {
            $detail = ($_ | Out-String)

            if ($detail -match 'PipelineStoppedException|The pipeline has been stopped|SYNC_CANCELLED_BY_USER') {
                Set-Status "Cancelled" ([System.Drawing.Color]::Gray)
                Log "Sync cancelled."
            } else {
                Set-Status "Error" ([System.Drawing.Color]::DarkRed)
                Log $detail
            }
        }
        finally {
            try { if ($script:SyncPS) { $script:SyncPS.Dispose() } } catch {}
            try { if ($script:SyncPool) { $script:SyncPool.Close(); $script:SyncPool.Dispose() } } catch {}

            $script:SyncPS = $null
            $script:SyncPool = $null
            $script:SyncHandle = $null

            Set-UiRunningState $false
            Update-RenameButtonState -AfterSync
        }
    }
})

# =====================================================
# Width/Height contract helpers
# - Compute compact minimum width from COLLAPSED UI only
# - Lock min width forever (prevents clipping & prevents "width jump" on expand)
# - Expanding details may increase height, never width
# =====================================================
$script:CollapsedMinSize     = $null
$script:LockedMinWidth       = $null
$script:ExpandedMinHeight    = $null
$script:LastExpandedHeight   = $null

function Get-NonClientSize {
    return New-Object Drawing.Size(
        ($form.Width  - $form.ClientSize.Width),
        ($form.Height - $form.ClientSize.Height)
    )
}

function Compute-CollapsedMinimum {
    # Ensure details are hidden for measurement (collapsed UI only)
    $detailsPanel.Visible = $false
    $root.RowStyles[2].SizeType = [Windows.Forms.SizeType]::Absolute
    $root.RowStyles[2].Height   = 0
    $btnToggle.Text = "Show Details"

    # Make sure handles exist and layout is up-to-date
    $form.CreateControl() | Out-Null
    $form.PerformLayout()
    $headerTable.PerformLayout()
    $headerLeftFlow.PerformLayout()
    $headerRightFlow.PerformLayout()
    $statusTable.PerformLayout()
    $root.PerformLayout()

    $nc = Get-NonClientSize

    # Use the REAL preferred widths of header and status rows
    $minClientW = [Math]::Max($headerTable.PreferredSize.Width, $statusTable.PreferredSize.Width)

    # Collapsed minimum height is header + status
    $minClientH = $headerTable.PreferredSize.Height + $statusTable.PreferredSize.Height

    $minW = $minClientW + $nc.Width
    $minH = $minClientH + $nc.Height

    $script:CollapsedMinSize = New-Object Drawing.Size($minW, $minH)
    $script:LockedMinWidth   = $minW
}

function Compute-ExpandedMinimumHeight {
    # We avoid $detailsPanel.PreferredSize.Height because it can be unreliable when Dock=Fill in a Percent row.

    $form.CreateControl() | Out-Null

    # Force layout so PreferredSize values are accurate
    $headerTable.PerformLayout()
    $statusTable.PerformLayout()
    $overviewGroup.PerformLayout()
    $overviewGrid.PerformLayout()
    $logGroup.PerformLayout()
    $detailsLayout.PerformLayout()
    $root.PerformLayout()

    $nc = Get-NonClientSize

    # Collapsed client height: header + status
    $collapsedClientH = $headerTable.PreferredSize.Height + $statusTable.PreferredSize.Height

    # Details required height:
    # - detailsPanel padding
    # - overviewGroup preferred height
    # - log minimum height (you already set MinimumSize.Height)
    # - a small spacer for the overview/log margin gap (safe constant)
    $detailsPaddingH = $detailsPanel.Padding.Top + $detailsPanel.Padding.Bottom
    $overviewH       = $overviewGroup.PreferredSize.Height
    $logMinH         = [Math]::Max(180, $logGroup.MinimumSize.Height)  # keep consistent with your intent
    $gapH            = 8  # matches your overviewGroup bottom margin

    $expandedClientH = $collapsedClientH + $detailsPaddingH + $overviewH + $gapH + $logMinH

    $script:ExpandedMinHeight = $expandedClientH + $nc.Height
}

function Set-DetailsVisible {
    param([bool]$Show)

    if ($null -eq $script:CollapsedMinSize)     { Compute-CollapsedMinimum }
    if ($null -eq $script:ExpandedMinHeight)    { Compute-ExpandedMinimumHeight }

    if ($Show) {
        # Expand: show details; NEVER change width
        $detailsPanel.Visible = $true
        $root.RowStyles[2].SizeType = [Windows.Forms.SizeType]::Percent
        $root.RowStyles[2].Height   = 100
        $btnToggle.Text = "Hide Details"

        # Lock minimum width forever; raise minimum height while expanded
        $form.MinimumSize = New-Object Drawing.Size($script:LockedMinWidth, $script:ExpandedMinHeight)

        # Grow HEIGHT only if needed (or restore last expanded height)
        $targetH = $script:ExpandedMinHeight
        if ($script:LastExpandedHeight -and $script:LastExpandedHeight -gt $targetH) {
            $targetH = $script:LastExpandedHeight
        }

        if ($form.Height -lt $targetH) {
            $form.Size = New-Object Drawing.Size($form.Width, $targetH)  # width unchanged
        }
    }
    else {
        # Remember expanded height for next time
        if ($detailsPanel.Visible) {
            $script:LastExpandedHeight = $form.Height
        }

        # Collapse: hide details; NEVER change width
        $detailsPanel.Visible = $false
        $root.RowStyles[2].SizeType = [Windows.Forms.SizeType]::Absolute
        $root.RowStyles[2].Height   = 0
        $btnToggle.Text = "Show Details"

        # Restore compact minimum height; keep locked min width
        $form.MinimumSize = New-Object Drawing.Size($script:LockedMinWidth, $script:CollapsedMinSize.Height)

        # Snap down HEIGHT only (width unchanged)
        $form.Size = New-Object Drawing.Size($form.Width, $script:CollapsedMinSize.Height)
    }

    $form.PerformLayout()
}

# Toggle button
$btnToggle.Add_Click({
    Set-DetailsVisible -Show (-not $detailsPanel.Visible)
})

# =====================================================
# SYSINFO BUTTONS (behavior unchanged)
# =====================================================
$btnSysinfoOpen.Add_Click({
    $path = "C:\ProgramData\ITFlow\sysinfo_$($env:COMPUTERNAME).json"
    if (Test-Path $path) {
        Start-Process notepad.exe -ArgumentList "`"$path`""
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Sysinfo file not found:`r`n$path",
            "SysInfo",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

$btnSysinfoView.Add_Click({
    Show-SysInfoSummary
})

# =====================================================
# Helper UI builders (only if not already defined elsewhere)
# =====================================================
if (-not (Get-Command Add-Label -ErrorAction SilentlyContinue)) {
    function Add-Label {
        param(
            [Parameter(Mandatory=$true)]$Parent,
            [Parameter(Mandatory=$true)][string]$Text,
            [Parameter(Mandatory=$true)][int]$X,
            [Parameter(Mandatory=$true)][int]$Y
        )
        $l = New-Object Windows.Forms.Label
        $l.Text = $Text
        $l.AutoSize = $true
        $l.Location = New-Object Drawing.Point($X,$Y)
        $Parent.Controls.Add($l)
        return $l
    }
}

if (-not (Get-Command Add-Textbox -ErrorAction SilentlyContinue)) {
    function Add-Textbox {
        param(
            [Parameter(Mandatory=$true)]$Parent,
            [Parameter(Mandatory=$true)][int]$X,
            [Parameter(Mandatory=$true)][int]$Y,
            [int]$Width = 240,
            [switch]$Password
        )
        $t = New-Object Windows.Forms.TextBox
        $t.Location = New-Object Drawing.Point($X,$Y)
        $t.Width = $Width
        if ($Password) { $t.UseSystemPasswordChar = $true }
        $Parent.Controls.Add($t)
        return $t
    }
}

# =====================================================
# CONFIG DIALOG (Settings + Agent Options only)
# =====================================================
$btnConfig.Add_Click({
    if ($script:SyncRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "Sync is currently running. Please cancel or wait until it finishes before opening Config.",
            "Sync Running",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $toolTip = New-Object Windows.Forms.ToolTip

    $cForm = New-Object Windows.Forms.Form
    $cForm.Text = "Config"
    $cForm.Size = New-Object Drawing.Size(520,520)
    $cForm.StartPosition = 'CenterParent'
    $cForm.FormBorderStyle = 'FixedDialog'
    $cForm.MaximizeBox = $false
    $cForm.MinimizeBox = $false
    $cForm.ShowInTaskbar = $false

    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.Padding = New-Object Windows.Forms.Padding(12)
    $cForm.Controls.Add($panel)

    # ---- ITFlow Settings
    $gbItflow = New-Object Windows.Forms.GroupBox
    $gbItflow.Text = "ITFlow Settings"
    $gbItflow.Dock = 'Top'
    $gbItflow.Height = 150
    $gbItflow.Padding = New-Object Windows.Forms.Padding(10,20,10,10)
    $panel.Controls.Add($gbItflow)

    Add-Label $gbItflow "ITFlow Base URL:" 12 28 | Out-Null
    $tBase = Add-Textbox $gbItflow 150 25 330
    $tBase.Text = $Config.BaseUrl

    Add-Label $gbItflow "Client ID:" 12 62 | Out-Null
    $tCid = Add-Textbox $gbItflow 150 59 120
    $tCid.Text = $Config.ClientId

    Add-Label $gbItflow "API Key:" 12 96 | Out-Null
    $tKey = Add-Textbox $gbItflow 150 93 330 -Password
    $tKey.Text = $Config.ApiKey

    # ---- Agent Options (ONLY 3)
    $gbAgent = New-Object Windows.Forms.GroupBox
    $gbAgent.Text = "Agent Options"
    $gbAgent.Dock = 'Top'
    $gbAgent.Height = 110
    $gbAgent.Padding = New-Object Windows.Forms.Padding(10,20,10,10)
    $gbAgent.Margin = New-Object Windows.Forms.Padding(0,10,0,0)
    $panel.Controls.Add($gbAgent)

    $cbTickets = New-Object Windows.Forms.CheckBox
    $cbTickets.Text = "Create Tickets (GUI mode only)"
    $cbTickets.AutoSize = $true
    $cbTickets.Location = New-Object Drawing.Point(14,28)
    $cbTickets.Checked = $script:EnableTicketingGui
    $gbAgent.Controls.Add($cbTickets)

    $toolTip.SetToolTip(
        $cbTickets,
        "GUI mode default is OFF (reporting only).`r`nSilent mode always creates tickets."
    )

    $cbFollow = New-Object Windows.Forms.CheckBox
    $cbFollow.Text = "Follow Client Transfers"
    $cbFollow.AutoSize = $true
    $cbFollow.Location = New-Object Drawing.Point(14,52)
    $cbFollow.Checked = $AllowFollowClientTransfer
    $gbAgent.Controls.Add($cbFollow)

    $cbAuto = New-Object Windows.Forms.CheckBox
    $cbAuto.Text = "Auto-update ClientId on Transfer"
    $cbAuto.AutoSize = $true
    $cbAuto.Location = New-Object Drawing.Point(14,76)
    $cbAuto.Checked = $AutoUpdateClientIdOnTransfer
    $gbAgent.Controls.Add($cbAuto)

    # ---- User Assignment from Logon Activity
    $gbUser = New-Object Windows.Forms.GroupBox
    $gbUser.Text = "User Assignment"
    $gbUser.Dock = 'Top'
    $gbUser.Height = 155
    $gbUser.Padding = New-Object Windows.Forms.Padding(10,20,10,10)
    $gbUser.Margin = New-Object Windows.Forms.Padding(0,10,0,0)
    $panel.Controls.Add($gbUser)

    $cbAssign = New-Object Windows.Forms.CheckBox
    $cbAssign.Text = "Assign Contact from Logon Activity"
    $cbAssign.AutoSize = $true
    $cbAssign.Location = New-Object Drawing.Point(14,28)
    $cbAssign.Checked = $AssignContactFromLogons
    $gbUser.Controls.Add($cbAssign)

    $toolTip.SetToolTip($cbAssign, "Automatically assign ITFlow contact based on Windows Security Event log session duration.")

    Add-Label $gbUser "Lookback Days:" 14 60 | Out-Null
    $udLookback = New-Object Windows.Forms.NumericUpDown
    $udLookback.Minimum = 1
    $udLookback.Maximum = 365
    $udLookback.Value = $AssignContactLookbackDays
    $udLookback.Location = New-Object Drawing.Point(150, 58)
    $udLookback.Size = New-Object Drawing.Size(80, 20)
    $gbUser.Controls.Add($udLookback)
    $toolTip.SetToolTip($udLookback, "How far back to scan the Security log for logon activity.")

    Add-Label $gbUser "Half-life Days:" 250 60 | Out-Null
    $udHalfLife = New-Object Windows.Forms.NumericUpDown
    $udHalfLife.Minimum = 0
    $udHalfLife.Maximum = 365
    $udHalfLife.Value = $AssignContactHalfLifeDays
    $udHalfLife.Location = New-Object Drawing.Point(360, 58)
    $udHalfLife.Size = New-Object Drawing.Size(70, 20)
    $gbUser.Controls.Add($udHalfLife)
    $toolTip.SetToolTip($udHalfLife, "Recency weighting: recent usage counts more, so a device that changes hands re-assigns within a few half-lives. 0 = flat cumulative total (no decay).")

    Add-Label $gbUser "Allowed Domain:" 14 90 | Out-Null
    $tDomain = Add-Textbox $gbUser 150 87 330
    $tDomain.Text = $AssignContactAllowedDomain

    $toolTip.SetToolTip($tDomain, "Only consider users from this domain (e.g. COMPANY). Leave blank to allow all domains.")

    $cbVerbose = New-Object Windows.Forms.CheckBox
    $cbVerbose.Text = "Verbose Logging (debug)"
    $cbVerbose.AutoSize = $true
    $cbVerbose.Location = New-Object Drawing.Point(14, 120)
    $cbVerbose.Checked = $VerboseLogging
    $gbUser.Controls.Add($cbVerbose)

    $toolTip.SetToolTip($cbVerbose, "Enable detailed debug logging for event log analysis and contact matching.")

    # ---- Non-admin note (preferences may not persist)
    $lblNote = New-Object Windows.Forms.Label
    $lblNote.AutoSize = $true
    $lblNote.ForeColor = [System.Drawing.Color]::Gray
    $lblNote.Dock = 'Top'
    $lblNote.Margin = New-Object Windows.Forms.Padding(2,10,2,0)
    if (-not (Test-IsAdmin)) {
        $lblNote.Text = "Note: Not running as Administrator - Agent Options may not persist (HKLM write may fail)."
    } else {
        $lblNote.Text = ""
        $lblNote.Height = 0
    }
    $panel.Controls.Add($lblNote)
    $panel.Controls.SetChildIndex($lblNote, 0) | Out-Null

    # ---- Buttons
    $btnSave = New-Object Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Width = 90
    $btnSave.Height = 30
    $btnSave.Anchor = "Bottom,Right"
    $btnSave.Location = New-Object Drawing.Point(310, 440)
    $panel.Controls.Add($btnSave)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Width = 90
    $btnCancel.Height = 30
    $btnCancel.Anchor = "Bottom,Right"
$btnCancel.Location = New-Object Drawing.Point(405, 440)
$panel.Controls.Add($btnCancel)

$btnDefaults = New-Object Windows.Forms.Button
$btnDefaults.Text = "Defaults"
$btnDefaults.Width = 90
$btnDefaults.Height = 30
$btnDefaults.Anchor = "Bottom,Left"
$btnDefaults.Location = New-Object Drawing.Point(12, 440)
$panel.Controls.Add($btnDefaults)

$btnCancel.Add_Click({ $cForm.Close() })

$btnDefaults.Add_Click({
    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Reset all agent options, flags, and cache to defaults?`r`n`r`nITFlow connection settings (BaseUrl, ClientId, ApiKey) will be preserved.",
        "Reset to Defaults",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
        if (Test-Path $IniPath) {
            $content = [System.IO.File]::ReadAllText($IniPath)
            # Keep only the [ITFlow] section (strip everything after it)
            if ($content -match "(?ms)\[ITFlow\].*?(\r?\n\r?\n\[|\z)") {
                $keep = $matches[0]
                $keep = $keep -replace "(?ms)(\r?\n\r?\n\[).*$", ""
                Set-Content -Path $IniPath -Value $keep.Trim() -Encoding UTF8 -Force -ErrorAction SilentlyContinue
            }
        }
        # Reset checkboxes in dialog to defaults
        $cbTickets.Checked = $true
        $cbFollow.Checked = $true
        $cbAuto.Checked = $true
        $cbAssign.Checked = $false
        $udLookback.Value = 90
        $udHalfLife.Value = 14
        $tDomain.Text = ""
        $cbVerbose.Checked = $false
        Log "Config reset to defaults"
    }
})

$btnSave.Add_Click({
        try {
        $Config.BaseUrl  = $tBase.Text.Trim()
        $Config.ClientId = $tCid.Text.Trim()
        $Config.ApiKey   = $tKey.Text.Trim()

        $script:EnableTicketingGui     = [bool]$cbTickets.Checked
        $script:AllowFollowClientTransfer     = [bool]$cbFollow.Checked
        $script:AutoUpdateClientIdOnTransfer  = [bool]$cbAuto.Checked
        $script:AssignContactFromLogons       = [bool]$cbAssign.Checked
        $script:AssignContactLookbackDays     = [int]$udLookback.Value
        $script:AssignContactHalfLifeDays     = [int]$udHalfLife.Value
        $script:AssignContactAllowedDomain     = $tDomain.Text.Trim()
        $script:VerboseLogging                 = [bool]$cbVerbose.Checked
        # Re-sync silent ticket flags immediately (so in-memory state matches saved config)
        $script:EnableTicketingSilent = $script:EnableTicketingGui
        $script:EnableRenameFailureTicketing = $script:EnableTicketingGui

        $enc = Protect-String $Config.ApiKey
        # Write preferences to INI for portable mode fallback (merge, never destroy)
        $newIniContent = @"
[ITFlow]
BaseUrl=$($Config.BaseUrl)
ClientId=$($Config.ClientId)
ApiKey=$enc

[Preferences]
CreateTicketsGui=$(if ($script:EnableTicketingGui) { 1 } else { 0 })
FollowClientTransfers=$(if ($script:AllowFollowClientTransfer) { 1 } else { 0 })
AutoUpdateClientIdOnTransfer=$(if ($script:AutoUpdateClientIdOnTransfer) { 1 } else { 0 })
AssignContactFromLogons=$(if ($script:AssignContactFromLogons) { 1 } else { 0 })
AssignContactLookbackDays=$($script:AssignContactLookbackDays)
AssignContactHalfLifeDays=$($script:AssignContactHalfLifeDays)
AssignContactAllowedDomain=$($script:AssignContactAllowedDomain)
VerboseLogging=$(if ($script:VerboseLogging) { 1 } else { 0 })
"@
        try { Merge-IniSections -FilePath $IniPath -SectionNames @('ITFlow', 'Preferences') -NewContent $newIniContent } catch {
            Log "WARN: INI merge failed (file locked), config changes saved to memory only: $($_.Exception.Message)"
        }

        # Sync preferences to registry when installed/elevated
        if ($script:RegistryAllowed) {
            try {
                if (-not (Test-Path $RegPreferences)) { New-Item -Path $RegPreferences -Force | Out-Null }
                Set-ItemProperty -LiteralPath $RegPreferences -Name "CreateTicketsGui" -Value $(if ($script:EnableTicketingGui) { 1 } else { 0 }) -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "FollowClientTransfers" -Value $(if ($script:AllowFollowClientTransfer) { 1 } else { 0 }) -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "AutoUpdateClientIdOnTransfer" -Value $(if ($script:AutoUpdateClientIdOnTransfer) { 1 } else { 0 }) -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactFromLogons" -Value $(if ($script:AssignContactFromLogons) { 1 } else { 0 }) -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactLookbackDays" -Value $script:AssignContactLookbackDays -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactHalfLifeDays" -Value $script:AssignContactHalfLifeDays -Type DWord
                Set-ItemProperty -LiteralPath $RegPreferences -Name "AssignContactAllowedDomain" -Value $script:AssignContactAllowedDomain -Type String
                Set-ItemProperty -LiteralPath $RegPreferences -Name "VerboseLogging" -Value $(if ($script:VerboseLogging) { 1 } else { 0 }) -Type DWord
                Log "Preferences synced to registry"
            } catch {
                Log "WARN: Registry preference sync failed (non-fatal): $($_.Exception.Message)"
            }
        }

        Log "Config saved (GUI ticketing=$($script:EnableTicketingGui); followTransfers=$AllowFollowClientTransfer; autoUpdateClientId=$AutoUpdateClientIdOnTransfer; assignContact=$AssignContactFromLogons; lookbackDays=$AssignContactLookbackDays; allowedDomain=$($script:AssignContactAllowedDomain); verboseLogging=$($script:VerboseLogging))"
        Refresh-OverviewUI
        $cForm.Close()
        } catch {
            Log "ERROR saving config: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)", "Config Error",
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $cForm.ShowDialog($form) | Out-Null
})

# =====================================================
# BUTTON ACTIONS
# =====================================================
$btnInstall.Add_Click({
    $installDir = "C:\ProgramData\ITFlow"
    $installPath = Join-Path $installDir "ITFlow-Agent.ps1"

    # Self-elevate if needed
    if (-not (Test-IsAdmin)) {
        $wantsUninstall = $script:IsInstalled
        $verb = if ($wantsUninstall) { "Uninstall" } else { "Install" }
        $flag = if ($wantsUninstall) { "-Uninstall" } else { "-Install" }

        $resp = [System.Windows.Forms.MessageBox]::Show(
            "$verb requires administrator privileges. Restart as administrator?",
            "Elevation Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" $flag -TaskScriptPath `"$installPath`" -Worker" -ErrorAction Stop | Out-Null
                # Store intent in script scope for timer callback (avoids closure issues)
                $script:InstallPollIsUninstall = $wantsUninstall
                $script:InstallPollPath = $installPath
                $script:InstallPollCount = 0
                $script:InstallPollTimer = New-Object System.Windows.Forms.Timer
                $script:InstallPollTimer.Interval = 1000
                $script:InstallPollTimer.Add_Tick({
                    $script:InstallPollCount++
                    Update-InstallButton
                    if ($script:InstallPollIsUninstall -and -not $script:IsInstalled) {
                        $script:InstallPollTimer.Stop()
                        $script:InstallPollTimer.Dispose()
                        $script:InstallPollCount = 0
                        $script:InstallPollPath = $null
                        $script:InstallPollIsUninstall = $null
                        [System.Windows.Forms.MessageBox]::Show(
                            "Scheduled task, registry keys, and C:\ProgramData\ITFlow have been removed.",
                            "Uninstall Complete",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information
                        ) | Out-Null
                    } elseif (-not $script:InstallPollIsUninstall -and $script:IsInstalled) {
                        $script:InstallPollTimer.Stop()
                        $script:InstallPollTimer.Dispose()
                        $script:InstallPollCount = 0
                        $path = $script:InstallPollPath
                        $script:InstallPollPath = $null
                        $script:InstallPollIsUninstall = $null
                        [System.Windows.Forms.MessageBox]::Show(
                            "Agent installed to $path`r`nScheduled task created (runs at startup as SYSTEM).`r`n`r`nThe script at the original location is no longer needed by the task.",
                            "Install Complete",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information
                        ) | Out-Null
                    } elseif ($script:InstallPollCount -ge 120) {
                        $script:InstallPollTimer.Stop()
                        $script:InstallPollTimer.Dispose()
                        $script:InstallPollCount = 0
                        $script:InstallPollPath = $null
                        $verb = if ($script:InstallPollIsUninstall) { "Uninstall" } else { "Install" }
                        $script:InstallPollIsUninstall = $null
                        [System.Windows.Forms.MessageBox]::Show(
                            "$verb timed out after 2 minutes. Check the logs for details.",
                            "$verb Failed",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error
                        ) | Out-Null
                    }
                })
                $script:InstallPollTimer.Start()
            } catch {
                Log "Elevation failed: $($_.Exception.Message)"
            }
        }
        return
    }

    if ($script:IsInstalled) {
        # --- Uninstall ---
        try { Uninstall-ITFlowScheduledTask } catch { }
        try { Remove-Item -LiteralPath $RegRoot -Recurse -Force -ErrorAction Stop; Log "Registry keys removed" } catch { Log "Registry cleanup: $($_.Exception.Message)" }
        try { Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop; Log "ProgramData folder removed" } catch { Log "Folder cleanup: $($_.Exception.Message)" }
        Log "Agent uninstalled"
        Update-InstallButton
        [System.Windows.Forms.MessageBox]::Show(
            "Scheduled task, registry keys, and $installDir have been removed.",
            "Uninstall Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    # --- Install ---
    # Step 1: Write config to registry
    try {
        if (-not (Write-ConfigToRegistry)) {
            throw "Write-ConfigToRegistry returned false"
        }
        Log "Registry config written"
    } catch {
        Log "Registry config error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to write registry config. Administrator rights may be required.",
            "Install Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    # Step 2: Copy script to ProgramData
    try {
        # SECURITY (v7.5.5): same install-path hardening as the CLI -Install path.
        Protect-InstallPath -InstallDir $installDir
        Copy-Item -Path $PSCommandPath -Destination $installPath -Force -ErrorAction Stop
        Set-ITFlowHardenedAcl -Path $installPath | Out-Null
        Log "Script installed to $installPath (hardened ACL applied)"
    } catch {
        Log "Script copy failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to copy script to $installPath`r`n$($_.Exception.Message)",
            "Install Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    # Step 3: Install scheduled task (pointing to the ProgramData location)
    try {
        $savedTaskScriptPath = $TaskScriptPath
        $TaskScriptPath = $installPath
        Install-ITFlowScheduledTask | Out-Null
        $TaskScriptPath = $savedTaskScriptPath
        Log "Scheduled task installed"
    } catch {
        Log "Scheduled task install failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Config and script copied, but scheduled task install failed: $($_.Exception.Message)",
            "Install Partial",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    Update-InstallButton
    [System.Windows.Forms.MessageBox]::Show(
        "Agent installed to $installPath`r`nScheduled task created (runs at startup as SYSTEM).`r`n`r`nThe script at the original location is no longer needed by the task.",
        "Install Complete",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})

$btnTest.Add_Click({
    if ($script:SyncRunning) {
        Log "API test blocked: sync running."
        return
    }

    try {
        # ITFlow 26.08: a key inherits its user's module and client permissions, so
        # a single clients/read call no longer answers "can this key do the job".
        # An asset-sync key legitimately may not hold Clients read at all, which the
        # old test reported as a total failure.
        $clientIdForTest = try { [int]$Config.ClientId } catch { 0 }
        $caps = Test-ITFlowApiCapabilities -ConfiguredClientId $clientIdForTest

        foreach ($p in $caps.Probes) {
            $mark = if ($p.Ok) { "OK  " } else { "FAIL" }
            Log "API test [$mark] $($p.Name) - $($p.Note)"
        }

        $assetProbe = $caps.Probes | Where-Object { $_.Name -like 'Assets read*' } | Select-Object -First 1

        if ($caps.AuthFailed) {
            Set-Status "API key rejected - reissue required" ([System.Drawing.Color]::DarkRed)
            Log "API test failed: the key was rejected. ITFlow 26.08 deleted every pre-existing key, and keys issued since expire on a set date. Create a new key under Admin Settings > API Keys and save it here."
        }
        elseif ($assetProbe -and $assetProbe.Ok) {
            $failed = @($caps.Probes | Where-Object { -not $_.Ok })
            if ($failed.Count -eq 0) {
                Set-Status "API connection successful" ([System.Drawing.Color]::DarkGreen)
                Log "API test passed (all probes)"
            } else {
                Set-Status "API OK - limited permissions" ([System.Drawing.Color]::DarkOrange)
                Log "API test passed for asset sync, but $($failed.Count) capability probe(s) failed. The key's user is missing those module or client permissions; the features relying on them will be skipped."
            }
        }
        elseif ($assetProbe -and $assetProbe.Note -like 'permission denied (403)*') {
            Set-Status "API key valid - no asset permission" ([System.Drawing.Color]::DarkRed)
            Log "API test failed: the key authenticated but its user's role lacks Support module access for assets (read needs Read, sync needs Modify). Grant it under Admin > Roles - no new key is needed. $($assetProbe.Note)"
        }
        else {
            Set-Status "API test failed" ([System.Drawing.Color]::DarkRed)
            $why = if ($assetProbe) { $assetProbe.Note } else { "assets read probe did not run" }
            Log "API test failed: asset sync is not possible with this key - $why"
        }
    } catch {
        Set-Status "API test failed" ([System.Drawing.Color]::DarkRed)
        Log $_.Exception.Message
    }
})

$btnRun.Add_Click({
    if (-not $script:SyncRunning) {
        Start-SyncAsync
    } else {
        Cancel-SyncAsync
    }
})



# =====================================================
# STARTUP:
# - Start collapsed at computed compact minimum width/height
# - Width is locked; expand changes height only
# - No flicker
# =====================================================
$form.Opacity = 0
$form.Add_Shown({
    $form.BeginInvoke([Action]{
        Compute-CollapsedMinimum
        Compute-ExpandedMinimumHeight

        # Lock minimum width forever; start at collapsed min height.
        $form.MinimumSize = New-Object Drawing.Size($script:LockedMinWidth, $script:CollapsedMinSize.Height)
        $form.Size        = New-Object Drawing.Size($script:LockedMinWidth, $script:CollapsedMinSize.Height)

        $form.Opacity = 1
    }) | Out-Null
})

# =====================================================
# SHOW UI
# =====================================================


# =====================================================
# GUI STARTUP INIT (Added)
# -----------------------------------------------------
# Ensure a clean state at launch.
# =====================================================
$script:SyncRunning = $false
$script:CancelSyncRequested = $false
Set-UiRunningState -Running:$false

# Check for pending computer rename from a previous session
$startupPendingRename = Test-PendingComputerRename
if ($startupPendingRename) {
    Set-Status "Rename pending - reboot required" ([System.Drawing.Color]::DarkOrange)
    Log "Pending computer rename detected: '$startupPendingRename' - reboot required"
}

# Set install/uninstall button state based on whether scheduled task exists
Update-InstallButton

# Overview auto-refresh timer (30s, local fields only)
$script:OverviewTimer = New-Object System.Windows.Forms.Timer
$script:OverviewTimer.Interval = 30000
$script:OverviewTimer.Add_Tick({
    if (-not $script:SyncRunning) {
        Refresh-OverviewUI
    }
})
$script:OverviewTimer.Start()

# -----------------------------------------------------
# IMPORTANT: Worker runspaces must never show the GUI
# -----------------------------------------------------
if ($Worker) { return }

try {
    if (-not $Silent) {
        $form.ShowDialog() | Out-Null
    }
}
finally {
    # Stop timers to prevent lingering handles after form close
    try { $script:TailTimer.Stop(); $script:TailTimer.Dispose() } catch {}
    try { $script:PollTimer.Stop(); $script:PollTimer.Dispose() } catch {}
    try { $script:OverviewTimer.Stop(); $script:OverviewTimer.Dispose() } catch {}
    try { $script:InstallPollTimer.Stop(); $script:InstallPollTimer.Dispose() } catch {}
    try { $script:RenamePollTimer.Stop(); $script:RenamePollTimer.Dispose() } catch {}
    # Release mutex only in non-worker mode
    if (-not $Worker -and $script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch {}
        try { $script:mutex.Dispose() } catch {}
    }
}
