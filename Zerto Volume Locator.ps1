
# --- PowerCLI import & base configuration (VCF.PowerCLI preferred; fallback to VMware.PowerCLI) ---
Import-Module VCF.PowerCLI -ErrorAction SilentlyContinue
if (-not (Get-Module VCF.PowerCLI)) {
    Import-Module VMware.PowerCLI -ErrorAction Stop
}
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

# --- Prompt for vCenter ---
$vcServer = Read-Host "Enter vCenter FQDN or IP (e.g., vc01.domain.com or 10.0.0.25)"
if ([string]::IsNullOrWhiteSpace($vcServer)) {
    Write-Error "vCenter server value is empty. Please rerun and provide a valid FQDN or IP."
    return
}

# --- Reachability check (TCP 443) ---
Write-Host ("Validating connectivity to {0}..." -f $vcServer) -ForegroundColor Cyan
$reachable443 = $false
try { $reachable443 = Test-NetConnection -ComputerName $vcServer -Port 443 -InformationLevel Quiet } catch { $reachable443 = $false }
if (-not $reachable443) {
    Write-Error ("Cannot reach {0} on TCP 443. Check DNS/firewall and try again." -f $vcServer)
    return
}

# --- Choose authentication method ---
Write-Host ""
Write-Host "Select authentication method:" -ForegroundColor Yellow
Write-Host "  1) Prompt for username/password (recommended)"
Write-Host "  2) Use Windows pass-through (current user / SSO)"
Write-Host "  3) Use a saved credential (from $env:LOCALAPPDATA\PowerCLI\cred.xml)"
$authChoice = Read-Host "Enter 1, 2, or 3"

function Get-SavedCredential {
    $credPath = Join-Path $env:LOCALAPPDATA "PowerCLI\cred.xml"
    if (Test-Path $credPath) {
        try { return Import-Clixml -Path $credPath } catch { Write-Warning ("Failed to load saved credential: {0}" -f $_.Exception.Message) }
    }
    return $null
}
function Save-Credential([pscredential]$cred) {
    if (-not $cred) { return }
    $credDir = Join-Path $env:LOCALAPPDATA "PowerCLI"
    if (-not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir | Out-Null }
    $credPath = Join-Path $credDir "cred.xml"
    try { $cred | Export-Clixml -Path $credPath; Write-Host ("Credential saved to: {0}" -f $credPath) -ForegroundColor Green }
    catch { Write-Warning ("Could not save credential: {0}" -f $_.Exception.Message) }
}

$connectParams = @{ Server = $vcServer }
$vcCred = $null
switch ($authChoice) {
    '1' {
        $vcCred = Get-Credential -Message ("Enter vCenter credentials for {0}" -f $vcServer)
        if (-not $vcCred) { Write-Error "No credential was entered. Aborting."; return }
        $connectParams.Credential = $vcCred
        $save = Read-Host "Save this credential for reuse? (y/N)"
        if ($save -match '^(y|Y|yes)$') { Save-Credential -cred $vcCred }
    }
    '2' { Write-Host "Using Windows pass-through (current user)." -ForegroundColor Cyan }
    '3' {
        $vcCred = Get-SavedCredential
        if (-not $vcCred) {
            Write-Warning "No saved credential found. Falling back to prompt."
            $vcCred = Get-Credential -Message ("Enter vCenter credentials for {0}" -f $vcServer)
            if (-not $vcCred) { Write-Error "No credential was entered. Aborting."; return }
        }
        $connectParams.Credential = $vcCred
    }
    default {
        Write-Warning "Invalid choice. Defaulting to prompt."
        $vcCred = Get-Credential -Message ("Enter vCenter credentials for {0}" -f $vcServer)
        if (-not $vcCred) { Write-Error "No credential was entered. Aborting."; return }
        $connectParams.Credential = $vcCred
    }
}

# --- Connect ---
try {
    $vc = Connect-VIServer @connectParams -ErrorAction Stop
    Write-Host ("Connected to {0} as {1}" -f $vc.Name, $vc.User) -ForegroundColor Green
}
catch {
    Write-Error ("Connect-VIServer failed: {0}" -f $_.Exception.Message)
    return
}

# --- Output paths ---
$outCsv      = "C:\VM_Drive_to_vSphere_LUN_Map.csv"
$failLogPath = "C:\VM_Drive_to_vSphere_LUN_Failures.log"
if (Test-Path $outCsv) { Remove-Item $outCsv -Force -ErrorAction SilentlyContinue }
Set-Content -Path $failLogPath -Value '' -Encoding UTF8

# ------------------------------
# Helper: VMware-side disk inventory (Get-View), includes controller type
# ------------------------------
function Get-VMHardwareMap {
    param([VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$Vm)

    $vmView = Get-View -Id $Vm.Id
    $dev    = $vmView.Config.Hardware.Device

    # Include common controller types; SCSI used for joins, but we record others for context
    $controllers = $dev | Where-Object {
        $_.GetType().Name -match 'Virtual.*(SCSI|NVME|AHCI)Controller'
    }
    $disks = $dev | Where-Object { $_.GetType().Name -eq 'VirtualDisk' }

    $rows = @()
    foreach ($d in $disks) {
        $ctrl = $controllers | Where-Object { $_.Key -eq $d.ControllerKey }
        $ctrlType = if ($ctrl) { $ctrl.GetType().Name } else { $null }

        $bus   = if ($ctrl) { $ctrl.BusNumber } else { $null }
        $unit  = $d.UnitNumber

        # Build display ID strings using -f (avoids $var:other parsing errors)
        $idStr = if ($ctrlType -match 'SCSI') { "SCSI({0}:{1})" -f $bus, $unit } `
            elseif ($ctrlType -match 'NVME') { "NVMe({0}:{1})" -f $bus, $unit } `
            elseif ($ctrlType -match 'AHCI') { "SATA({0}:{1})" -f $bus, $unit } `
            else { "Ctrl({0}):Unit({1})" -f $bus, $unit }

        $backingTypeName = $d.Backing.GetType().Name
        $backingType     = if ($backingTypeName -like 'VirtualDiskRawDiskMapping*') {'RDM'} else {'VMDK'}

        $datastore   = $null
        $lunCanon    = $null
        $lunDisplay  = $null
        $lunCapGB    = $null

        if ($backingType -eq 'VMDK') {
            try {
                $dsRef    = $d.Backing.Datastore
                if ($dsRef) {
                    $dsView   = Get-View -Id $dsRef
                    $datastore = $dsView.Name
                }
            } catch {}
        }
        else {
            try {
                $lunUuid = $d.Backing.LunUuid
                $hostView = Get-View -Id $vmView.Runtime.Host
                $storSys  = Get-View -Id $hostView.ConfigManager.StorageSystem
                $scsiLuns = $storSys.StorageDeviceInfo.ScsiLun
                $lun      = $scsiLuns | Where-Object { $_.Uuid -eq $lunUuid }
                if ($lun) {
                    $lunCanon   = $lun.CanonicalName
                    $lunDisplay = $lun.DisplayName
                    $lunCapGB   = [math]::Round(([double]$lun.Capacity.Block * $lun.Capacity.BlockSize) / 1GB, 2)
                }
            } catch {}
        }

        $rows += [PSCustomObject]@{
            VMwareDisk     = $d.DeviceInfo.Label
            ControllerType = $ctrlType
            BusNumber      = $bus
            UnitNumber     = $unit
            SCSI_ID        = if ($ctrlType -match 'SCSI') { "SCSI({0}:{1})" -f $bus, $unit } else { $null }  # join key when guest reports SCSI
            BackingType    = $backingType
            Datastore      = $datastore
            LunCanonical   = $lunCanon
            LunDisplay     = $lunDisplay
            LunCapGB       = $lunCapGB
        }
    }
    return ,$rows
}

# ------------------------------
# Guest script: volumes → JSON (Windows only)
# ------------------------------
$guestVolsScript = @'
Get-CimInstance Win32_Volume |
    Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter -ne $null } |
    Select-Object @{n="DriveLetter"; e={$_.DriveLetter}},
                  @{n="VolumeLabel"; e={$_.Label}},
                  @{n="FileSystem";  e={$_.FileSystem}},
                  @{n="VolumeSizeGB"; e={[math]::Round(([double]$_.Capacity)/1GB,2)}} |
    ConvertTo-Json -Depth 3
'@

# ------------------------------
# Guest script: drive → SCSI(bus:unit) → JSON (Windows, SCSI-centric)
# ------------------------------
$guestMapScript = @'
$diskDrives = Get-CimInstance Win32_DiskDrive | Where-Object {
    $_.Model -match "VMware|Virtual" -or $_.PNPDeviceID -match "^SCSI\\Disk&Ven_VMware"
}
$ldToPart   = Get-CimInstance Win32_LogicalDiskToPartition
$volumes    = Get-CimInstance Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter -ne $null }

$map = @()
foreach ($d in $diskDrives) {
    # For VMware SCSI virtual disks, SCSIBus/SCSITargetId are reliable join keys
    $bus    = $d.SCSIBus
    $target = $d.SCSITargetId
    $parts  = Get-CimAssociatedInstance -InputObject $d -Association Win32_DiskDriveToDiskPartition
    foreach ($p in $parts) {
        $lds = $ldToPart | Where-Object { $_.Antecedent -match [regex]::Escape($p.DeviceID) } | ForEach-Object { $_.Dependent }
        foreach ($ld in $lds) {
            $dl = $ld.DeviceID
            $vol = $volumes | Where-Object { $_.DriveLetter -eq $dl }
            if ($vol) {
                $map += [PSCustomObject]@{
                    DriveLetter = $dl
                    ScsiBus     = $bus
                    ScsiTarget  = $target
                }
            }
        }
    }
}
$map | ConvertTo-Json -Depth 3
'@

# ------------------------------
# Enumerate Windows VMs & build the mapping
# ------------------------------
$windowsVMs = Get-VM | Where-Object { $_.Guest.OSFullName -like "*Windows*" }
if (-not $windowsVMs) {
    Write-Warning "No Windows VMs found."
    Disconnect-VIServer -Confirm:$false | Out-Null
    return
}

$guestCred = Get-Credential -Message "Enter Windows guest admin credentials"

# Collect all rows for Export-Csv, and failures for log
$allRows   = New-Object System.Collections.Generic.List[object]
$failRows  = New-Object System.Collections.Generic.List[object]

$vmCount = $windowsVMs.Count
$idx = 0

foreach ($vm in $windowsVMs) {
    $idx++
    Write-Progress -Activity "Enumerating VM volumes" `
                   -Status "Processing $($vm.Name) ($idx of $vmCount)" `
                   -PercentComplete ([int](($0)))

    $vmName  = $vm.Name
    $esxiHost = $vm.VMHost.Name
    $cluster  = (Get-Cluster -VM $vm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

    # Tools & ESXi 902 checks
    $toolsStatus = $vm.ExtensionData.Guest.ToolsStatus
    if ($toolsStatus -eq "toolsNotRunning") {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason="VMware Tools not running (Invoke-VMScript requires Tools)" })
        continue
    }
    $port902 = Test-NetConnection -ComputerName $esxiHost -Port 902 -InformationLevel Quiet
    if (-not $port902) {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason="ESXi host '$esxiHost' not reachable on TCP 902 (Guest Ops require 902)" })
        continue
    }

    # VMware-side map
    $vmHw = Get-VMHardwareMap -Vm $vm

    # Guest volumes (JSON)
    $guestVolsJson = $null
    try {
        $guestVolsRes = Invoke-VMScript -VM $vm -ScriptText $guestVolsScript -GuestCredential $guestCred -ScriptType Powershell -ErrorAction Stop
        $guestVolsJson = $guestVolsRes.ScriptOutput.Trim()
    } catch {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason=("Failed to get guest volumes: {0}" -f $_.Exception.Message) })
        continue
    }

    # Parse guest volumes JSON
    $guestVols = $null
    try {
        $guestVols = ConvertFrom-Json -InputObject $guestVolsJson
        if ($guestVols -isnot [System.Collections.IEnumerable]) { $guestVols = @($guestVols) }
    } catch {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason=("Failed to parse guest volumes JSON: {0}" -f $_.Exception.Message) })
        continue
    }

    # Guest drive → SCSI map (JSON)
    $guestMapJson = $null
    try {
        $guestMapRes = Invoke-VMScript -VM $vm -ScriptText $guestMapScript -GuestCredential $guestCred -ScriptType Powershell -ErrorAction Stop
        $guestMapJson = $guestMapRes.ScriptOutput.Trim()
    } catch {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason=("Failed to get guest drive→SCSI map: {0}" -f $_.Exception.Message) })
        continue
    }

    # Parse map JSON
    $guestMap = $null
    try {
        $guestMap = ConvertFrom-Json -InputObject $guestMapJson
        if ($guestMap -isnot [System.Collections.IEnumerable]) { $guestMap = @($guestMap) }
    } catch {
        $failRows.Add([PSCustomObject]@{ VM=$vmName; Reason=("Failed to parse drive→SCSI map JSON: {0}" -f $_.Exception.Message) })
        continue
    }

    # Join: for each guest drive, find SCSI(bus:unit) and match to VMware disk + datastore/RDM info
    foreach ($vol in $guestVols) {
        $dl = $vol.DriveLetter
        $g  = $guestMap | Where-Object { $_.DriveLetter -eq $dl } | Select-Object -First 1

        $scsiId = $null
        $hw     = $null
        if ($g) {
            $scsiId = "SCSI({0}:{1})" -f $g.ScsiBus, $g.ScsiTarget
            $hw     = $vmHw | Where-Object { $_.SCSI_ID -eq $scsiId } | Select-Object -First 1
        }

        # Null-safe fields for PS 5.1
        $vmwareDisk = if ($hw) { $hw.VMwareDisk } else { $null }
        $backing    = if ($hw) { $hw.BackingType } else { $null }
        $dsName     = if ($hw) { $hw.Datastore } else { $null }
        $lunCanon   = if ($hw) { $hw.LunCanonical } else { $null }
        $lunDisp    = if ($hw) { $hw.LunDisplay } else { $null }
        $lunCapGB   = if ($hw) { $hw.LunCapGB } else { $null }
        $ctrlType   = if ($hw) { $hw.ControllerType } else { $null }

        $allRows.Add([PSCustomObject]@{
            VMName            = $vmName
            ESXiHost          = $esxiHost
            ClusterName       = $cluster
            GuestDriveLetter  = $dl
            VolumeLabel       = $vol.VolumeLabel
            FileSystem        = $vol.FileSystem
            VolumeSizeGB      = $vol.VolumeSizeGB
            VMwareDisk        = $vmwareDisk
            ControllerType    = $ctrlType
            SCSI_ID           = $scsiId               # present when guest supplied SCSI bus/target
            BackingType       = $backing              # VMDK or RDM
            Datastore         = $dsName
            LunCanonicalName  = $lunCanon
            LunDisplayName    = $lunDisp
            LunCapacityGB     = $lunCapGB
        })
    }
}

# --- Deduplicate by VMName+GuestDriveLetter (keeps first, preferring rows that have VMwareDisk populated) ---
$dedup = $allRows |
    Group-Object -Property VMName, GuestDriveLetter |
    ForEach-Object {
        # Prefer a row that resolved VMwareDisk; else take first
        $resolved = $_.Group | Where-Object { $_.VMwareDisk } | Select-Object -First 1
        if ($resolved) { $resolved } else { $_.Group | Select-Object -First 1 }
    }

# --- Export CSV (quoted, tidy, no type info) ---
$dedup |
    Sort-Object VMName, GuestDriveLetter |
    Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8

# --- Write failures log ---
if ($failRows.Count -gt 0) {
    $failRows | Sort-Object VM, Reason | Format-Table -AutoSize | Out-String | Set-Content -Path $failLogPath -Encoding UTF8
}

# --- Disconnect + final messages ---
try { Disconnect-VIServer -Confirm:$false | Out-Null } catch {}
Write-Host ("Drive → vSphere LUN map generated: {0}" -f $outCsv) -ForegroundColor Green
if ($failRows.Count -gt 0) {
    Write-Host ("Some VMs had issues. See: {0}" -f $failLogPath) -ForegroundColor Yellow
}
