<#
.SYNOPSIS
  VCF 9.1 Disconnected Software Depot Sync Tool
.DESCRIPTION
  Production PowerShell 7 / WPF UI wrapper for Broadcom VCF Download Tool.

  Rev1.1 / UI v1.2.4-full
  - Three download modes.
  - Fresh metadata/catalog sync before every download.
  - No silent curated 22-ID fallback after catalog sync.
  - Hardened VCFDT argument passing; no $args nested-function collision.
  - Generate ID parsing from stdout/stderr/vdt.log.
  - Chunked component uploads with state tracking.
.NOTES
  Requires PowerShell 7 on Windows.
#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:AppVersion = 'Rev1.1 / UI v1.2.4-full'
$script:ReadmeUrl = 'https://github.com/Achieve1molle/VCF-9.1-Disconnected-Software-Depot-Sync-Tool/blob/master/README.md'

try {
    $pwsh = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $pwsh) { $pwsh = 'pwsh.exe' }
} catch { $pwsh = 'pwsh.exe' }

if (-not $NoRelaunch -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath -NoRelaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# -----------------------------------------------------------------------------
# Component scope definitions
# -----------------------------------------------------------------------------
$script:BaseComponents = @(
    'VCENTER','SDDC_MANAGER_VCF','NSX_T_MANAGER','VSP','DEPOT_SERVICE',
    'VCF_LICENSE_SERVER','VCF_FLEET_LCM','VCF_SDDC_LCM','VIDB',
    'TELEMETRY_ACCEPTOR','VCFDT'
)

$script:AddOnComponents = @(
    'HCX','VRNI','VRLI','VROPS','VRA','VCF_OPS_CLOUD_PROXY',
    'VCFMS_METRICS_STORE','VCF_OBSERVABILITY_DATA_PLATFORM','VCF_SALT',
    'VCF_SALT_RAAS','VCF_SERVICE_VCD_MIGRATION_BACKEND'
)

# Upload grouping is component-based because VCFDT upload filters by component.
$script:UploadGroups = @(
    [pscustomobject]@{Name='vCenter alone'; Components=@('VCENTER')},
    [pscustomobject]@{Name='VCF Automation alone'; Components=@('VRA')},
    [pscustomobject]@{Name='VCF services runtime alone'; Components=@('VSP')},
    [pscustomobject]@{Name='VCF Operations for Networks alone'; Components=@('VRNI')},
    [pscustomobject]@{Name='VMware NSX alone'; Components=@('NSX_T_MANAGER')},
    [pscustomobject]@{Name='All others + add-ons'; Components=@(
        'SDDC_MANAGER_VCF','DEPOT_SERVICE','VCF_LICENSE_SERVER','VCF_FLEET_LCM',
        'VCF_SDDC_LCM','VIDB','TELEMETRY_ACCEPTOR','VROPS','VRLI',
        'VCF_OPS_CLOUD_PROXY','VCFMS_METRICS_STORE','VCF_OBSERVABILITY_DATA_PLATFORM',
        'VCF_SALT','VCF_SALT_RAAS','HCX','VCFDT','VCF_SERVICE_VCD_MIGRATION_BACKEND'
    )}
)

# -----------------------------------------------------------------------------
# Global UI/runtime state
# -----------------------------------------------------------------------------
$script:RunDir = $null
$script:LogFile = $null
$script:CurrentJob = $null
$script:JobTimer = $null
$script:HeartbeatTimer = $null
$script:IsBusy = $false

function New-RunDir {
    $base = 'D:\VCF91\Logs'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $script:RunDir = Join-Path $base ('VCFDepotSync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
    $script:LogFile = Join-Path $script:RunDir 'VCFDepotSync.log'
    '' | Set-Content -LiteralPath $script:LogFile -Encoding UTF8
}

function Write-UiLog {
    param([string]$Message,[string]$Level='INFO')
    $line = '[{0}][{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {}
    try {
        $script:window.Dispatcher.Invoke([Action]{
            $script:txtLog.AppendText($line + [Environment]::NewLine)
            if ($script:chkAutoScroll.IsChecked) {
                $script:txtLog.CaretIndex = $script:txtLog.Text.Length
                $script:txtLog.ScrollToEnd()
            }
        }) | Out-Null
    } catch {}
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes/1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes/1KB)) }
    return "$Bytes B"
}

function Get-ToolBat {
    $p = $script:txtToolPath.Text.Trim()
    if (Test-Path $p -PathType Leaf) { return $p }
    $bat = Join-Path $p 'vcf-download-tool.bat'
    if (Test-Path $bat -PathType Leaf) { return $bat }
    throw 'vcf-download-tool.bat not found. Select the VCF Download Tool bin folder or vcf-download-tool.bat.'
}

function Get-VdtLogPathFromBat([string]$Bat) {
    $bin = Split-Path -Parent $Bat
    $root = Split-Path -Parent $bin
    return (Join-Path $root 'log\vdt.log')
}

function Validate-ToolPath {
    $bat = Get-ToolBat
    $dir = Split-Path -Parent $bat
    $lcm = Join-Path $dir 'lcm-bundle-transfer-util.bat'
    if (-not (Test-Path $lcm)) { throw "Missing required file: $lcm" }
    Write-UiLog "Validated VCF Download Tool bin path: $dir"
    [System.Windows.MessageBox]::Show("Validated:`n$dir",'VCF Download Tool','OK','Information') | Out-Null
}

function Write-SecretFile {
    param([string]$Path,[string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path,$Value.Trim(),[Text.Encoding]::ASCII)
}

function Remove-StaleSecretFiles {
    foreach ($pat in @('vcfdt-ops-password*.txt','vcfdt-activation-code*.txt')) {
        foreach ($i in @(Get-ChildItem -Path $env:TEMP -Filter $pat -File -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue; Write-UiLog "Removed stale temp secret file: $($i.Name)" } catch {}
        }
    }
}

function Test-DownloadState {
    param([string]$Path,[string]$Mode,[string]$VcfVersion,[string]$Sku)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        return ($s.Status -eq 'Downloaded' -and $s.DownloadMode -eq $Mode -and $s.VcfVersion -eq $VcfVersion -and $s.Sku -eq $Sku)
    } catch { return $false }
}

function Write-DebugHeartbeat {
    try {
        $bat = Get-ToolBat
        $vdt = Get-VdtLogPathFromBat $bat
        if (Test-Path -LiteralPath $vdt) {
            $i = Get-Item -LiteralPath $vdt
            Write-UiLog ("DEBUG VCFDT log: size={0} modified={1}" -f (Format-Bytes $i.Length),$i.LastWriteTime.ToString('HH:mm:ss'))
        }
        foreach ($d in @($script:txtDownloadDir.Text.Trim(),$script:txtUploadDir.Text.Trim()) | Select-Object -Unique) {
            $wd = Join-Path $d 'workingDir'
            if (Test-Path -LiteralPath $wd) {
                foreach ($f in @(Get-ChildItem -LiteralPath $wd -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
                    Write-UiLog ("DEBUG workingDir: {0} size={1} modified={2}" -f $f.Name,(Format-Bytes $f.Length),$f.LastWriteTime.ToString('HH:mm:ss'))
                }
            }
        }
    } catch {}
}

function Start-Heartbeat {
    if ($script:HeartbeatTimer) { $script:HeartbeatTimer.Stop() }
    $script:HeartbeatTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:HeartbeatTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:HeartbeatTimer.Add_Tick({ if ($script:IsBusy) { Write-DebugHeartbeat } })
    $script:HeartbeatTimer.Start()
}

function Stop-Heartbeat {
    try { if ($script:HeartbeatTimer) { $script:HeartbeatTimer.Stop() } } catch {}
    $script:HeartbeatTimer = $null
}

function Set-Busy {
    param([bool]$Busy)
    $script:IsBusy = $Busy
    $script:window.Dispatcher.Invoke([Action]{
        foreach ($b in @($script:btnReadme,$script:btnValidateTool,$script:btnGenerateDepotId,$script:btnParseDepotId,$script:btnDownload,$script:btnConnect,$script:btnUpload,$script:btnCopyDepotId)) { $b.IsEnabled = -not $Busy }
        $script:btnStop.IsEnabled = $Busy
        if ($Busy) { $script:lblStatus.Content='Running'; $script:lblStatus.Foreground=[Windows.Media.Brushes]::DodgerBlue; Start-Heartbeat }
        else { Stop-Heartbeat; $script:lblStatus.Content='Ready'; $script:lblStatus.Foreground=[Windows.Media.Brushes]::LightGreen }
    }) | Out-Null
}

function Start-JobWithPolling {
    param([scriptblock]$ScriptBlock,[object[]]$ArgumentList,[string]$TaskName)
    if ($script:IsBusy) { throw 'A task is already running.' }
    Set-Busy $true
    Write-UiLog "Starting $TaskName"
    $script:CurrentJob = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $script:JobTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:JobTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:JobTimer.Add_Tick({
        try {
            $out = Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue
            foreach ($l in @($out)) { if ($null -ne $l) { Write-UiLog ([string]$l) } }
            if ($script:CurrentJob.State -in @('Completed','Failed','Stopped')) {
                $st = $script:CurrentJob.State
                Write-UiLog "$TaskName finished with job state: $st" $(if ($st -eq 'Completed') { 'INFO' } else { 'ERROR' })
                Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
                $script:CurrentJob = $null
                $script:JobTimer.Stop()
                Set-Busy $false
            }
        } catch { Write-UiLog $_.Exception.Message 'ERROR'; Set-Busy $false }
    })
    $script:JobTimer.Start()
}

function Stop-ActiveWork {
    Write-UiLog 'Stop requested by operator.' 'WARN'
    try {
        if ($script:JobTimer) { $script:JobTimer.Stop() }
        if ($script:CurrentJob) { Stop-Job $script:CurrentJob -ErrorAction SilentlyContinue; Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue; $script:CurrentJob=$null }
        $procs = Get-CimInstance Win32_Process -Filter "name='java.exe' or name='cmd.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'vcf-download-tool|lcm-bundle-transfer-util|DepotStore|workingDir|VCF_Download_Tool' }
        foreach ($p in @($procs)) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Write-UiLog "Stopped child process PID=$($p.ProcessId)" 'WARN' } catch {} }
    } finally { Set-Busy $false }
}

# -----------------------------------------------------------------------------
# Generate ID
# -----------------------------------------------------------------------------
function Start-GenerateDepotId {
    $bat = Get-ToolBat
    $dir = Split-Path -Parent $bat
    $vdt = Get-VdtLogPathFromBat $bat
    Set-Busy $true
    Write-UiLog 'Generating Software Depot ID and parsing stdout/stderr/vdt.log.'
    $script:CurrentJob = Start-Job -ArgumentList @($bat,$dir,$vdt) -ScriptBlock {
        param($bat,$dir,$vdt)
        function ParseGuid([string]$Text) {
            if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
            foreach ($Pattern in @('serviceId=([0-9a-fA-F-]{36})','Software depot ID:\s*([0-9a-fA-F-]{36})','Software Depot ID:\s*([0-9a-fA-F-]{36})','\b([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b')) {
                $m = [regex]::Match($Text,$Pattern)
                if ($m.Success) { return $m.Groups[1].Value }
            }
            return $null
        }
        function Invoke-VcfdtSimple([string[]]$ArgList) {
            $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$bat
            foreach ($x in $ArgList) { [void]$psi.ArgumentList.Add([string]$x) }
            $psi.WorkingDirectory=$dir; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=$true; $psi.CreateNoWindow=$true
            $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi; [void]$p.Start()
            try { 1..5 | ForEach-Object { $p.StandardInput.WriteLine('Y') } } catch {}
            $so=$p.StandardOutput.ReadToEnd(); $se=$p.StandardError.ReadToEnd(); $p.WaitForExit()
            [pscustomobject]@{ExitCode=[int]$p.ExitCode;StdOut=$so;StdErr=$se}
        }
        $found=$null; $last=9999
        foreach ($ArgList in @(@('configuration','generate','--software-depot-id'),@('configuration','generate','--software-depot-id','--ceip','DISABLE'))) {
            Write-Output ('Generate args: '+($ArgList -join ' '))
            $r=Invoke-VcfdtSimple -ArgList $ArgList
            $last=$r.ExitCode
            if ($r.StdOut) { Write-Output $r.StdOut }
            if ($r.StdErr) { Write-Output ('STDERR: '+$r.StdErr) }
            Write-Output ('Generate exit code: '+$r.ExitCode)
            $found=ParseGuid ($r.StdOut+"`n"+$r.StdErr)
            if ($found) { break }
        }
        if (-not $found -and (Test-Path $vdt)) { try { $found=ParseGuid (Get-Content $vdt -Raw) } catch {} }
        if ($found) { Write-Output ('GUID_FOUND:'+ $found); exit 0 }
        Write-Output 'ERROR: No Software Depot ID GUID parsed.'; exit $last
    }
    $script:JobTimer=[Windows.Threading.DispatcherTimer]::new()
    $script:JobTimer.Interval=[TimeSpan]::FromSeconds(1)
    $script:JobTimer.Add_Tick({
        try {
            $out=Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue
            foreach ($l in @($out)) {
                if ($null -eq $l) { continue }
                $s=[string]$l
                if ($s -match '^GUID_FOUND:([0-9a-fA-F-]{36})$') {
                    $guid=$Matches[1]
                    $script:txtDepotId.Text=$guid
                    [Windows.Clipboard]::SetText($guid)
                    Write-UiLog "Software Depot ID captured and copied to clipboard: $guid"
                    Start-Process "https://vcf.broadcom.com/vcf/clm/download-manager/register?serviceId=$guid"
                } else { Write-UiLog $s }
            }
            if ($script:CurrentJob.State -in @('Completed','Failed','Stopped')) {
                Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue
                $script:CurrentJob=$null
                $script:JobTimer.Stop()
                Set-Busy $false
            }
        } catch { Write-UiLog $_.Exception.Message 'ERROR'; Set-Busy $false }
    })
    $script:JobTimer.Start()
}

function Parse-DepotIdFromExistingLog {
    try {
        $bat=Get-ToolBat
        $vdt=Get-VdtLogPathFromBat $bat
        $txt=Get-Content -LiteralPath $vdt -Raw
        $m=[regex]::Matches($txt,'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($m.Count -lt 1) { throw 'No GUID found in vdt.log' }
        $guid=$m[$m.Count-1].Groups[1].Value
        $script:txtDepotId.Text=$guid
        [Windows.Clipboard]::SetText($guid)
        Write-UiLog "Parsed latest GUID from vdt.log: $guid"
    } catch { Write-UiLog $_.Exception.Message 'ERROR' }
}

# -----------------------------------------------------------------------------
# Download with mandatory fresh catalog sync
# -----------------------------------------------------------------------------
function Start-Download {
    $bat=Get-ToolBat
    $act=$script:txtActivationCode.Text.Trim()
    if (-not $act) { throw 'Activation code is required before downloading.' }
    $depot=$script:txtDownloadDir.Text.Trim()
    New-Item -ItemType Directory -Force -Path $depot | Out-Null
    $mode=[string]$script:cboDownloadMode.SelectedItem.Content
    $force=[bool]$script:chkForceRedownload.IsChecked
    $state=Join-Path $depot '.vcf-download-state.json'
    $vcf=$script:txtVcfVersion.Text.Trim()
    $sku=$script:txtSku.Text.Trim()
    if ((-not $force) -and (Test-DownloadState -Path $state -Mode $mode -VcfVersion $vcf -Sku $sku)) {
        Write-UiLog "SKIP: $mode already marked Downloaded. Enable Force re-download to run again."
        return
    }
    $af=Join-Path $env:TEMP ('vcfdt-activation-code-'+[guid]::NewGuid()+'.txt')
    Write-SecretFile $af $act
    Start-JobWithPolling -TaskName 'Download Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),$af,$depot,$state,$vcf,$sku,$mode,($script:BaseComponents|ConvertTo-Json -Compress),($script:AddOnComponents|ConvertTo-Json -Compress)) -ScriptBlock {
        param($bat,$dir,$secretFile,$depot,$statePath,$vcf,$sku,$mode,$baseJson,$addonJson)

        function Invoke-Vcfdt {
            param([string[]]$ArgList)
            Write-Output ('Download command args: '+($ArgList -join ' '))
            $psi=[Diagnostics.ProcessStartInfo]::new()
            $psi.FileName=$bat
            foreach($a in $ArgList){[void]$psi.ArgumentList.Add([string]$a)}
            $psi.WorkingDirectory=$dir
            $psi.UseShellExecute=$false
            $psi.RedirectStandardOutput=$true
            $psi.RedirectStandardError=$true
            $psi.RedirectStandardInput=$true
            $psi.CreateNoWindow=$true
            $p=[Diagnostics.Process]::new()
            $p.StartInfo=$psi
            [void]$p.Start()
            try { 1..30 | ForEach-Object { $p.StandardInput.WriteLine('Y') } } catch {}
            while(-not $p.StandardOutput.EndOfStream){Write-Output $p.StandardOutput.ReadLine()}
            while(-not $p.StandardError.EndOfStream){Write-Output ('ERROR: '+$p.StandardError.ReadLine())}
            $p.WaitForExit()
            Write-Output ('Exit code: '+$p.ExitCode)
            return [int]$p.ExitCode
        }

        function Get-ComponentHint {
            param([string]$PathText,[string[]]$KnownComponents)
            foreach ($c in $KnownComponents) {
                if ($PathText -match ('(?i)(^|[^A-Z0-9_])' + [regex]::Escape($c) + '([^A-Z0-9_]|$)')) { return $c }
            }
            return $null
        }

        function Get-CatalogBundleRecords {
            param([string]$CatalogPath,[string[]]$KnownComponents)
            $records=@()
            if (-not (Test-Path -LiteralPath $CatalogPath)) { return @() }
            $json=Get-Content -LiteralPath $CatalogPath -Raw
            $idMatches=[regex]::Matches($json,'(?is)"id"\s*:\s*"([0-9a-fA-F-]{36})"')
            foreach($m in $idMatches){
                $id=$m.Groups[1].Value
                $start=[Math]::Max(0,$m.Index-4000)
                $len=[Math]::Min(8000,$json.Length-$start)
                $ctx=$json.Substring($start,$len)
                $type='UNKNOWN'
                $tm=[regex]::Match($ctx,'(?is)"type"\s*:\s*"([A-Z_]+)"')
                if($tm.Success){$type=$tm.Groups[1].Value}
                $component=Get-ComponentHint -PathText $ctx -KnownComponents $KnownComponents
                $version=''
                $vm=[regex]::Match($ctx,'(?is)"(?:productVersion|version|componentVersion)"\s*:\s*"([^"]*9\.1[^"]*)"')
                if($vm.Success){$version=$vm.Groups[1].Value}
                $records += [pscustomobject]@{Id=$id;Type=$type;Component=$component;Version=$version}
            }
            return @($records | Sort-Object Id -Unique)
        }

        try {
            # Fresh catalog/manifest sync is mandatory every time Download Binary runs.
            $catalog=Join-Path $depot 'PROD\metadata\productVersionCatalog\v1\productVersionCatalog.json'
            Write-Output 'Refreshing VCFDT metadata/catalog before resolving download IDs.'
            $metadataArgs=@('metadata','download','--ceip','DISABLE','--depot-download-activation-code-file',$secretFile,'--depot-store',$depot)
            $metadataExit=Invoke-Vcfdt -ArgList $metadataArgs
            if($metadataExit -ne 0){
                Write-Output "WARN: metadata download with --ceip failed with exit code $metadataExit. Retrying metadata download without --ceip."
                $metadataArgs=@('metadata','download','--depot-download-activation-code-file',$secretFile,'--depot-store',$depot)
                $metadataExit=Invoke-Vcfdt -ArgList $metadataArgs
            }
            if($metadataExit -ne 0){ throw "Fresh metadata/catalog sync failed with exit code $metadataExit. Download stopped before binary ID resolution." }
            if(-not(Test-Path -LiteralPath $catalog)){ throw "Fresh metadata/catalog sync completed but productVersionCatalog.json was not found at $catalog. Download stopped." }
            Write-Output "Fresh catalog found: $catalog"

            $base=@($baseJson|ConvertFrom-Json)
            $addon=@($addonJson|ConvertFrom-Json)
            $known=@($base+$addon|Sort-Object -Unique)
            $records=@(Get-CatalogBundleRecords -CatalogPath $catalog -KnownComponents $known)
            if($records.Count -lt 1){ throw "Fresh catalog was found but no bundle IDs were parsed. Inspect productVersionCatalog.json." }

            if($mode -match '^Mode A'){
                $ids=@($records|Where-Object{$_.Type -eq 'INSTALL' -and $_.Component -in $base}|Select-Object -ExpandProperty Id -Unique)
                Write-Output "Mode A: selected base platform INSTALL IDs from fresh catalog. Count: $($ids.Count)."
            } elseif($mode -match '^Mode B'){
                $allowed=@($base+$addon|Sort-Object -Unique)
                $ids=@($records|Where-Object{$_.Type -eq 'INSTALL' -and $_.Component -in $allowed}|Select-Object -ExpandProperty Id -Unique)
                Write-Output "Mode B: selected base + add-on INSTALL IDs from fresh catalog. Count: $($ids.Count)."
            } else {
                $ids=@($records|Select-Object -ExpandProperty Id -Unique)
                Write-Output "Mode C: selected every bundle ID discovered in fresh catalog. Count: $($ids.Count)."
            }

            if($ids.Count -lt 1){ throw "Fresh catalog parsed, but no bundle IDs matched selected mode [$mode]. Try Mode C or inspect productVersionCatalog.json." }
            $ids=@($ids|Sort-Object -Unique)
            Write-Output "Fresh catalog mode selection complete. Final unique download ID count: $($ids.Count)."

            $chunkSize=25
            $fail=0
            for($i=0;$i -lt $ids.Count;$i+=$chunkSize){
                $end=[Math]::Min($i+$chunkSize-1,$ids.Count-1)
                $chunk=@($ids[$i..$end])
                Write-Output ("Downloading ID chunk {0}-{1} of {2}" -f ($i+1),($end+1),$ids.Count)
                $cmdArgs=@('binaries','download','--ceip','DISABLE','--depot-download-activation-code-file',$secretFile,'--id',($chunk -join ','),'--depot-store',$depot)
                $ec=Invoke-Vcfdt -ArgList $cmdArgs
                if($ec -ne 0){$fail++;Write-Output "WARN: chunk failed with exit code $ec"}
            }
            if($fail -gt 0){throw "$fail download chunk(s) failed."}
            $state=[ordered]@{Status='Downloaded';DownloadMode=$mode;VcfVersion=$vcf;Sku=$sku;IdCount=$ids.Count;Timestamp=(Get-Date).ToString('o')}
            $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-Output "Download state written: $statePath"
        } finally {
            try { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue; Write-Output 'Activation code temp file removed.' } catch {}
        }
    }
}

# -----------------------------------------------------------------------------
# Connectivity and upload
# -----------------------------------------------------------------------------
function Test-ConnectOpsFleet {
    foreach($fqdn in @($script:txtOpsFqdn.Text.Trim(),$script:txtDepotFqdn.Text.Trim())){
        Write-UiLog "Testing $fqdn TCP/443"
        if(-not(Test-NetConnection $fqdn -Port 443 -InformationLevel Quiet)){throw "TCP/443 failed to $fqdn"}
        Write-UiLog "TCP/443 OK to $fqdn"
    }
}

function Start-Upload {
    $bat=Get-ToolBat
    $pass=$script:pbOpsPassword.Password
    if(-not $pass){throw 'OPS password is required.'}
    $retry=3
    try{$retry=[int]$script:txtUploadRetries.Text.Trim()}catch{}
    $force=[bool]$script:chkForceReupload.IsChecked
    $vcf=$script:txtVcfVersion.Text.Trim()
    $depot=$script:txtUploadDir.Text.Trim()
    $state=Join-Path $depot '.vcf-upload-state.json'
    $common=@('depot','binaries','upload','--ops-fqdn',$script:txtOpsFqdn.Text.Trim(),'--ops-auth-source','LOCAL','--ops-user',$script:txtOpsUser.Text.Trim(),'--depot-fqdn',$script:txtDepotFqdn.Text.Trim(),'--vcf-version',$vcf,'--depot-store',$depot,'--sku',$script:txtSku.Text.Trim(),'--type','INSTALL')
    Start-JobWithPolling -TaskName 'Upload Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),($common|ConvertTo-Json -Compress),($script:UploadGroups|ConvertTo-Json -Depth 10 -Compress),$pass,$retry,$force,$state,$vcf,$depot) -ScriptBlock {
        param($bat,$dir,$commonJson,$groupsJson,$opsPassword,$retry,$force,$statePath,$vcf,$depot)
        function LoadState($p){try{if(Test-Path $p){return(Get-Content $p -Raw|ConvertFrom-Json -AsHashtable)}}catch{};return @{}}
        function SaveState($p,$s){$s|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $p -Encoding UTF8}
        function NewSecret($v){$p=Join-Path $env:TEMP ('vcfdt-ops-password-'+[guid]::NewGuid()+'.txt');[IO.File]::WriteAllText($p,$v.Trim(),[Text.Encoding]::ASCII);return $p}
        function CleanWD($d,$c){$wd=Join-Path $d 'workingDir';if(Test-Path $wd){Write-Output "Cleaning workingDir before $c upload: $wd";Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue;Start-Sleep 5}}
        function InvokeUpload($c,$attempt){
            $pf=NewSecret $opsPassword
            try{
                $args=@(($commonJson|ConvertFrom-Json)+@('--ops-user-password-file',$pf,'--component',$c))
                Write-Output ("==== Upload component: $c | attempt $attempt ====")
                Write-Output ('Upload args: '+($args -join ' '))
                $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$bat;foreach($a in $args){[void]$psi.ArgumentList.Add([string]$a)}
                $psi.WorkingDirectory=$dir;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true;$psi.CreateNoWindow=$true
                $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();try{1..10|ForEach-Object{$p.StandardInput.WriteLine('Y')}}catch{}
                while(-not$p.StandardOutput.EndOfStream){Write-Output $p.StandardOutput.ReadLine()}
                while(-not$p.StandardError.EndOfStream){Write-Output('ERROR: '+$p.StandardError.ReadLine())}
                $p.WaitForExit();Write-Output("Component $c attempt $attempt exit code: $($p.ExitCode)");return [int]$p.ExitCode
            } finally { Remove-Item $pf -Force -ErrorAction SilentlyContinue; Write-Output 'OPS password temp file removed.' }
        }
        $state=LoadState $statePath;$failed=@();$succeeded=@();$skipped=@();$groups=$groupsJson|ConvertFrom-Json
        foreach($g in $groups){
            Write-Output "######## Upload group: $($g.Name) ########"
            foreach($c in @($g.Components)){
                if((-not$force)-and$state.ContainsKey($c)-and$state[$c].Status-eq'Uploaded'-and$state[$c].VcfVersion-eq$vcf){Write-Output "SKIP: $c already Uploaded.";$skipped+=$c;continue}
                $ok=$false
                for($a=1;$a -le $retry;$a++){
                    CleanWD $depot $c
                    $ec=InvokeUpload $c $a
                    if($ec -eq 0){$ok=$true;$succeeded+=$c;$state[$c]=@{Status='Uploaded';VcfVersion=$vcf;Timestamp=(Get-Date).ToString('o')};SaveState $statePath $state;break}
                    else{Write-Output "WARN: $c failed with exit code $ec";if($a -lt $retry){Start-Sleep 60}}
                }
                if(-not$ok){$failed+=$c;$state[$c]=@{Status='Failed';VcfVersion=$vcf;Timestamp=(Get-Date).ToString('o')};SaveState $statePath $state}
            }
        }
        Write-Output "Upload summary: $($succeeded.Count) succeeded, $($skipped.Count) skipped, $($failed.Count) failed."
        if($failed.Count){Write-Output('FAILED COMPONENTS: '+($failed -join ', '))}
    }
}

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------
$xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VCF 9.1 Disconnected Software Depot Sync Tool" Height="890" Width="1360" WindowStartupLocation="CenterScreen" Background="#0F0F0F">
<Window.Resources>
<Style TargetType="Label"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="3"/></Style>
<Style TargetType="TextBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style>
<Style TargetType="PasswordBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style>
<Style TargetType="Button"><Setter Property="Margin" Value="3"/><Setter Property="Padding" Value="6,4"/><Setter Property="Width" Value="125"/><Setter Property="Background" Value="#2B2B2B"/><Setter Property="Foreground" Value="#EDEDED"/></Style>
<Style TargetType="GroupBox"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="6"/></Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="#EDEDED"/></Style>
<Style TargetType="ComboBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/></Style>
</Window.Resources>
<Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<GroupBox Header="Tool, Depot, Activation, and Download Mode" Grid.Column="0"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCFDT bin or .bat"/><TextBox x:Name="txtToolPath" Grid.Row="0" Grid.Column="1" Text="C:\Installs\VCF_Download_Tool\bin"/><Button x:Name="btnBrowseTool" Grid.Row="0" Grid.Column="2" Content="..."/>
<Label Grid.Row="1" Grid.Column="0" Content="Download directory"/><TextBox x:Name="txtDownloadDir" Grid.Row="1" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseDownload" Grid.Row="1" Grid.Column="2" Content="..."/>
<Label Grid.Row="2" Grid.Column="0" Content="Upload directory"/><TextBox x:Name="txtUploadDir" Grid.Row="2" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseUpload" Grid.Row="2" Grid.Column="2" Content="..."/>
<Label Grid.Row="3" Grid.Column="0" Content="Generated Depot ID"/><TextBox x:Name="txtDepotId" Grid.Row="3" Grid.Column="1"/><Button x:Name="btnCopyDepotId" Grid.Row="3" Grid.Column="2" Content="Copy ID"/>
<Label Grid.Row="4" Grid.Column="0" Content="Activation code"/><TextBox x:Name="txtActivationCode" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2"/>
<Label Grid.Row="5" Grid.Column="0" Content="Download mode"/><ComboBox x:Name="cboDownloadMode" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2"><ComboBoxItem IsSelected="True">Mode A - Base platform INSTALL only, all 9.1 catalog versions</ComboBoxItem><ComboBoxItem>Mode B - Base + HCX/Networks/Logging/Ops add-on INSTALL only, all 9.1 catalog versions</ComboBoxItem><ComboBoxItem>Mode C - Everything available in catalog, all detected bundle types/components</ComboBoxItem></ComboBox>
<Label Grid.Row="6" Grid.Column="0" Content="Download options"/><CheckBox x:Name="chkForceRedownload" Grid.Row="6" Grid.Column="1" Content="Force re-download" Margin="3,6,0,0"/>
</Grid></GroupBox>
<GroupBox Header="Fleet Upload Connection" Grid.Column="1"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCF version / SKU"/><StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtVcfVersion" Width="130" Text="9.1.0.0"/><TextBox x:Name="txtSku" Width="80" Text="VCF"/></StackPanel>
<Label Grid.Row="1" Grid.Column="0" Content="OPS FQDN"/><TextBox x:Name="txtOpsFqdn" Grid.Row="1" Grid.Column="1"/>
<Label Grid.Row="2" Grid.Column="0" Content="Fleet FQDN"/><TextBox x:Name="txtDepotFqdn" Grid.Row="2" Grid.Column="1"/>
<Label Grid.Row="3" Grid.Column="0" Content="OPS username"/><TextBox x:Name="txtOpsUser" Grid.Row="3" Grid.Column="1" Text="admin"/>
<Label Grid.Row="4" Grid.Column="0" Content="OPS password"/><PasswordBox x:Name="pbOpsPassword" Grid.Row="4" Grid.Column="1"/>
<Label Grid.Row="5" Grid.Column="0" Content="Upload retries"/><StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtUploadRetries" Width="60" Text="3"/><CheckBox x:Name="chkForceReupload" Content="Force re-upload" Margin="16,4,0,0"/></StackPanel>
</Grid></GroupBox></Grid>
<GroupBox Grid.Row="1" Header="Workflow"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="4"><Button x:Name="btnReadme" Content="Readme"/><Button x:Name="btnValidateTool" Content="Validate Tool"/><Button x:Name="btnGenerateDepotId" Content="Generate ID"/><Button x:Name="btnParseDepotId" Content="Parse ID Log"/><Button x:Name="btnDownload" Content="Download Binary"/><Button x:Name="btnConnect" Content="Connect"/><Button x:Name="btnUpload" Content="Upload Binary"/><Button x:Name="btnStop" Content="Stop" Background="#5A1F1F" IsEnabled="False"/><StackPanel Orientation="Vertical" Margin="10,0,0,0"><CheckBox x:Name="chkAutoScroll" Content="Auto-scroll log" IsChecked="True"/><CheckBox x:Name="chkDebug" Content="Debug monitor" IsChecked="True"/></StackPanel><Label Content="Status:"/><Label x:Name="lblStatus" Content="Ready" Foreground="#7CFF7C"/></StackPanel></GroupBox>
<GroupBox Grid.Row="2" Header="Log"><TextBox x:Name="txtLog" FontFamily="Consolas" FontSize="12" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" IsReadOnly="True" Background="#000000" Foreground="#EDEDED"/></GroupBox></Grid></Window>
"@

$script:window=[Windows.Markup.XamlReader]::Parse($xaml)
foreach($n in @('txtToolPath','btnBrowseTool','txtDownloadDir','btnBrowseDownload','txtUploadDir','btnBrowseUpload','txtDepotId','btnCopyDepotId','txtActivationCode','cboDownloadMode','chkForceRedownload','txtVcfVersion','txtSku','txtOpsFqdn','txtDepotFqdn','txtOpsUser','pbOpsPassword','txtUploadRetries','chkForceReupload','btnReadme','btnValidateTool','btnGenerateDepotId','btnParseDepotId','btnDownload','btnConnect','btnUpload','btnStop','txtLog','chkAutoScroll','chkDebug','lblStatus')){Set-Variable -Name $n -Scope Script -Value $script:window.FindName($n)}
function Browse-Folder($Target){$dlg=New-Object System.Windows.Forms.FolderBrowserDialog;if($dlg.ShowDialog()-eq[System.Windows.Forms.DialogResult]::OK){$Target.Text=$dlg.SelectedPath}}
$script:btnReadme.Add_Click({Start-Process $script:ReadmeUrl})
$script:btnBrowseTool.Add_Click({Browse-Folder $script:txtToolPath})
$script:btnBrowseDownload.Add_Click({Browse-Folder $script:txtDownloadDir})
$script:btnBrowseUpload.Add_Click({Browse-Folder $script:txtUploadDir})
$script:btnCopyDepotId.Add_Click({if($script:txtDepotId.Text){[Windows.Clipboard]::SetText($script:txtDepotId.Text);Write-UiLog 'Software Depot ID copied to clipboard.'}})
$script:btnParseDepotId.Add_Click({Parse-DepotIdFromExistingLog})
$script:btnValidateTool.Add_Click({try{Validate-ToolPath}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnGenerateDepotId.Add_Click({try{Start-GenerateDepotId}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnDownload.Add_Click({try{Start-Download}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnConnect.Add_Click({try{Test-ConnectOpsFleet}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnUpload.Add_Click({try{Start-Upload}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnStop.Add_Click({Stop-ActiveWork})
$script:window.Add_ContentRendered({
    New-RunDir
    Write-UiLog "==== VCF Depot Sync Tool started $script:AppVersion ===="
    Write-UiLog "Run folder: $script:RunDir"
    Remove-StaleSecretFiles
    Write-UiLog 'Mode A: base platform INSTALL artifacts only, all 9.1 catalog versions.'
    Write-UiLog 'Mode B: base platform plus HCX, Networks/VRNI, Logging/VRLI, Operations/VROPS, Automation/VRA, Salt, cloud proxy, and migration add-on INSTALL artifacts.'
    Write-UiLog 'Mode C: every bundle ID discovered in a freshly synced productVersionCatalog, all detected bundle types/components.'
    Write-UiLog 'Fresh catalog mode: Download Binary refreshes metadata/catalog before resolving Mode A/B/C IDs.'
    Write-UiLog 'No curated 22-ID fallback is used after fresh catalog sync; the run fails clearly if catalog generation/parsing fails.'
})
$null=$script:window.ShowDialog()
