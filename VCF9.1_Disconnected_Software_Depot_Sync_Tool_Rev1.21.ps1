<#
.SYNOPSIS
  VCF 9.1 Disconnected Software Depot Sync Tool
.DESCRIPTION
  Full production PowerShell 7 / WPF UI wrapper for the Broadcom VCF Download Tool.
  Provides Software Depot ID generation, disconnected binary download, Fleet upload,
  chunked upload workflow, JSON state tracking, retry handling, debug monitoring,
  robust Generate ID parsing from stdout/stderr/vdt.log, and improved download prompt handling.
.NOTES
  Production Release: Rev1.1 / UI v1.1.9-full
  Script Name: VCF9.1_Disconnected_Software_Depot_Sync_Tool_Rev1.1.ps1
#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:AppVersion = 'Rev1.1 / UI v1.1.9-full'
$script:ReadmeUrl = 'https://github.com/Achieve1molle/VCF-9.1-Disconnected-Software-Depot-Sync-Tool/blob/master/README.md'
$script:DownloadSet = 'VCF91-22-latest-install'

try { $pwsh = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path; if (-not $pwsh) { $pwsh = 'pwsh.exe' } } catch { $pwsh = 'pwsh.exe' }
if (-not $NoRelaunch -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath -NoRelaunch
    exit $LASTEXITCODE
}

# --------------------------------------------------------------------------------------
# Self-sign helper
# --------------------------------------------------------------------------------------
$script:SelfSignStatus = 'Self-sign not attempted.'
function Ensure-SelfSignedScript {
    try {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $PSCommandPath)) { $script:SelfSignStatus = 'Self-sign skipped: PSCommandPath unavailable.'; return }
        try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue } catch {}
        $sig = Get-AuthenticodeSignature -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid') { $script:SelfSignStatus = "Script signature already valid: $($sig.SignerCertificate.Subject)"; return }
        $subject = 'CN=VCF Depot Sync UI Code Signing'
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) { $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5) -ErrorAction Stop }
        $tmp = Join-Path $env:TEMP 'VCFDepotSync-CodeSigning.cer'
        Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\TrustedPublisher -ErrorAction SilentlyContinue | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\Root -ErrorAction SilentlyContinue | Out-Null
        Set-AuthenticodeSignature -FilePath $PSCommandPath -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop | Out-Null
        $verify = Get-AuthenticodeSignature -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
        $script:SelfSignStatus = "Self-sign completed. Signature status: $($verify.Status). Certificate: $($cert.Subject)"
    } catch { $script:SelfSignStatus = 'Self-sign failed: ' + $_.Exception.Message }
}
Ensure-SelfSignedScript

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --------------------------------------------------------------------------------------
# Globals
# --------------------------------------------------------------------------------------
$script:RunDir = $null
$script:LogFile = $null
$script:CurrentJob = $null
$script:JobTimer = $null
$script:IsBusy = $false
$script:HeartbeatTimer = $null
$script:HeartbeatOn = $false
$script:LastWorkingDirSnapshot = @{}
$script:ProcCpuSnapshot = @{}

# Curated 22 latest-only INSTALL IDs for VCF 9.1. Includes optional/adjacent components such as HCX.
$script:LatestIds = @(
'0a02f34d-2e9d-500d-bbb6-b417e9e96870','de3a3d15-6b06-5171-9e07-683baa634155','19c57bf5-4492-59b8-83eb-6d45c51acff3','aa88f811-700a-5384-b86e-c40191985348','2549d171-774b-5662-8a40-a40f8cb2cf11','eb2aa9bf-11df-5ce0-add9-69864dd4fa7d','ee6974ad-a803-58a3-b0c2-b86bf61e622b','2a141812-4173-5fe1-be1e-35a1059a6485','0911b05e-e5c1-5036-867f-7a12066c8d06','cfdc3829-f065-50ec-8c4e-2c2fc85ccc56','e48612e2-12f1-50b7-bff2-ec60a0d06861','ad46043f-a8b3-50c0-b994-9783fbce2f4d','342a5203-bc8e-51cb-9f64-b29509a14dc0','c47da8e6-b8f1-5ae8-9359-2af08bd9eb68','c7afe212-0aef-58a8-8cf5-dcdcc7818327','3cbee014-f05f-5522-8664-53b9f7ac91f2','8396a956-aeb1-5e97-981c-97966e3f513e','d7b7f50b-f15e-55ce-8d80-54a5104183f2','d1a8d3cd-74de-59c1-a26d-d46cf170430c','a7cc99d3-1148-5781-99c8-598c17bbaa11','3eec1fe9-357b-5739-b113-ceee0bfb59d5','1998d24e-9fa4-5a13-b795-472537e224d2')

$script:UploadGroups = @(
 [pscustomobject]@{Name='vCenter alone';Components=@('VCENTER')},
 [pscustomobject]@{Name='VCF Automation alone';Components=@('VRA')},
 [pscustomobject]@{Name='VCF services runtime alone';Components=@('VSP')},
 [pscustomobject]@{Name='VCF Operations for Networks alone';Components=@('VRNI')},
 [pscustomobject]@{Name='VMware NSX alone';Components=@('NSX_T_MANAGER')},
 [pscustomobject]@{Name='All others';Components=@('SDDC_MANAGER_VCF','DEPOT_SERVICE','VCF_LICENSE_SERVER','VCF_FLEET_LCM','VCF_SDDC_LCM','VIDB','TELEMETRY_ACCEPTOR','VROPS','VRLI','VCF_OPS_CLOUD_PROXY','VCFMS_METRICS_STORE','VCF_OBSERVABILITY_DATA_PLATFORM','VCF_SALT','VCF_SALT_RAAS','HCX','VCFDT','VCF_SERVICE_VCD_MIGRATION_BACKEND')}
)

# --------------------------------------------------------------------------------------
# Utility functions
# --------------------------------------------------------------------------------------
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
            if ($script:chkAutoScroll.IsChecked) { $script:txtLog.CaretIndex = $script:txtLog.Text.Length; $script:txtLog.ScrollToEnd() }
        }) | Out-Null
    } catch {}
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
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
    [System.Windows.MessageBox]::Show("Validated:`n$dir", 'VCF Download Tool', 'OK', 'Information') | Out-Null
}

function Write-SecretFile {
    param([string]$Path,[string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path,$Value.Trim(),[Text.Encoding]::ASCII)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true,$false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().Name,'FullControl','Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {}
}

function Remove-StaleSecretFiles {
    try {
        foreach ($pat in @('vcfdt-ops-password*.txt','vcfdt-activation-code*.txt')) {
            foreach ($i in @(Get-ChildItem -Path $env:TEMP -Filter $pat -File -ErrorAction SilentlyContinue)) {
                try { Remove-Item -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue; Write-UiLog "Removed stale temp secret file: $($i.Name)" } catch {}
            }
        }
    } catch { Write-UiLog ('Secret cleanup warning: ' + $_.Exception.Message) 'WARN' }
}

function Test-DownloadState {
    param([string]$Path,[string]$VcfVersion,[string]$Sku)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        return ($s.Status -eq 'Downloaded' -and $s.DownloadSet -eq $script:DownloadSet -and $s.VcfVersion -eq $VcfVersion -and $s.Sku -eq $Sku -and [int]$s.ExpectedItemCount -eq 22)
    } catch { return $false }
}

function Write-DebugHeartbeat {
    try {
        if (-not $script:IsBusy -or -not $script:chkDebug.IsChecked) { return }
        foreach ($d in @($script:txtUploadDir.Text.Trim(),$script:txtDownloadDir.Text.Trim()) | Where-Object { $_ } | Select-Object -Unique) {
            $wd = Join-Path $d 'workingDir'
            if (Test-Path -LiteralPath $wd) {
                foreach ($f in @(Get-ChildItem -LiteralPath $wd -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) {
                    $key = $f.FullName; $last = 0
                    if ($script:LastWorkingDirSnapshot.ContainsKey($key)) { $last = [double]$script:LastWorkingDirSnapshot[$key] }
                    $delta = [double]$f.Length - $last; $script:LastWorkingDirSnapshot[$key] = [double]$f.Length
                    Write-UiLog ("DEBUG workingDir: {0} size={1} delta={2} modified={3}" -f $f.Name,(Format-Bytes $f.Length),(Format-Bytes $delta),$f.LastWriteTime.ToString('HH:mm:ss'))
                }
            }
        }
        try {
            $bat = Get-ToolBat; $vdtLog = Get-VdtLogPathFromBat $bat
            if (Test-Path -LiteralPath $vdtLog) { $i = Get-Item -LiteralPath $vdtLog; Write-UiLog ("DEBUG VCFDT log: size={0} modified={1}" -f (Format-Bytes $i.Length),$i.LastWriteTime.ToString('HH:mm:ss')) }
        } catch {}
        try {
            $procs = Get-CimInstance Win32_Process -Filter "name='java.exe' or name='cmd.exe' or name='powershell.exe' or name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'vcf-download-tool|lcm-bundle-transfer-util|DepotStore|workingDir|VCF_Download_Tool' }
            foreach ($p in @($procs)) {
                $cpuText='n/a'
                try { $gp=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue; if($gp){$cpu=[double]$gp.CPU;$last=$null;if($script:ProcCpuSnapshot.ContainsKey([string]$p.ProcessId)){$last=[double]$script:ProcCpuSnapshot[[string]$p.ProcessId]};$script:ProcCpuSnapshot[[string]$p.ProcessId]=$cpu;if($null-ne$last){$cpuText=('total={0:N2}, delta={1:N2}'-f$cpu,($cpu-$last))}else{$cpuText=('total={0:N2}'-f$cpu)}} } catch {}
                Write-UiLog ("DEBUG process active: PID={0} Name={1} CPU={2}" -f $p.ProcessId,$p.Name,$cpuText)
                try { foreach($c in @(Get-NetTCPConnection -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue | Where-Object {$_.RemotePort -eq 443})){Write-UiLog ("DEBUG tcp443: PID={0} {1}:{2} -> {3}:{4} State={5}" -f $p.ProcessId,$c.LocalAddress,$c.LocalPort,$c.RemoteAddress,$c.RemotePort,$c.State)} } catch {}
            }
        } catch {}
    } catch { Write-UiLog ('DEBUG monitor error: ' + $_.Exception.Message) 'WARN' }
}

function Start-Heartbeat {
    if ($script:HeartbeatTimer) { $script:HeartbeatTimer.Stop() }
    $script:HeartbeatOn = $false
    $script:HeartbeatTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:HeartbeatTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:HeartbeatTimer.Add_Tick({
        if ($script:IsBusy) {
            $script:HeartbeatOn = -not $script:HeartbeatOn
            $script:lblStatus.Content = if ($script:HeartbeatOn) { 'Running' } else { 'Running .' }
            $script:lblStatus.Foreground = if ($script:HeartbeatOn) { [Windows.Media.Brushes]::DodgerBlue } else { [Windows.Media.Brushes]::LightGreen }
            Write-DebugHeartbeat
        }
    })
    $script:HeartbeatTimer.Start()
}
function Stop-Heartbeat { try { if ($script:HeartbeatTimer) { $script:HeartbeatTimer.Stop() } } catch {}; $script:HeartbeatTimer=$null; $script:HeartbeatOn=$false; $script:LastWorkingDirSnapshot=@{}; $script:ProcCpuSnapshot=@{} }

function Set-Busy { param([bool]$Busy)
    $script:IsBusy = $Busy
    $script:window.Dispatcher.Invoke([Action]{
        foreach ($b in @($script:btnReadme,$script:btnValidateTool,$script:btnGenerateDepotId,$script:btnDownload,$script:btnConnect,$script:btnUpload,$script:btnCopyDepotId,$script:btnParseDepotId)) { $b.IsEnabled = -not $Busy }
        $script:btnStop.IsEnabled = $Busy
        if ($Busy) { $script:lblStatus.Content='Running'; $script:lblStatus.Foreground=[Windows.Media.Brushes]::DodgerBlue; Start-Heartbeat }
        else { Stop-Heartbeat; $script:lblStatus.Content='Ready'; $script:lblStatus.Foreground=[Windows.Media.Brushes]::LightGreen }
    }) | Out-Null
}

function Start-JobWithPolling { param([scriptblock]$ScriptBlock,[object[]]$ArgumentList,[string]$TaskName)
    if ($script:IsBusy) { throw 'A task is already running.' }
    Set-Busy $true; Write-UiLog "Starting $TaskName"
    $script:CurrentJob = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $script:JobTimer = [Windows.Threading.DispatcherTimer]::new(); $script:JobTimer.Interval=[TimeSpan]::FromSeconds(2)
    $script:JobTimer.Add_Tick({
        try {
            $out = Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue
            foreach($l in @($out)){ if($null-ne$l){ Write-UiLog ([string]$l) } }
            if($script:CurrentJob.State -in @('Completed','Failed','Stopped')){
                $st=$script:CurrentJob.State; Write-UiLog "$TaskName finished with job state: $st" $(if($st -eq 'Completed'){'INFO'}else{'ERROR'})
                Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue; $script:CurrentJob=$null; $script:JobTimer.Stop(); Set-Busy $false
            }
        } catch { Write-UiLog $_.Exception.Message 'ERROR'; Set-Busy $false }
    })
    $script:JobTimer.Start()
}

function Stop-ActiveWork {
    try {
        Write-UiLog 'Stop requested by operator.' 'WARN'
        if ($script:JobTimer) { $script:JobTimer.Stop() }
        if ($script:CurrentJob) { Stop-Job -Job $script:CurrentJob -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Remove-Job -Job $script:CurrentJob -Force -ErrorAction SilentlyContinue; $script:CurrentJob=$null }
        $procs = Get-CimInstance Win32_Process -Filter "name='java.exe' or name='cmd.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'vcf-download-tool|lcm-bundle-transfer-util|DepotStore|workingDir|VCF_Download_Tool' }
        foreach($p in @($procs)){ try{ Write-UiLog "Stopping child process PID=$($p.ProcessId) Name=$($p.Name)" 'WARN'; Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
        Set-Busy $false; Write-UiLog 'Stop completed.' 'WARN'
    } catch { Write-UiLog ('Stop failed: ' + $_.Exception.Message) 'ERROR'; Set-Busy $false }
}

# --------------------------------------------------------------------------------------
# Generate ID workflow - robust parsing from stdout/stderr/current vdt.log delta
# --------------------------------------------------------------------------------------
function Start-GenerateDepotId {
    if ($script:IsBusy) { throw 'A task is already running.' }
    $bat = Get-ToolBat
    $dir = Split-Path -Parent $bat
    $vdtLog = Get-VdtLogPathFromBat $bat
    Set-Busy $true
    Write-UiLog 'Generating Software Depot ID. The tool will parse stdout, stderr, and new vdt.log content.'
    $script:CurrentJob = Start-Job -ArgumentList @($bat,$dir,$vdtLog) -ScriptBlock {
        param($bat,$dir,$vdtLog)
        function ParseGuid([string]$Text) {
            if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
            $patterns = @('serviceId=([0-9a-fA-F-]{36})','Software depot ID:\s*([0-9a-fA-F-]{36})','Software Depot ID:\s*([0-9a-fA-F-]{36})','\b([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b')
            foreach($pat in $patterns){ $m=[regex]::Match($Text,$pat); if($m.Success){ if($m.Groups.Count -gt 1){ return $m.Groups[1].Value } else { return $m.Value } } }
            return $null
        }
        function RunCmd([string[]]$ArgsToUse){
            $cmdText = '"' + $bat + '" ' + ($ArgsToUse -join ' ')
            Write-Output ('Generate command: ' + $cmdText)
            $psi=[Diagnostics.ProcessStartInfo]::new()
            $psi.FileName='cmd.exe'
            $psi.Arguments='/d /c ' + $cmdText
            $psi.WorkingDirectory=$dir
            $psi.UseShellExecute=$false
            $psi.RedirectStandardOutput=$true
            $psi.RedirectStandardError=$true
            $psi.RedirectStandardInput=$true
            $psi.CreateNoWindow=$true
            $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi
            [void]$p.Start()
            try { 1..5 | ForEach-Object { $p.StandardInput.WriteLine('Y') } } catch {}
            $so=$p.StandardOutput.ReadToEnd(); $se=$p.StandardError.ReadToEnd(); $p.WaitForExit()
            [pscustomobject]@{Exit=[int]$p.ExitCode;Out=$so;Err=$se;Command=$cmdText}
        }
        $oldLen=0
        try { if(Test-Path -LiteralPath $vdtLog){ $oldLen=(Get-Item -LiteralPath $vdtLog).Length } } catch {}
        $attempts=@(
            @('configuration','generate','--software-depot-id'),
            @('configuration','generate','--software-depot-id','--ceip','DISABLE')
        )
        $found=$null; $lastExit=9999
        foreach($a in $attempts){
            $r=RunCmd -ArgsToUse $a
            $lastExit=$r.Exit
            if($r.Out){ Write-Output $r.Out }
            if($r.Err){ Write-Output ('STDERR: ' + $r.Err) }
            Write-Output ('Generate exit code: ' + $r.Exit)
            $found=ParseGuid ($r.Out + "`n" + $r.Err)
            if($found){ break }
            if($r.Exit -eq 0 -and $found){ break }
        }
        if(-not $found){
            try{
                if(Test-Path -LiteralPath $vdtLog){
                    $fs=[IO.File]::Open($vdtLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    try{
                        if($oldLen -gt 0 -and $oldLen -lt $fs.Length){ $fs.Seek($oldLen,[IO.SeekOrigin]::Begin) | Out-Null }
                        $sr=[IO.StreamReader]::new($fs)
                        $newText=$sr.ReadToEnd()
                        $sr.Close()
                    } finally { $fs.Close() }
                    if($newText){ Write-Output 'Parsing newly appended vdt.log content for generated Software Depot ID.'; $found=ParseGuid $newText }
                }
            }catch{ Write-Output ('WARN: Failed to parse vdt.log for depot ID: ' + $_.Exception.Message) }
        }
        if($found){ Write-Output ('GUID_FOUND:' + $found); exit 0 }
        Write-Output 'ERROR: Generate completed but no Software Depot ID GUID was parsed from stdout, stderr, or new vdt.log content.'
        exit $lastExit
    }
    $script:JobTimer=[Windows.Threading.DispatcherTimer]::new(); $script:JobTimer.Interval=[TimeSpan]::FromSeconds(1)
    $script:JobTimer.Add_Tick({
        try{
            $out=Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue
            foreach($l in @($out)){
                if($null -eq $l){continue}
                $s=[string]$l
                if($s -match '^GUID_FOUND:([0-9a-fA-F-]{36})$'){
                    $guid=$Matches[1]
                    $script:txtDepotId.Text=$guid
                    [Windows.Clipboard]::SetText($guid)
                    $url="https://vcf.broadcom.com/vcf/clm/download-manager/register?serviceId=$guid"
                    Write-UiLog "Software Depot ID captured, populated in UI, and copied to clipboard: $guid"
                    Write-UiLog "Opening registration URL: $url"
                    Start-Process $url
                } else { Write-UiLog $s }
            }
            if($script:CurrentJob.State -in @('Completed','Failed','Stopped')){
                $st=$script:CurrentJob.State
                if($script:txtDepotId.Text -match '^[0-9a-fA-F-]{36}$'){ Write-UiLog "Generate ID workflow finished with job state $st and a populated Depot ID." } else { Write-UiLog "Generate ID workflow finished with job state $st but no Depot ID is populated." 'ERROR' }
                Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue; $script:CurrentJob=$null; $script:JobTimer.Stop(); Set-Busy $false
            }
        }catch{ Write-UiLog $_.Exception.Message 'ERROR'; Set-Busy $false }
    })
    $script:JobTimer.Start()
}

function Parse-DepotIdFromExistingLog {
    try{
        $bat=Get-ToolBat; $vdtLog=Get-VdtLogPathFromBat $bat
        if(-not(Test-Path -LiteralPath $vdtLog)){throw "vdt.log not found: $vdtLog"}
        $txt=Get-Content -LiteralPath $vdtLog -Raw
        $m=[regex]::Matches($txt,'(?:serviceId=|Software depot ID:\s*|Software Depot ID:\s*)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if($m.Count -lt 1){throw 'No GUID found in vdt.log.'}
        $guid=$m[$m.Count-1].Groups[1].Value
        $script:txtDepotId.Text=$guid
        [Windows.Clipboard]::SetText($guid)
        Write-UiLog "Parsed latest GUID from vdt.log and copied to clipboard: $guid"
    }catch{Write-UiLog $_.Exception.Message 'ERROR'}
}

# --------------------------------------------------------------------------------------
# Download and upload workflows
# --------------------------------------------------------------------------------------
function Start-Download {
    $bat=Get-ToolBat
    $act=$script:txtActivationCode.Text.Trim()
    if(-not $act){throw 'Activation code is required. Generate/register the Software Depot ID in Broadcom portal, then paste the activation code before downloading.'}
    $depot=$script:txtDownloadDir.Text.Trim(); New-Item -ItemType Directory -Force -Path $depot | Out-Null
    $statePath=Join-Path $depot '.vcf-download-state.json'; $vcfVersion=$script:txtVcfVersion.Text.Trim(); $sku=$script:txtSku.Text.Trim(); $force=[bool]$script:chkForceRedownload.IsChecked
    if((-not $force) -and (Test-DownloadState -Path $statePath -VcfVersion $vcfVersion -Sku $sku)){Write-UiLog "SKIP: Download set $script:DownloadSet is already marked Downloaded for VCF $vcfVersion in $statePath. Enable Force re-download to run again."; return}
    $af=Join-Path $env:TEMP ('vcfdt-activation-code-'+[guid]::NewGuid()+'.txt'); Write-SecretFile $af $act
    $args=@('binaries','download','--ceip','DISABLE','--depot-download-activation-code-file',$af,'--id',($script:LatestIds -join ','),'--depot-store',$depot)
    $argsJson=$args|ConvertTo-Json -Compress
    Write-UiLog ('Download command args: '+($args -join ' '))
    Start-JobWithPolling -TaskName 'Download Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),$argsJson,$af,$statePath,$vcfVersion,$sku,$script:DownloadSet) -ScriptBlock {
        param($bat,$dir,$argsJson,$secretFile,$statePath,$vcfVersion,$sku,$downloadSet)
        try{
            $args=@($argsJson|ConvertFrom-Json)
            Write-Output ('Download job args: '+($args -join ' '))
            $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$bat
            foreach($a in $args){[void]$psi.ArgumentList.Add([string]$a)}
            $psi.WorkingDirectory=$dir; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=$true; $psi.CreateNoWindow=$true
            $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi; [void]$p.Start()
            # Pre-answer common VCFDT prompts such as delete/overwrite/continue. The input buffer is intentional.
            try { 1..20 | ForEach-Object { $p.StandardInput.WriteLine('Y') } } catch {}
            while(-not $p.StandardOutput.EndOfStream){Write-Output $p.StandardOutput.ReadLine()}
            while(-not $p.StandardError.EndOfStream){Write-Output ('ERROR: '+$p.StandardError.ReadLine())}
            $p.WaitForExit(); Write-Output ('Exit code: '+$p.ExitCode)
            if($p.ExitCode -ne 0){throw 'Download failed'}
            $state=[ordered]@{Status='Downloaded';DownloadSet=$downloadSet;VcfVersion=$vcfVersion;Sku=$sku;Type='INSTALL';ExpectedItemCount=22;Timestamp=(Get-Date).ToString('o')}
            $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-Output "Download state written: $statePath"
        } finally { try{Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue; Write-Output 'Activation code temp file removed.'}catch{} }
    }
}

function Test-ConnectOpsFleet {
    foreach($fqdn in @($script:txtOpsFqdn.Text.Trim(),$script:txtDepotFqdn.Text.Trim())){
        Write-UiLog "Testing $fqdn TCP/443"
        if(-not(Test-NetConnection $fqdn -Port 443 -InformationLevel Quiet)){throw "TCP/443 failed to $fqdn"}
        Write-UiLog "TCP/443 OK to $fqdn"
    }
    [System.Windows.MessageBox]::Show('TCP/443 connectivity validated.','Connect','OK','Information')|Out-Null
}

function Start-Upload {
    $bat=Get-ToolBat; $pass=$script:pbOpsPassword.Password; if(-not $pass){throw 'OPS password is required.'}
    $retryCount=3; try{$retryCount=[int]$script:txtUploadRetries.Text.Trim()}catch{$retryCount=3}; if($retryCount -lt 1){$retryCount=1}; if($retryCount -gt 10){$retryCount=10}
    $retryDelaySeconds=60; $force=[bool]$script:chkForceReupload.IsChecked; $vcfVersion=$script:txtVcfVersion.Text.Trim(); $depotStore=$script:txtUploadDir.Text.Trim(); $statePath=Join-Path $depotStore '.vcf-upload-state.json'
    Write-UiLog "Upload retry policy: $retryCount attempt(s) per component, $retryDelaySeconds second delay between attempts. Force re-upload: $force"
    $common=@('depot','binaries','upload','--ops-fqdn',$script:txtOpsFqdn.Text.Trim(),'--ops-auth-source','LOCAL','--ops-user',$script:txtOpsUser.Text.Trim(),'--depot-fqdn',$script:txtDepotFqdn.Text.Trim(),'--vcf-version',$vcfVersion,'--depot-store',$depotStore,'--sku',$script:txtSku.Text.Trim(),'--type','INSTALL')
    Start-JobWithPolling -TaskName 'Upload Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),($common|ConvertTo-Json -Compress),($script:UploadGroups|ConvertTo-Json -Depth 10 -Compress),$pass,$retryCount,$retryDelaySeconds,$force,$statePath,$vcfVersion,$depotStore) -ScriptBlock {
        param($bat,$dir,$commonJson,$groupsJson,$opsPassword,$retryCount,$retryDelaySeconds,$force,$statePath,$vcfVersion,$depotStore)
        $common=@($commonJson|ConvertFrom-Json)
        function LoadState($p){try{if(Test-Path $p){return(Get-Content $p -Raw|ConvertFrom-Json -AsHashtable)}}catch{};return @{}}
        function SaveState($p,$s){try{$s|ConvertTo-Json -Depth 10|Set-Content $p -Encoding UTF8}catch{}}
        function NewSecret($v){$path=Join-Path $env:TEMP ('vcfdt-ops-password-'+[guid]::NewGuid()+'.txt');[IO.File]::WriteAllText($path,$v.Trim(),[Text.Encoding]::ASCII);return $path}
        function CleanWorkingDir($store,$component){try{$wd=Join-Path $store 'workingDir';if(Test-Path -LiteralPath $wd){Write-Output "Cleaning workingDir before component $component upload: $wd";Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue;Start-Sleep -Seconds 5}}catch{Write-Output "WARN: Unable to clean workingDir before $component upload: $($_.Exception.Message)"}}
        function InvokeUpload($component,$attempt,$max){
            $pf=$null;$lines=New-Object System.Collections.Generic.List[string]
            try{
                $pf=NewSecret $opsPassword;[void]$lines.Add("==== Upload component: $component | attempt $attempt of $max ====")
                $args=@($common+@('--ops-user-password-file',$pf,'--component',$component));[void]$lines.Add('Upload job args: '+($args -join ' '))
                $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$bat;foreach($a in $args){[void]$psi.ArgumentList.Add([string]$a)}
                $psi.WorkingDirectory=$dir;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true;$psi.CreateNoWindow=$true
                $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();try{1..10|ForEach-Object{$p.StandardInput.WriteLine('Y')}}catch{}
                while(-not$p.StandardOutput.EndOfStream){[void]$lines.Add($p.StandardOutput.ReadLine())}
                while(-not$p.StandardError.EndOfStream){[void]$lines.Add('ERROR: '+$p.StandardError.ReadLine())}
                $p.WaitForExit();[void]$lines.Add("Component $component attempt $attempt exit code: $($p.ExitCode)")
                return [pscustomobject]@{Component=$component;ExitCode=[int]$p.ExitCode;Lines=$lines.ToArray()}
            }catch{[void]$lines.Add("ERROR: Component $component attempt $attempt exception: $($_.Exception.Message)");return [pscustomobject]@{Component=$component;ExitCode=9999;Lines=$lines.ToArray()}}
            finally{if($pf){Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue;[void]$lines.Add('OPS password temp file removed.')}}
        }
        $state=LoadState $statePath;$failed=@();$succeeded=@();$skipped=@();$groups=$groupsJson|ConvertFrom-Json
        foreach($g in $groups){Write-Output "######## Upload group: $($g.Name) ########";foreach($c in @($g.Components)){
            if((-not$force)-and$state.ContainsKey($c)-and$state[$c].Status -eq 'Uploaded'-and$state[$c].VcfVersion -eq $vcfVersion){Write-Output "SKIP: Component $c is already marked Uploaded for VCF version $vcfVersion. Enable Force re-upload to upload again.";$skipped+=$c;continue}
            $ok=$false
            for($attempt=1;$attempt -le $retryCount;$attempt++){
                CleanWorkingDir $depotStore $c
                $result=InvokeUpload $c $attempt $retryCount
                foreach($line in @($result.Lines)){if($line){Write-Output $line}}
                $exitCode=[int]$result.ExitCode
                if($exitCode -eq 0){Write-Output "Component $c upload succeeded on attempt $attempt.";$ok=$true;$succeeded+=$c;$state[$c]=@{Status='Uploaded';VcfVersion=$vcfVersion;Timestamp=(Get-Date).ToString('o')};SaveState $statePath $state;break}
                else{Write-Output "WARN: Component $c failed with exit code $exitCode on attempt $attempt of $retryCount."}
                if($attempt -lt $retryCount){Write-Output "Retrying component $c in $retryDelaySeconds seconds...";Start-Sleep -Seconds $retryDelaySeconds}
            }
            if(-not$ok){Write-Output "ERROR: Component $c failed after $retryCount attempt(s). Continuing to next component.";$failed+=$c;$state[$c]=@{Status='Failed';VcfVersion=$vcfVersion;Timestamp=(Get-Date).ToString('o')};SaveState $statePath $state}
        }}
        Write-Output "Upload summary: $($succeeded.Count) succeeded, $($skipped.Count) skipped, $($failed.Count) failed."
        if($failed.Count -gt 0){Write-Output('FAILED COMPONENTS: '+($failed -join ', '))}
        if($skipped.Count -gt 0){Write-Output('SKIPPED COMPONENTS: '+($skipped -join ', '))}
        if($failed.Count -eq 0){Write-Output 'Upload workflow completed.'}
    }
}

# --------------------------------------------------------------------------------------
# WPF UI
# --------------------------------------------------------------------------------------
$xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VCF 9.1 Disconnected Software Depot Sync Tool" Height="860" Width="1300" WindowStartupLocation="CenterScreen" Background="#0F0F0F">
<Window.Resources>
<Style TargetType="Label"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="3"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
<Style TargetType="TextBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="BorderBrush" Value="#6E6E6E"/></Style>
<Style TargetType="PasswordBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="BorderBrush" Value="#6E6E6E"/></Style>
<Style TargetType="Button"><Setter Property="Margin" Value="3"/><Setter Property="Padding" Value="6,4"/><Setter Property="Width" Value="122"/><Setter Property="Background" Value="#2B2B2B"/><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="BorderBrush" Value="#8A8A8A"/></Style>
<Style TargetType="GroupBox"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="6"/><Setter Property="BorderBrush" Value="#BFBFBF"/></Style>
<Style TargetType="CheckBox"><Setter Property="Foreground" Value="#EDEDED"/></Style>
</Window.Resources>
<Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<GroupBox Header="Tool, Depot, and Activation" Grid.Column="0"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCFDT bin or .bat"/><TextBox x:Name="txtToolPath" Grid.Row="0" Grid.Column="1" Text="C:\Installs\VCF_Download_Tool\bin"/><Button x:Name="btnBrowseTool" Grid.Row="0" Grid.Column="2" Content="..."/>
<Label Grid.Row="1" Grid.Column="0" Content="Download directory"/><TextBox x:Name="txtDownloadDir" Grid.Row="1" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseDownload" Grid.Row="1" Grid.Column="2" Content="..."/>
<Label Grid.Row="2" Grid.Column="0" Content="Upload directory"/><TextBox x:Name="txtUploadDir" Grid.Row="2" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseUpload" Grid.Row="2" Grid.Column="2" Content="..."/>
<Label Grid.Row="3" Grid.Column="0" Content="Generated Depot ID"/><TextBox x:Name="txtDepotId" Grid.Row="3" Grid.Column="1" ToolTip="Editable so an ID can be pasted from vdt.log if needed."/><Button x:Name="btnCopyDepotId" Grid.Row="3" Grid.Column="2" Content="Copy ID"/>
<Label Grid.Row="4" Grid.Column="0" Content="Activation code"/><TextBox x:Name="txtActivationCode" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2"/>
<Label Grid.Row="5" Grid.Column="0" Content="Download options"/><CheckBox x:Name="chkForceRedownload" Grid.Row="5" Grid.Column="1" Content="Force re-download" Margin="3,6,0,0"/>
</Grid></GroupBox>
<GroupBox Header="Fleet Upload Connection" Grid.Column="1"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCF version / SKU"/><StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtVcfVersion" Width="130" Text="9.1.0.0"/><TextBox x:Name="txtSku" Width="80" Text="VCF"/></StackPanel>
<Label Grid.Row="1" Grid.Column="0" Content="OPS FQDN"/><TextBox x:Name="txtOpsFqdn" Grid.Row="1" Grid.Column="1" Text="pod01ops01.corp.achieve-1.com"/>
<Label Grid.Row="2" Grid.Column="0" Content="Fleet FQDN"/><TextBox x:Name="txtDepotFqdn" Grid.Row="2" Grid.Column="1" Text="pod01fleet01.corp.achieve-1.com"/>
<Label Grid.Row="3" Grid.Column="0" Content="OPS username"/><TextBox x:Name="txtOpsUser" Grid.Row="3" Grid.Column="1" Text="admin"/>
<Label Grid.Row="4" Grid.Column="0" Content="OPS password"/><PasswordBox x:Name="pbOpsPassword" Grid.Row="4" Grid.Column="1"/>
<Label Grid.Row="5" Grid.Column="0" Content="Upload retries"/><StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtUploadRetries" Width="60" Text="3"/><CheckBox x:Name="chkForceReupload" Content="Force re-upload" Margin="16,4,0,0"/></StackPanel>
</Grid></GroupBox>
</Grid>
<GroupBox Grid.Row="1" Header="Workflow"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="4">
<StackPanel><TextBlock Text="Readme" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnReadme" Content="Readme"/></StackPanel>
<StackPanel><TextBlock Text="Step 1" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnValidateTool" Content="Validate Tool"/></StackPanel>
<StackPanel><TextBlock Text="Step 2" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnGenerateDepotId" Content="Generate ID"/></StackPanel>
<StackPanel><TextBlock Text="Log Recovery" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnParseDepotId" Content="Parse ID Log"/></StackPanel>
<StackPanel><TextBlock Text="Step 3" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnDownload" Content="Download Binary"/></StackPanel>
<StackPanel><TextBlock Text="Step 4" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnConnect" Content="Connect"/></StackPanel>
<StackPanel><TextBlock Text="Step 5" Foreground="#7CFF7C" HorizontalAlignment="Center"/><Button x:Name="btnUpload" Content="Upload Binary"/></StackPanel>
<StackPanel><TextBlock Text="Stop" Foreground="#FF9E9E" HorizontalAlignment="Center"/><Button x:Name="btnStop" Content="Stop" Background="#5A1F1F" IsEnabled="False"/></StackPanel>
<StackPanel Orientation="Vertical" VerticalAlignment="Center" Margin="15,4,8,0"><CheckBox x:Name="chkAutoScroll" Content="Auto-scroll log" IsChecked="True"/><CheckBox x:Name="chkDebug" Content="Debug monitor" IsChecked="True"/></StackPanel>
<StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="8,12,0,0"><Label Content="Status:"/><Label x:Name="lblStatus" Content="Ready" Foreground="#7CFF7C"/></StackPanel>
</StackPanel></GroupBox>
<GroupBox Grid.Row="2" Header="Log"><TextBox x:Name="txtLog" VerticalContentAlignment="Top" VerticalAlignment="Stretch" HorizontalAlignment="Stretch" FontFamily="Consolas" FontSize="12" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" IsReadOnly="True" Background="#000000" Foreground="#EDEDED"/></GroupBox>
</Grid></Window>
"@
$script:window=[Windows.Markup.XamlReader]::Parse($xaml)
foreach($n in @('txtToolPath','btnBrowseTool','txtDownloadDir','btnBrowseDownload','txtUploadDir','btnBrowseUpload','txtDepotId','btnCopyDepotId','txtActivationCode','chkForceRedownload','txtVcfVersion','txtSku','txtOpsFqdn','txtDepotFqdn','txtOpsUser','pbOpsPassword','txtUploadRetries','chkForceReupload','btnReadme','btnValidateTool','btnGenerateDepotId','btnParseDepotId','btnDownload','btnConnect','btnUpload','btnStop','txtLog','chkAutoScroll','chkDebug','lblStatus')){Set-Variable -Name $n -Scope Script -Value $script:window.FindName($n)}
function Browse-Folder($Target){$dlg=New-Object System.Windows.Forms.FolderBrowserDialog;if($dlg.ShowDialog()-eq[System.Windows.Forms.DialogResult]::OK){$Target.Text=$dlg.SelectedPath}}
$script:btnReadme.Add_Click({try{Start-Process $script:ReadmeUrl;Write-UiLog "Opened Readme: $script:ReadmeUrl"}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnBrowseTool.Add_Click({Browse-Folder $script:txtToolPath});$script:btnBrowseDownload.Add_Click({Browse-Folder $script:txtDownloadDir});$script:btnBrowseUpload.Add_Click({Browse-Folder $script:txtUploadDir})
$script:btnCopyDepotId.Add_Click({if($script:txtDepotId.Text){[Windows.Clipboard]::SetText($script:txtDepotId.Text);Write-UiLog 'Software Depot ID copied to clipboard.'}})
$script:btnParseDepotId.Add_Click({Parse-DepotIdFromExistingLog})
$script:btnValidateTool.Add_Click({try{Validate-ToolPath}catch{Write-UiLog $_.Exception.Message 'ERROR';[System.Windows.MessageBox]::Show($_.Exception.Message,'Validate Tool failed','OK','Error')|Out-Null}})
$script:btnGenerateDepotId.Add_Click({try{$ans=[System.Windows.MessageBox]::Show('VCF Download Tool may regenerate the Software Depot ID. Current activation code can be invalidated. Continue?','Generate ID','YesNo','Warning');if($ans -ne 'Yes'){Write-UiLog 'Generate ID cancelled by operator.' 'WARN';return};Start-GenerateDepotId}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnDownload.Add_Click({try{Start-Download}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnConnect.Add_Click({try{Test-ConnectOpsFleet}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnUpload.Add_Click({try{Start-Upload}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnStop.Add_Click({Stop-ActiveWork})
$script:window.Add_ContentRendered({New-RunDir;Write-UiLog "==== VCF Depot Sync Tool started $script:AppVersion ====";Write-UiLog "Run folder: $script:RunDir";Write-UiLog $script:SelfSignStatus;Remove-StaleSecretFiles;Write-UiLog "Readme URL: $script:ReadmeUrl";Write-UiLog 'Generate ID fix enabled: parses stdout, stderr, and new vdt.log content; also includes Parse ID Log recovery button.';Write-UiLog 'Download prompt handling enabled: pre-answers common VCFDT delete/overwrite/continue prompts with Y.';Write-UiLog 'Generated Depot ID field is editable for manual paste/recovery.';Write-UiLog 'No validation or connection action is run automatically. Start with Step 1.'})
$null=$script:window.ShowDialog()

# SIG # Begin signature block
# MIIFvwYJKoZIhvcNAQcCoIIFsDCCBawCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD/s0KeaE6gAJrX
# 1iCTy6/wfIPi7TF/7ByyKddjEupTEaCCAyYwggMiMIICCqADAgECAhB6z+lukcl/
# j08JiNQ2T17sMA0GCSqGSIb3DQEBCwUAMCkxJzAlBgNVBAMMHlZDRiBEZXBvdCBT
# eW5jIFVJIENvZGUgU2lnbmluZzAeFw0yNjA2MDYxMjM3MDFaFw0zMTA2MDYxMjQ3
# MDFaMCkxJzAlBgNVBAMMHlZDRiBEZXBvdCBTeW5jIFVJIENvZGUgU2lnbmluZzCC
# ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALchQ5yxFqzUybu/6gZaAbMx
# Ivg29EBG9dPikN7kmbR2afVjO4BpxfdvePcvsRb08hNXFiBXd+JhTY/D2ORDMXTr
# m5hAyR7xkzyNe+WAH3L9svf4iOrykTntzTG4EiK8Vty9TgRtoeSTlBhCaF1recaV
# GmeXWb4gfd8vvaPpGyI4vZ0ScSOysS84fn9q2STjMF22Z66URJXGU+YNjX6j0jkk
# d6+vQI6f8vN3HJOtHCKXeLnBchWLbM8iEbIFIMbb0msOIzHmXMQ7CMnIlPJDc00P
# 6EXVxCk0V2JQpRD6BoOobNsTes05HwPLZiNS9O9H6lmWe2FLLjlFVqC1uvwBCGUC
# AwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0G
# A1UdDgQWBBRZ+S5sqwaYypwmL+TXp6DQNseNbTANBgkqhkiG9w0BAQsFAAOCAQEA
# nMfkp5x5quINyjW2Py8ZpV9kBAw+XzZxYLknN3kqcka//jWXJJLMHRDWeGl0o6W4
# j6xhs18sqTXHJQ9eL1wyV48nOQxaPN8wEiVVe14xVgyv1Eu9gxF1W6nH8sy27/f5
# +hojrVDKeFbCtb1+sSAfJCso/idLkVe88iwNhTH0tI1cJb+v0bppfQhjMuX3GXzu
# QQUDmwTXAfC1wAY/e3GATzGu06W8HPYoA/31i25wFMs+ABcADCXPKA6PUhncWO2w
# FZwzotwztgPXywfi8wyOZCo2AaqEiieX4ZpEByLu3ulP1OgvmlUB4imTo6Fevq/h
# dCXriiZPvGkQXPpa/2ZDwDGCAe8wggHrAgEBMD0wKTEnMCUGA1UEAwweVkNGIERl
# cG90IFN5bmMgVUkgQ29kZSBTaWduaW5nAhB6z+lukcl/j08JiNQ2T17sMA0GCWCG
# SAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcN
# AQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUw
# LwYJKoZIhvcNAQkEMSIEIPTnApYC5HEvdyl3VjY5ekf2VG3XEQ9qJXY5TFp6vsJk
# MA0GCSqGSIb3DQEBAQUABIIBAGatywSMj1M2MWDjlg68iegos/qX5CjEqjF+8tNq
# dU60yWGUUvmCxPYpWVKyTnUFRFnQkggTxDc5mS7mNcFhLtb308YtZHXZBQUyzk/C
# 8aKk6bl3lP0wHc44rvBrxmKd4lkcpBpmINwTXocOqSfkjaDI45h8Jw5DTSwfKmjt
# ffbuu1CjpJGiAeDC4pnLxzPvWtkbGIJ3Zul5I/dzZFtvlCAQwKdnMx1SdU4pxrBI
# EsVrnvCSURFMZhiBPKkVSOLY5aMvl6uIVy4osEMErqkH5EhAGsbfR3mLwPmRi1zc
# sIId+Bg1jtX9ao77ll+2eBLGC7/tFl3kT2Zbm7PfjEPRI8I=
# SIG # End signature block
