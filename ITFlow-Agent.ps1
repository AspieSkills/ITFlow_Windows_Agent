# =====================================================
# ITFlow PowerShell Agent
# version - 7.4.2
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

#===============================
#  Global Variables
#===============================

# Agent version
$AgentVersion = "7.4.2"

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
}


# Prevent duplicate Local vs ITFlow compare blocks per run
$script:LoggedLocalVsITFlow = $false

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

    $origClientId = [int]$Config.ClientId
    Write-AssetTransferLog -Serial $Inv.Serial -Hostname $Inv.Hostname `
        -ConfiguredClientId $origClientId -DiscoveredClientId $DiscoveredClientId -DiscoveredAssetId $DiscoveredAssetId

    if (-not $AllowFollowClientTransfer -or $DiscoveredClientId -le 0) {
        Log "WARNING: Serial '$($Inv.Serial)' exists in ITFlow under client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId). Aborting."
        if ($CreateTransferMismatchTicket) {
            $title = "[TRANSFER DETECTED] $($Inv.Hostname) | Serial: $($Inv.Serial) moved to client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
            $details = "Configured Client ID: $origClientId`nDiscovered Client ID: $DiscoveredClientId`nDiscovered Asset ID: $DiscoveredAssetId`nSerial: $($Inv.Serial)`nHostname: $($Inv.Hostname)`nBlocked: AllowFollowClientTransfer=$false`n`n---`nDevice specification`n----------------------`n$DeviceSpec"
            Create-ITFlowTicket -Title $title -ClientId $origClientId -AssetId $DiscoveredAssetId -Details $details | Out-Null
        }
        return [pscustomobject]@{ Followed = $false }
    }

    if ($EnableTicketingSilent) {
        $title = "[TRANSFER DETECTED] $($Inv.Hostname) | Serial: $($Inv.Serial) moved to client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
        $details = "Original Client ID: $origClientId`nDiscovered Client ID: $DiscoveredClientId`nDiscovered Asset ID: $DiscoveredAssetId`nSerial: $($Inv.Serial)`nHostname: $($Inv.Hostname)`n`n---`nDevice specification`n----------------------`n$DeviceSpec"
        Create-ITFlowTicket -Title $title -ClientId $origClientId -AssetId $DiscoveredAssetId -Details $details | Out-Null
    }

    $script:LastRunState.TransferFollowed = $true

    if ($AutoUpdateClientIdOnTransfer -and $DiscoveredClientId -ne $origClientId) {
        Log "Auto-update enabled: persisting ClientId change $origClientId -> $DiscoveredClientId"
        $persistOk = Set-ConfiguredClientId -NewClientId $DiscoveredClientId
        if ($persistOk) { $script:LastRunState.ClientIdAutoUpdated = $true }
    }

    if ($EnableTicketingSilent) {
        $title = "[TRANSFER FOLLOWED] $($Inv.Hostname) | Serial: $($Inv.Serial) now in client_id=$DiscoveredClientId (asset_id=$DiscoveredAssetId)"
        $details = "Original Client ID: $origClientId`nNew Client ID: $DiscoveredClientId`nAsset ID: $DiscoveredAssetId`nSerial: $($Inv.Serial)`nHostname: $($Inv.Hostname)`nAuto-Update: $($AutoUpdateClientIdOnTransfer)`n`n---`nDevice specification`n----------------------`n$DeviceSpec"
        Create-ITFlowTicket -Title $title -ClientId $DiscoveredClientId -AssetId $DiscoveredAssetId -Details $details | Out-Null
    }

    $script:CurrentAssetId = $DiscoveredAssetId
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
        $uri = "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&client_id=$EffectiveClientId&asset_name=$DesiredHostname"
        $resp = Invoke-ITFlowChecked GET $uri $null "Asset name duplicate check"

        if ($resp -and "$($resp.success)" -eq "True" -and $resp.count -gt 0) {
            $others = @($resp.data | Where-Object { [int]$_.asset_id -ne $CurrentAssetId })
            if ($others.Count -gt 0) {
                return [pscustomobject]@{
                    IsDuplicate = $true
                    Count       = $resp.count
                    OtherAssetIds = ($others | ForEach-Object { [int]$_.asset_id })
                    OtherAssetSerials = ($others | ForEach-Object { [string]$_.serial })
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

        # 3) info (Notes) - full device specification block
        if ($DeviceSpec) {
            $infoValue = $DeviceSpec
            if ($LastCheckIn) { $infoValue += "`r`n`r`nLast Check-In: $LastCheckIn" }
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
        Create-ITFlowTicket -Title $title -ClientId $ClientId -Serial $Serial -Details $DeviceSpec | Out-Null
        Set-TicketFlag $regName | Out-Null
        Log "Device report ticket created for '$Serial'"
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

# =====================================================
# Test for Elevation
# =====================================================
function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
            try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch {
                Start-Sleep -Milliseconds 200
                try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
            }
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

        Set-ItemProperty -LiteralPath $RegRoot -Name "BaseUrl"  -Value $Config.BaseUrl
        Set-ItemProperty -LiteralPath $RegRoot -Name "ClientId" -Value $Config.ClientId
        Set-ItemProperty -LiteralPath $RegRoot -Name "ApiKey"   -Value (Protect-String $Config.ApiKey)

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

function Resolve-AssetIdBySerial {
    param(
        [Parameter(Mandatory=$true)][string]$Serial,
        [Parameter(Mandatory=$true)][int]$ClientId
    )

    try {
        $uri = "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&client_id=$ClientId&asset_serial=$Serial"
        $resp = Invoke-ITFlowChecked GET $uri $null "Resolve asset_id by serial"

        if ($resp -and "$($resp.success)" -eq "True" -and $resp.count -gt 0 -and $resp.data -and $resp.data[0].asset_id) {
            return [int]$resp.data[0].asset_id
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
            if ($raw -match "(?ms)\[$section\].*?^$Name=([^\r\n]+)") { return $matches[1].Trim() }
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
    if ($content -match "(?ms)\[$section\]") {
        if ($content -match "(?m)^$Name$MatchPattern") { $content = $content -replace "(?m)^$Name$MatchPattern", "$Name=$Value" }
        else { $content = $content -replace "(?m)(\[$section\])", "`$1`r`n$Name=$Value" }
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n[$section]`r`n$Name=$Value"
    }
    try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch {
        Start-Sleep -Milliseconds 200
        try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
    }
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
            $line = Select-String -Path $IniPath -Pattern "^$Name=\d+$" | Select-Object -First 1 -ErrorAction SilentlyContinue
            if ($line) { $val = ($line.Line -split '=')[1]; if ($val -match '^\d+$') { return [int]$val } }
        } catch { }
    }
    return $Default
}

function Set-PreferenceDword {
    param([string]$Name, [int]$Value)
    Write-RegDword -Path $RegPreferences -Name $Name -Value $Value
    Log "Preference saved: $Name=$Value"
}

function Get-PreferenceString {
    param([string]$Name, [string]$Default = "")
    $v = Read-RegValue -Path $RegPreferences -Name $Name
    if ($null -ne $v) { return (Normalize-Value $v) }
    return $Default
}

function Set-PreferenceString {
    param([string]$Name, [string]$Value)
    Write-RegString -Path $RegPreferences -Name $Name -Value $Value
    Log "Preference saved: $Name=$Value"
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
            return ($raw -match "(?ms)\[TicketFlags\].*?^$Name=1")
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
    if ($content -match "(?ms)\[TicketFlags\]") {
        if ($content -match "(?m)^$Name=\d+$") { $content = $content -replace "(?m)^$Name=\d+$", "$Name=1" }
        else { $content = $content -replace "(?m)(\[TicketFlags\])", "`$1`r`n$Name=1" }
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n[TicketFlags]`r`n$Name=1"
    }
    try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
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
            $content = $content -replace "(?m)^$Name=.*`r?`n", ""
            $content = $content -replace "`r`n`r`n\[TicketFlags\]`r`n$", ""
            try { Set-Content -Path $IniPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
        }
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

    try {
        Set-Content -Path $FilePath -Value $existing -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        Start-Sleep -Milliseconds 200
        Set-Content -Path $FilePath -Value $existing -Encoding UTF8 -Force -ErrorAction Stop
    }
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

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else {
    Split-Path -Parent $MyInvocation.MyCommand.Definition
}
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
        $null = New-Item -ItemType Directory -Path $LogRoot -Force -ErrorAction SilentlyContinue
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
        $reg = Get-ItemProperty $RegistryBasePath

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
# INVENTORY
# =====================================================
function Get-PrimaryMAC {
    $nic = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.MACAddress } |
        Select-Object -First 1
    if ($nic) { ($nic.MACAddress -replace '-',':').ToUpper() } else { $null }
}

function Get-PrimaryIP {
    $ips = Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.IPAddress } |
        ForEach-Object {
            $_.IPAddress | Where-Object {
                $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and
                $_ -notlike '169.*' -and
                $_ -ne '127.0.0.1'
            }
        }

if ($ips) { $ips | Select-Object -First 1 } else { $null }
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
        OS       = if ($OperatingSystem) { $OperatingSystem.Caption } else { (Get-CimInstance Win32_OperatingSystem).Caption }
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

        $laptopChassis  = @(8,9,10,11,12,14,18,21)
        $desktopChassis = @(3,4,5,6,7,15,16)

        if ($chassis | Where-Object { $laptopChassis -contains $_ })  { return "Laptop"  }
        if ($chassis | Where-Object { $desktopChassis -contains $_ }) { return "Desktop" }

        if ($model -match "Book|Notebook|Laptop|Ultrabook|ThinkPad|Latitude|EliteBook|ProBook") { return "Laptop" }
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

function Get-DisplayInfo {
    # EDID-based: model/name + physical size. Resolution is best-effort (typically primary/current).
    $displays = @()

    $monId = $null
    $monSize = $null
    try { $monId = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue } catch { }
    try { $monSize = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue } catch { }

    # Current resolution snapshot (best-effort)
    $resW = $null
    $resH = $null
    try {
        $video = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
        if ($video) {
            $primary = $video | Sort-Object CurrentHorizontalResolution -Descending | Select-Object -First 1
            $resW = $primary.CurrentHorizontalResolution
            $resH = $primary.CurrentVerticalResolution
        }
    } catch { }

    $sizeByInstance = @{}
    if ($monSize) {
        foreach ($s in $monSize) { $sizeByInstance[$s.InstanceName] = $s }
    }

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

            $displays += [pscustomobject]@{
                FriendlyName     = if ([string]::IsNullOrWhiteSpace($friendly)) { $null } else { $friendly }
                Manufacturer     = if ([string]::IsNullOrWhiteSpace($mfg)) { $null } else { $mfg }
                Model            = if ([string]::IsNullOrWhiteSpace($prod)) { $null } else { $prod }
                Serial           = if ([string]::IsNullOrWhiteSpace($serial)) { $null } else { $serial }
                SizeInches       = $diagIn
                NativeResolution = if ($resW -and $resH) { [pscustomobject]@{ Width = $resW; Height = $resH } } else { $null }
            }
        }
    }

    # Fallback when EDID isn't available
    if ($displays.Count -eq 0) {
        if ($resW -and $resH) {
            $displays += [pscustomobject]@{
                FriendlyName     = $null
                Manufacturer     = $null
                Model            = $null
                Serial           = $null
                SizeInches       = $null
                NativeResolution = [pscustomobject]@{ Width = $resW; Height = $resH }
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
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem

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

function Write-LocalSysInfoFromSnapshot {
    param(
        [Parameter(Mandatory=$true)] $Snapshot,
        [int]$Keep = 20
    )

    $hostname   = $env:COMPUTERNAME
    $root       = $script:SysInfoRoot
    $archiveDir = $script:SysInfoArchiveDir

    if (-not (Test-Path $root))       { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $archiveDir)) { New-Item -Path $archiveDir -ItemType Directory -Force | Out-Null }

    $currentFile = Join-Path $root "sysinfo_$hostname.json"
    $tmpFile     = "$currentFile.tmp"

    $stamp       = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $archiveFile = Join-Path $archiveDir "sysinfo_$hostname`_$stamp.json"

    $json = $Snapshot | ConvertTo-Json -Depth 12

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
function Invoke-ITFlow {
    param($Method, $Uri, $Body = $null)

    try {
        if ($Body) {
            Invoke-RestMethod -Method $Method -Uri $Uri `
                -Body ($Body | ConvertTo-Json -Depth 6) `
                -ContentType "application/json" `
                -TimeoutSec 90 `
                -ErrorAction Stop
        } else {
            Invoke-RestMethod -Method $Method -Uri $Uri `
                -TimeoutSec 90 `
                -ErrorAction Stop
        }
    } catch {
        throw "HTTP request failed: $($_.Exception.Message)"
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
        Log "ITFlow API threw exception ($Action): $($_.Exception.Message)"
        throw "ITFlow API call threw ($Action): $($_.Exception.Message)"
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

        Log "ITFlow API returned failure ($Action): $msg"
        throw "ITFlow API failed ($Action): $msg"
    }
    Log "ITFlow API success: $Action (count=$($resp.count))"
    return $resp
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

    # Base payload
    $payload = @{
        api_key        = $Config.ApiKey
        client_id      = $ClientId
        ticket_subject = $Title
    }

    # Include ticket_details when provided (convert plaintext to HTML for web display)
    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $htmlDetails = $Details -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        $htmlDetails = $htmlDetails -replace "`r`n", "<br>" -replace "`n", "<br>"
        $payload.ticket_details = $htmlDetails
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

function Invoke-HostnameRenameSafe {
    param(
        [Parameter(Mandatory=$true)][string]$DesiredHostname,
        [switch]$Force
    )

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
                $ticketTitle = "[RENAME FAILED] $($env:COMPUTERNAME) -> $DesiredHostname | Serial: $($inv.Serial) | Error: $($_.Exception.Message)"
                try { $assetIdForTicket = $script:CurrentAssetId } catch { $assetIdForTicket = $null }
                Create-ITFlowTicket -Title $ticketTitle -ClientId $Config.ClientId -AssetId $assetIdForTicket -Details "Current Hostname: $($env:COMPUTERNAME)`nDesired Hostname: $DesiredHostname`nSerial: $($inv.Serial)`nError: $($_.Exception.Message)" | Out-Null
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
        [string]$DeviceSpec = ""
    )

    Log "Enrollment (create): no existing asset found for serial '$($Inv.Serial)' - creating new asset in client_id=$EffectiveClientId"
    Log ("Enrollment (create): payload name='{0}' type='{1}' make='{2}' model='{3}' os='{4}' ip='{5}' mac='{6}' status='{7}'" -f $Inv.Hostname,$DetectedAssetType,$Inv.Make,$Inv.Model,$Inv.OS,$Inv.IP,$Inv.MAC,$DefaultAssetStatus)

    try {
        $result = Invoke-ITFlowChecked POST "$($Config.BaseUrl)/api/v1/assets/create.php" @{
            api_key      = $Config.ApiKey
            client_id    = [int]$EffectiveClientId
            asset_name   = $Inv.Hostname
            asset_serial = $Inv.Serial
            asset_make   = $Inv.Make
            asset_model  = $Inv.Model
            asset_os     = $Inv.OS
            asset_mac    = $Inv.MAC
            asset_ip     = $Inv.IP
            asset_type   = $DetectedAssetType
            asset_status = $DefaultAssetStatus
        } "Asset create"
    } catch {
        Log "Asset create failed, checking for existing serial in other clients..."
        try {
            $globalLookup = Invoke-ITFlowChecked GET "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&asset_serial=$($Inv.Serial)" $null "Transfer lookup by serial"
            if ("$($globalLookup.success)" -eq "True" -and ($globalLookup.data -and $globalLookup.data.Count -gt 0)) {
                $moved = $globalLookup.data | Select-Object -First 1
                $discoveredClientId = [int](Normalize-Value $moved.asset_client_id)
                $discoveredAssetId  = [int](Normalize-Value $moved.asset_id)
                $followResult = Invoke-AssetTransferFollow -Inv $Inv -DiscoveredClientId $discoveredClientId -DiscoveredAssetId $discoveredAssetId -DeviceSpec $DeviceSpec
                if ($followResult.Followed) {
                    $EffectiveClientId = $followResult.DiscoveredClientId
                    $result = [pscustomobject]@{ success = "True"; data = @(@{ insert_id = $followResult.DiscoveredAssetId }) }
                } else {
                    $script:LastSyncOK = $false
                    return
                }
            } else {
                Log "Asset not found in configured client, checking for transferred copy..."
                $foundTransferred = $false
                try {
                    $transferLookup = Invoke-ITFlowChecked GET "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&asset_serial=$($inv.Serial)" $null "Transfer lookup by serial"
                    $foundTransferred = "$($transferLookup.success)" -eq "True" -and ($transferLookup.data -and $transferLookup.data.Count -gt 0)
                } catch {
                    Log "Transfer lookup: serial not found in any client"
                }
                if ($foundTransferred) {
                    $moved = $transferLookup.data | Select-Object -First 1
                    $discoveredClientId = [int](Normalize-Value $moved.asset_client_id)
                    $discoveredAssetId  = [int](Normalize-Value $moved.asset_id)
                    $followResult = Invoke-AssetTransferFollow -Inv $inv -DiscoveredClientId $discoveredClientId -DiscoveredAssetId $discoveredAssetId -DeviceSpec $DeviceSpec
                    if ($followResult.Followed) {
                        $EffectiveClientId = $followResult.DiscoveredClientId
                        $lookup = [pscustomobject]@{ success = "True"; data = @($moved) }
                    } else {
                        $script:LastSyncOK = $false
                        return
                    }
                } else {
                    Start-AssetEnrollment -Inv $inv -DetectedAssetType $DetectedAssetType -EffectiveClientId $EffectiveClientId -Details $Details -DeviceSpec $DeviceSpec
                }
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
        # Reset per run to prevent GUI session bleed
        # --- Cancellation checkpoint (Added) ---
        Throw-IfCancelRequested

    # =============================
    # 1) Interrogate Machine (once)
    # =============================
    $snapshot = Get-FullSnapshot -AgentVersion $AgentVersion

    # Build device specification block for tickets (preserved when asset is archived/deleted)
    $dsb = New-Object System.Text.StringBuilder
    if ($snapshot.CPU) {
        $null = $dsb.AppendLine("CPU")
        $null = $dsb.AppendLine("---")
        $null = $dsb.AppendLine("Name:       $($snapshot.CPU.Name)")
        $null = $dsb.AppendLine("Cores:      $($snapshot.CPU.CoreCount) / $($snapshot.CPU.LogicalCount)")
        $null = $dsb.AppendLine("Max MHz:    $($snapshot.CPU.MaxClockMHz)")
    }
    if ($snapshot.Memory -and $snapshot.Memory.TotalGB) {
        $null = $dsb.AppendLine("")
        $null = $dsb.AppendLine("Memory")
        $null = $dsb.AppendLine("------")
        $null = $dsb.AppendLine("Total GB:   $($snapshot.Memory.TotalGB)")
    }
    if ($snapshot.Storage -and $snapshot.Storage.Totals) {
        $null = $dsb.AppendLine("")
        $null = $dsb.AppendLine("Storage")
        $null = $dsb.AppendLine("-------")
        $null = $dsb.AppendLine("Physical:   $($snapshot.Storage.Totals.PhysicalTotalGB) GB")
        $null = $dsb.AppendLine("Volumes:    $($snapshot.Storage.Totals.VolumeTotalGB) GB")
        if ($snapshot.Storage.PhysicalDisks -and $snapshot.Storage.PhysicalDisks.Count -gt 0) {
            $null = $dsb.AppendLine("Disks:      $($snapshot.Storage.PhysicalDisks.Count)")
            foreach ($disk in $snapshot.Storage.PhysicalDisks) {
                $null = $dsb.AppendLine("")
                $null = $dsb.AppendLine("  Model:      $($disk.Model)")
                if ($disk.Serial) { $null = $dsb.AppendLine("  Serial:     $($disk.Serial)") }
                $null = $dsb.AppendLine("  Size:       $([math]::Round($disk.SizeBytes / 1GB, 2)) GB")
                $null = $dsb.AppendLine("  Media:      $($disk.MediaType)")
                if ($disk.HealthStatus) { $null = $dsb.AppendLine("  Health:     $($disk.HealthStatus)") }
            }
        }
    }
    if ($snapshot.Displays -and $snapshot.Displays.Count -gt 0) {
        $null = $dsb.AppendLine("")
        $null = $dsb.AppendLine("Displays")
        $null = $dsb.AppendLine("--------")
        foreach ($display in $snapshot.Displays) {
            $null = $dsb.AppendLine("")
            if ($display.FriendlyName) { $null = $dsb.AppendLine("  Name:       $($display.FriendlyName)") }
            if ($display.Manufacturer) { $null = $dsb.AppendLine("  Make:       $($display.Manufacturer)") }
            if ($display.Model) { $null = $dsb.AppendLine("  Model:      $($display.Model)") }
            if ($display.Serial) { $null = $dsb.AppendLine("  Serial:     $($display.Serial)") }
            if ($display.SizeInches) { $null = $dsb.AppendLine("  Size:       $($display.SizeInches) inches") }
            if ($display.NativeResolution) {
                $null = $dsb.AppendLine("  Resolution: $($display.NativeResolution.Width) x $($display.NativeResolution.Height)")
            }
        }
    }
    if ($snapshot.Network -and $snapshot.Network.Adapters) {
        $null = $dsb.AppendLine("")
        $null = $dsb.AppendLine("Network")
        $null = $dsb.AppendLine("-------")
        foreach ($adapter in $snapshot.Network.Adapters) {
            $null = $dsb.AppendLine("")
            $null = $dsb.AppendLine("  Name:       $($adapter.Name)")
            if ($adapter.InterfaceDescription -and $adapter.InterfaceDescription -ne $adapter.Name) {
                $null = $dsb.AppendLine("  Desc:       $($adapter.InterfaceDescription)")
            }
            $null = $dsb.AppendLine("  Status:     $($adapter.Status)")
            $null = $dsb.AppendLine("  MAC:        $($adapter.MacAddress)")
            if ($adapter.LinkSpeed) { $null = $dsb.AppendLine("  Speed:      $($adapter.LinkSpeed)") }
            if ($adapter.Ips -and $adapter.Ips.Count -gt 0) {
                foreach ($ip in $adapter.Ips) {
                    $null = $dsb.AppendLine("  IP:         $($ip.IPAddress) /$($ip.PrefixLength) ($($ip.AddressFamily))")
                    if ($ip.DefaultGateway) { $null = $dsb.AppendLine("  Gateway:    $($ip.DefaultGateway)") }
                }
            }
        }
    }
    $DeviceSpec = $dsb.ToString()

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

    # Effective client_id for this run (may change if asset was transferred)
    $EffectiveClientId = [int]$Config.ClientId


    # Reset per-run UI state (ALWAYS do this once per run)
    $script:LastRunState.TransferFollowed     = $false
    $script:LastRunState.ClientIdAutoUpdated  = $false


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
                Invoke-ITFlowChecked GET "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&limit=1" $null "Connectivity probe" | Out-Null
                $connected = $true
                $elapsed = (Get-Date) - $startTime
                Log "ITFlow reachable after ${attempt} attempt(s) (elapsed: $([int]$elapsed.TotalSeconds)s)"
                break
            }
            catch {
                Throw-IfCancelRequested
                Log "ITFlow not reachable on attempt ${attempt}: $($_.Exception.Message)"
                if ($attempt -lt $maxAttempts) {
                    Log "Retrying in ${sleepSeconds} seconds..."
                    Start-SleepCancelAware -Seconds $sleepSeconds
                }
                $attempt++
            }
        }

        if (-not $connected) {
            $elapsed = (Get-Date) - $startTime
            Log "ITFlow unavailable after ${maxAttempts} attempts (elapsed: $([int]$elapsed.TotalSeconds)s) - aborting sync"
            $script:LastSyncOK = $false
            return
        }

        Log "Connectivity check passed, starting asset sync"

        # Lookup asset by serial in the configured client
        $lookup = Invoke-ITFlowChecked GET "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&client_id=$EffectiveClientId&asset_serial=$($inv.Serial)" $null "Asset lookup by serial+client"

        Log "Asset lookup returned data count: $(if ($null -ne $lookup.data) { $lookup.data.Count } else { 'null' })"

        # Loop allows one re-entry after transfer follow so rename+update happen in the same sync
        $retrySyncAfterTransfer = $false
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
                                    $detailStr = "Current Hostname: $currentHostname`nDesired Hostname: $DesiredHostname`nSerial: $currentSerial`nCurrent Asset ID: $currentAssetId`nConflicting Asset IDs: $otherIdsStr"
                                    Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$currentAssetId) -Details $detailStr | Out-Null
                                    Set-TicketFlag $renameConflictFlag | Out-Null
                                } else {
                                    Log "Rename conflict ticket already raised for '$DesiredHostname' - skipping"
                                }

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
                                    $detailStr = "Current Hostname: $currentHostname`nDesired Hostname: $DesiredHostname`nSerial: $currentSerial`nCurrent Asset ID: $currentAssetId`nAD DN: $adDN"
                                    Create-ITFlowTicket -Title $ticketTitle -ClientId $EffectiveClientId -AssetId ([int]$currentAssetId) -Details $detailStr | Out-Null
                                    Set-TicketFlag $renameConflictFlag | Out-Null
                                } else {
                                    Log "Rename conflict ticket already raised for '$DesiredHostname' - skipping"
                                }

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
                $detailStr = "Current Hostname: $currentHostname`nDesired Hostname: $DesiredHostname`nSerial: $currentSerial`nMode: GUI"
                if ($adCleanupLog) { $detailStr += "`nAD Cleanup: $adCleanupLog" }
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
            $pending = Test-PendingComputerRename
            if ($pending) {
                Log "Headless rename skipped: reboot-pending rename to '$pending' already exists"
            } else {
                if ($EnableTicketingSilent) {
                    if (-not (Test-TicketFlag $renameFlag)) {
                        $ticketTitle = "[RENAME] $currentHostname -> $DesiredHostname | Serial: $currentSerial"
                        $detailStr = "Current Hostname: $currentHostname`nDesired Hostname: $DesiredHostname`nSerial: $currentSerial`nMode: Headless"
                        if ($adCleanupLog) { $detailStr += "`nAD Cleanup: $adCleanupLog" }
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
                } else {
                    $ok = Invoke-HostnameRenameSafe -DesiredHostname $DesiredHostname -Force
                    if ($ok) {
                        Clear-QueuedRename
                        Set-AgentCacheValue -Name "RenameRetry_$DesiredHostname" -Value 0
                        if ($Reboot) {
                            Log "Reboot requested after rename - restarting in 60 seconds"
                            shutdown.exe /r /t 60 /c "ITFlow Agent: Rename to '$DesiredHostname' completed. Rebooting to apply."
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
                Set-AgentCacheValue -Name "SetAssetNameOnce" -Value 1
            }

            # =============================
            # ENFORCEMENT UPDATE (local truth)
            # =============================
            $update = @{
                api_key   = $Config.ApiKey
                client_id = [int]$EffectiveClientId
                asset_id  = [int]$asset.asset_id
            }

            $lastCheckIn = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $update.asset_description = "Last Check-In: $lastCheckIn"

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

            # Set asset_name once if blank
            if ($script:SetAssetNameOnce -or (Get-AgentCacheValue -Name "SetAssetNameOnce" -Default 0) -eq 1) { $update.asset_name = $inv.Hostname }

            # ===== MAC/IP WRITE-ONLY =====
            # - Do NOT read/compare from ITFlow (API does not return these fields on your instance).
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
                $resp = Invoke-ITFlow POST "$($Config.BaseUrl)/api/v1/assets/update.php" $update
                Log ("Asset update API response: " + ($resp | ConvertTo-Json -Depth 4 -Compress))

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
                    }
                }
            }
        }
        $retrySyncAfterTransfer = $false
    }
    else {
        Log "Asset not found in configured client, checking for transferred copy..."
        $foundTransferred = $false
        try {
            $transferLookup = Invoke-ITFlowChecked GET "$($Config.BaseUrl)/api/v1/assets/read.php?api_key=$($Config.ApiKey)&asset_serial=$($inv.Serial)" $null "Transfer lookup by serial"
            $foundTransferred = "$($transferLookup.success)" -eq "True" -and ($transferLookup.data -and $transferLookup.data.Count -gt 0)
        } catch {
            Log "Transfer lookup: serial not found in any client"
        }
        if ($foundTransferred) {
            $moved = $transferLookup.data | Select-Object -First 1
            $discoveredClientId = [int](Normalize-Value $moved.asset_client_id)
            $discoveredAssetId  = [int](Normalize-Value $moved.asset_id)
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
            $sb = New-Object System.Text.StringBuilder
            $null = $sb.AppendLine("Device Information")
            $null = $sb.AppendLine("==================")
            $null = $sb.AppendLine("Hostname:   $($snapshot.Device.Hostname)")
            $null = $sb.AppendLine("Serial:     $($snapshot.Device.Serial)")
            $null = $sb.AppendLine("Make/Model: $($snapshot.Device.Make) / $($snapshot.Device.Model)")
            $null = $sb.AppendLine("OS:         $($snapshot.Device.OS)")
            $null = $sb.AppendLine("Type:       $($snapshot.Device.AssetType)")
            $null = $sb.AppendLine("MAC:        $($snapshot.Device.PrimaryMAC)")
            $null = $sb.AppendLine("IP:         $($snapshot.Device.PrimaryIP)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("Device specification")
            $null = $sb.AppendLine("--------------------")
            $null = $sb.Append($DeviceSpec)
            $enrollDetails = $sb.ToString()
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

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$resolvedPath`" -Silent -Rename -Worker" -WorkingDirectory (Split-Path $resolvedPath -Parent)
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
            try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { try { schtasks.exe /run /tn $TaskName *>$null 2>&1 } catch { Log "Task trigger failed: $($_.Exception.Message)" } }
        exit 0
    }

    if ($existingTask -and $installedVersion -and $installedVersion -ne $AgentVersion) {
        # Protect against downgrade: skip if installed version is newer
        try {
            $installedVer = [version]$installedVersion
            $currentVer = [version]$AgentVersion
            if ($installedVer -gt $currentVer) {
                Log "Skipping downgrade: installed v$installedVersion is newer than this script v$AgentVersion"
                exit 0
            }
        } catch {
            Log "Version comparison failed (non-fatal): installed='$installedVersion' current='$AgentVersion' - proceeding with update"
        }
        Log "Updating agent v$installedVersion -> v$AgentVersion..."
    } else {
        Log "Installing agent v$AgentVersion to $installPath..."
    }

    try { Write-ConfigToRegistry | Out-Null; Log "Registry config written" } catch { Log "Registry config write failed: $($_.Exception.Message)" }
    try { if (-not (Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory -Force | Out-Null }; Copy-Item -Path $PSCommandPath -Destination $installPath -Force -ErrorAction Stop; Log "Script copied to $installPath" } catch { Log "ERROR: Failed to copy script: $($_.Exception.Message)" }
    if (-not $TaskScriptPath) { $TaskScriptPath = $installPath }
    Install-ITFlowScheduledTask
    try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { schtasks.exe /run /tn $TaskName *>$null 2>&1 }
    Log "Scheduled task triggered for first sync"
    exit 0
}
if ($Uninstall) {
    Uninstall-ITFlowScheduledTask
    try { Remove-Item -LiteralPath "HKLM:\SOFTWARE\ITFlow" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath "C:\ProgramData\ITFlow" -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Log "ITFlow agent fully uninstalled"
    exit 0
}

# GUI ticket preference applies to all modes - read early for silent/worker contexts
$script:EnableTicketingGui = (Get-PreferenceDword -Name "CreateTicketsGui" -Default 1) -ne 0
# Sync silent ticket flags with the GUI preference so the checkbox controls all tickets
$EnableTicketingSilent = $script:EnableTicketingGui
$EnableRenameFailureTicketing = $script:EnableTicketingGui
# Read transfer/update preferences early too (worker doesn't reach the form section)
$AllowFollowClientTransfer = (Get-PreferenceDword -Name "FollowClientTransfers" -Default 1) -ne 0
$AutoUpdateClientIdOnTransfer = (Get-PreferenceDword -Name "AutoUpdateClientIdOnTransfer" -Default 1) -ne 0

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

    if ($Worker) { return } else { exit 0 }
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
$AutoUpdateClientIdOnTransfer  = (Get-PreferenceDword -Name "AutoUpdateClientIdOnTransfer" -Default 1) -ne 0

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

function Update-InstallButton {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $script:IsInstalled = [bool]$task
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

    # Self-elevate if needed
    if (-not (Test-IsAdmin)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Renaming the computer requires administrator privileges.`r`n`r`nClose this window and re-launch as Administrator, or run:`r`npowershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent -Rename",
            "Elevation Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

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

    $ok = Invoke-HostnameRenameSafe -DesiredHostname $target

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
    $cForm.Size = New-Object Drawing.Size(520,360)
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
    $btnSave.Location = New-Object Drawing.Point(310, 280)
    $panel.Controls.Add($btnSave)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Width = 90
    $btnCancel.Height = 30
    $btnCancel.Anchor = "Bottom,Right"
$btnCancel.Location = New-Object Drawing.Point(405, 280)
$panel.Controls.Add($btnCancel)

$btnDefaults = New-Object Windows.Forms.Button
$btnDefaults.Text = "Defaults"
$btnDefaults.Width = 90
$btnDefaults.Height = 30
$btnDefaults.Anchor = "Bottom,Left"
$btnDefaults.Location = New-Object Drawing.Point(12, 280)
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
        # Re-sync silent ticket flags immediately (so in-memory state matches saved config)
        $EnableTicketingSilent = $script:EnableTicketingGui
        $EnableRenameFailureTicketing = $script:EnableTicketingGui

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
"@
        try { Merge-IniSections -FilePath $IniPath -SectionNames @('ITFlow', 'Preferences') -NewContent $newIniContent } catch {
            Log "WARN: INI merge failed (file locked), config changes saved to memory only: $($_.Exception.Message)"
        }

        Log "Config saved (GUI ticketing=$($script:EnableTicketingGui); followTransfers=$AllowFollowClientTransfer; autoUpdateClientId=$AutoUpdateClientIdOnTransfer)"
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
        $resp = [System.Windows.Forms.MessageBox]::Show(
            "Install requires administrator privileges. Restart as administrator?",
            "Elevation Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            try { Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Install -TaskScriptPath `"$installPath`" -Worker" -ErrorAction Stop } catch {
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
        if (-not (Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $PSCommandPath -Destination $installPath -Force -ErrorAction Stop
        Log "Script installed to $installPath"
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
        Invoke-ITFlow GET "$($Config.BaseUrl)/api/v1/clients/read.php?api_key=$($Config.ApiKey)" | Out-Null
        Set-Status "API connection successful" ([System.Drawing.Color]::DarkGreen)
        Log "API test passed"
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
if (Get-Command Set-UiRunningState -ErrorAction SilentlyContinue) {
    Set-UiRunningState -Running:$false
}

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
    # Release mutex only in non-worker mode
    if (-not $Worker -and $script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch {}
        try { $script:mutex.Dispose() } catch {}
    }
}
