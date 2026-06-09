<#
.SYNOPSIS
  VCF 9.1 Disconnected Software Depot Sync Tool - Full Compatible Set Edition
.DESCRIPTION
  PowerShell 7 / WPF UI wrapper for Broadcom VCF Download Tool.
  v1.2.0 adds Mode C / Full Compatible Set behavior:
    - Download can run without curated --id filtering to pull all available compatible artifacts.
    - Upload can iterate INSTALL, UPGRADE, and PATCH image types for all known components.
    - ESX_HOST is included.
    - Optional/add-on modules are included where VCFDT has matching artifacts.
.NOTES
  Production Release: Rev1.2.0-full-compatible
#>
[CmdletBinding()]
param([switch]$NoRelaunch)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:AppVersion='Rev1.2.0-full-compatible'
$script:ReadmeUrl='https://github.com/Achieve1molle/VCF-9.1-Disconnected-Software-Depot-Sync-Tool/blob/master/README.md'

try { $pwsh=(Get-Process -Id $PID -ErrorAction SilentlyContinue).Path; if(-not $pwsh){$pwsh='pwsh.exe'} } catch { $pwsh='pwsh.exe' }
if(-not $NoRelaunch -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    & $pwsh -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath -NoRelaunch
    exit $LASTEXITCODE
}

$script:SelfSignStatus='Self-sign not attempted.'
function Ensure-SelfSignedScript {
    try {
        if([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not(Test-Path -LiteralPath $PSCommandPath)){ $script:SelfSignStatus='Self-sign skipped: PSCommandPath unavailable.'; return }
        try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue } catch {}
        $sig=Get-AuthenticodeSignature -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
        if($sig -and $sig.Status -eq 'Valid'){ $script:SelfSignStatus="Script signature already valid: $($sig.SignerCertificate.Subject)"; return }
        $subject='CN=VCF Depot Sync UI Code Signing'
        $cert=Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(30) } | Sort-Object NotAfter -Descending | Select-Object -First 1
        if(-not $cert){ $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5) -ErrorAction Stop }
        $tmp=Join-Path $env:TEMP 'VCFDepotSync-CodeSigning.cer'
        Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\TrustedPublisher -ErrorAction SilentlyContinue | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\Root -ErrorAction SilentlyContinue | Out-Null
        Set-AuthenticodeSignature -FilePath $PSCommandPath -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop | Out-Null
        $verify=Get-AuthenticodeSignature -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
        $script:SelfSignStatus="Self-sign completed. Signature status: $($verify.Status). Certificate: $($cert.Subject)"
    } catch { $script:SelfSignStatus='Self-sign failed: '+$_.Exception.Message }
}
Ensure-SelfSignedScript

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:RunDir=$null; $script:LogFile=$null; $script:CurrentJob=$null; $script:JobTimer=$null; $script:IsBusy=$false
$script:HeartbeatTimer=$null; $script:HeartbeatOn=$false; $script:ProcCpuSnapshot=@{}; $script:LastWorkingDirSnapshot=@{}

# Known VCF / add-on / optional components observed in VCFDT metadata scans plus common VCF 9.x components.
$script:AllComponents = @(
 'ESX_HOST','VCENTER','SDDC_MANAGER_VCF','NSX_T_MANAGER',
 'VRA','VROPS','VRLI','VRNI','VRSLCM','VRO','HCX',
 'VSP','DEPOT_SERVICE','VCF_LICENSE_SERVER','VCF_FLEET_LCM','VCF_SDDC_LCM','VIDB','TELEMETRY_ACCEPTOR',
 'VCF_OPS_CLOUD_PROXY','VCFMS_METRICS_STORE','VCF_OBSERVABILITY_DATA_PLATFORM','VCF_SALT','VCF_SALT_RAAS','VCFDT',
 'VCF_SERVICE_VCD_MIGRATION_BACKEND','VCF_CONSUMPTION_CLI','VCF_CONSUMPTION_CLI_PLUGINS',
 'VSAN_FILE_SERVICES','DLVM','VLR','VLR_EDGE','NSX_ALB','DSM','VKR',
 'SUPERVISOR','SUPERVISOR_SERVICE_ARGOCD','SUPERVISOR_SERVICE_CONTOUR','SUPERVISOR_SERVICE_VKS','SUPERVISOR_SERVICE_LCI',
 'SUPERVISOR_SERVICE_HARBOR','SUPERVISOR_SERVICE_SUPERVISOR_MANAGEMENT_PROXY','SUPERVISOR_SERVICE_METRICS_AGGREGATOR',
 'SUPERVISOR_SERVICE_CA_CLUSTERISSUER','SUPERVISOR_SERVICE_EXTDNS','VKS_STANDARD_PACKAGES','VKSM_EXTENSIONS',
 'VCF_SERVICE_SECRET_STORE','VCF_SERVICE_PROTECTION_AND_RECOVERY','VCF_SERVICE_CONFIGURATION'
)
$script:AllImageTypes=@('INSTALL','UPGRADE','PATCH')

# Previous curated latest-only list retained as fallback mode.
$script:CuratedLatestIds=@('0a02f34d-2e9d-500d-bbb6-b417e9e96870','de3a3d15-6b06-5171-9e07-683baa634155','19c57bf5-4492-59b8-83eb-6d45c51acff3','aa88f811-700a-5384-b86e-c40191985348','2549d171-774b-5662-8a40-a40f8cb2cf11','eb2aa9bf-11df-5ce0-add9-69864dd4fa7d','ee6974ad-a803-58a3-b0c2-b86bf61e622b','2a141812-4173-5fe1-be1e-35a1059a6485','0911b05e-e5c1-5036-867f-7a12066c8d06','cfdc3829-f065-50ec-8c4e-2c2fc85ccc56','e48612e2-12f1-50b7-bff2-ec60a0d06861','ad46043f-a8b3-50c0-b994-9783fbce2f4d','342a5203-bc8e-51cb-9f64-b29509a14dc0','c47da8e6-b8f1-5ae8-9359-2af08bd9eb68','c7afe212-0aef-58a8-8cf5-dcdcc7818327','3cbee014-f05f-5522-8664-53b9f7ac91f2','8396a956-aeb1-5e97-981c-97966e3f513e','d7b7f50b-f15e-55ce-8d80-54a5104183f2','d1a8d3cd-74de-59c1-a26d-d46cf170430c','a7cc99d3-1148-5781-99c8-598c17bbaa11','3eec1fe9-357b-5739-b113-ceee0bfb59d5','1998d24e-9fa4-5a13-b795-472537e224d2')

function New-RunDir { $base='D:\VCF91\Logs'; New-Item -ItemType Directory -Force -Path $base|Out-Null; $script:RunDir=Join-Path $base ('VCFDepotSync-'+(Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory -Force -Path $script:RunDir|Out-Null; $script:LogFile=Join-Path $script:RunDir 'VCFDepotSync.log'; ''|Set-Content -LiteralPath $script:LogFile -Encoding UTF8 }
function Write-UiLog { param([string]$Message,[string]$Level='INFO'); $line='[{0}][{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message; try{Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8}catch{}; try{$script:window.Dispatcher.Invoke([Action]{$script:txtLog.AppendText($line+[Environment]::NewLine);if($script:chkAutoScroll.IsChecked){$script:txtLog.CaretIndex=$script:txtLog.Text.Length;$script:txtLog.ScrollToEnd()}})|Out-Null}catch{} }
function Format-Bytes([double]$Bytes){ if($Bytes -ge 1GB){return '{0:N2} GB' -f ($Bytes/1GB)}; if($Bytes -ge 1MB){return '{0:N2} MB' -f ($Bytes/1MB)}; if($Bytes -ge 1KB){return '{0:N2} KB' -f ($Bytes/1KB)}; return "$Bytes B" }
function Get-ToolBat { $p=$script:txtToolPath.Text.Trim(); if(Test-Path $p -PathType Leaf){return $p}; $bat=Join-Path $p 'vcf-download-tool.bat'; if(Test-Path $bat -PathType Leaf){return $bat}; throw 'vcf-download-tool.bat not found. Select VCF Download Tool bin folder or vcf-download-tool.bat.' }
function Get-VdtLogPathFromBat([string]$Bat){ Join-Path (Split-Path -Parent (Split-Path -Parent $Bat)) 'log\vdt.log' }
function Validate-ToolPath { $bat=Get-ToolBat; $dir=Split-Path -Parent $bat; $lcm=Join-Path $dir 'lcm-bundle-transfer-util.bat'; if(-not(Test-Path $lcm)){throw "Missing required file: $lcm"}; Write-UiLog "Validated VCF Download Tool bin path: $dir"; [System.Windows.MessageBox]::Show("Validated:`n$dir",'VCF Download Tool','OK','Information')|Out-Null }
function Write-SecretFile { param([string]$Path,[string]$Value); New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null; [IO.File]::WriteAllText($Path,$Value.Trim(),[Text.Encoding]::ASCII) }
function Remove-StaleSecretFiles { foreach($pat in @('vcfdt-ops-password*.txt','vcfdt-activation-code*.txt')){ foreach($i in @(Get-ChildItem -Path $env:TEMP -Filter $pat -File -ErrorAction SilentlyContinue)){ try{Remove-Item -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue;Write-UiLog "Removed stale temp secret file: $($i.Name)"}catch{} } } }

function Write-DebugHeartbeat {
    try{
        if(-not $script:IsBusy -or -not $script:chkDebug.IsChecked){return}
        foreach($d in @($script:txtUploadDir.Text.Trim(),$script:txtDownloadDir.Text.Trim())|Where-Object{$_}|Select-Object -Unique){
            $wd=Join-Path $d 'workingDir'
            if(Test-Path $wd){ foreach($f in @(Get-ChildItem -LiteralPath $wd -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 5)){ $key=$f.FullName;$last=0;if($script:LastWorkingDirSnapshot.ContainsKey($key)){$last=[double]$script:LastWorkingDirSnapshot[$key]};$delta=[double]$f.Length-$last;$script:LastWorkingDirSnapshot[$key]=[double]$f.Length;Write-UiLog ("DEBUG workingDir: {0} size={1} delta={2} modified={3}" -f $f.Name,(Format-Bytes $f.Length),(Format-Bytes $delta),$f.LastWriteTime.ToString('HH:mm:ss')) } }
        }
        try{$bat=Get-ToolBat;$vdtLog=Get-VdtLogPathFromBat $bat;if(Test-Path $vdtLog){$i=Get-Item $vdtLog;Write-UiLog ("DEBUG VCFDT log: size={0} modified={1}" -f (Format-Bytes $i.Length),$i.LastWriteTime.ToString('HH:mm:ss'))}}catch{}
    }catch{Write-UiLog ('DEBUG monitor error: '+$_.Exception.Message) 'WARN'}
}
function Start-Heartbeat { if($script:HeartbeatTimer){$script:HeartbeatTimer.Stop()}; $script:HeartbeatTimer=[Windows.Threading.DispatcherTimer]::new(); $script:HeartbeatTimer.Interval=[TimeSpan]::FromSeconds(15); $script:HeartbeatTimer.Add_Tick({ if($script:IsBusy){$script:HeartbeatOn=-not $script:HeartbeatOn;$script:lblStatus.Content=if($script:HeartbeatOn){'Running'}else{'Running .'};$script:lblStatus.Foreground=if($script:HeartbeatOn){[Windows.Media.Brushes]::DodgerBlue}else{[Windows.Media.Brushes]::LightGreen};Write-DebugHeartbeat} }); $script:HeartbeatTimer.Start() }
function Stop-Heartbeat { try{if($script:HeartbeatTimer){$script:HeartbeatTimer.Stop()}}catch{};$script:HeartbeatTimer=$null;$script:HeartbeatOn=$false;$script:LastWorkingDirSnapshot=@{};$script:ProcCpuSnapshot=@{} }
function Set-Busy { param([bool]$Busy); $script:IsBusy=$Busy; $script:window.Dispatcher.Invoke([Action]{ foreach($b in @($script:btnReadme,$script:btnValidateTool,$script:btnGenerateDepotId,$script:btnParseDepotId,$script:btnDownload,$script:btnConnect,$script:btnUpload,$script:btnCopyDepotId)){ $b.IsEnabled=-not $Busy }; $script:btnStop.IsEnabled=$Busy; if($Busy){$script:lblStatus.Content='Running';$script:lblStatus.Foreground=[Windows.Media.Brushes]::DodgerBlue;Start-Heartbeat}else{Stop-Heartbeat;$script:lblStatus.Content='Ready';$script:lblStatus.Foreground=[Windows.Media.Brushes]::LightGreen} })|Out-Null }
function Start-JobWithPolling { param([scriptblock]$ScriptBlock,[object[]]$ArgumentList,[string]$TaskName); if($script:IsBusy){throw 'A task is already running.'}; Set-Busy $true; Write-UiLog "Starting $TaskName"; $script:CurrentJob=Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList; $script:JobTimer=[Windows.Threading.DispatcherTimer]::new(); $script:JobTimer.Interval=[TimeSpan]::FromSeconds(2); $script:JobTimer.Add_Tick({ try{$out=Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue;foreach($l in @($out)){if($null-ne$l){Write-UiLog ([string]$l)}};if($script:CurrentJob.State -in @('Completed','Failed','Stopped')){$st=$script:CurrentJob.State;Write-UiLog "$TaskName finished with job state: $st" $(if($st-eq'Completed'){'INFO'}else{'ERROR'});Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue;$script:CurrentJob=$null;$script:JobTimer.Stop();Set-Busy $false}}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false} }); $script:JobTimer.Start() }
function Stop-ActiveWork { try{Write-UiLog 'Stop requested by operator.' 'WARN'; if($script:JobTimer){$script:JobTimer.Stop()}; if($script:CurrentJob){Stop-Job $script:CurrentJob -ErrorAction SilentlyContinue;Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue;$script:CurrentJob=$null}; Get-CimInstance Win32_Process -Filter "name='java.exe' or name='cmd.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -match 'vcf-download-tool|lcm-bundle-transfer-util|DepotStore|workingDir|VCF_Download_Tool'}|ForEach-Object{try{Write-UiLog "Stopping child process PID=$($_.ProcessId) Name=$($_.Name)" 'WARN';Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}; Set-Busy $false }catch{Write-UiLog ('Stop failed: '+$_.Exception.Message) 'ERROR';Set-Busy $false} }

function ParseGuid([string]$Text){ if([string]::IsNullOrWhiteSpace($Text)){return $null}; foreach($pat in @('serviceId=([0-9a-fA-F-]{36})','Software depot ID:\s*([0-9a-fA-F-]{36})','Software Depot ID:\s*([0-9a-fA-F-]{36})','\b([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b')){ $m=[regex]::Match($Text,$pat); if($m.Success){return $m.Groups[1].Value} }; return $null }
function Start-GenerateDepotId {
    $bat=Get-ToolBat;$dir=Split-Path -Parent $bat;$vdtLog=Get-VdtLogPathFromBat $bat
    Set-Busy $true; Write-UiLog 'Generating Software Depot ID. Parsing stdout, stderr, and vdt.log.'
    $script:CurrentJob=Start-Job -ArgumentList @($bat,$dir,$vdtLog) -ScriptBlock {
        param($bat,$dir,$vdtLog)
        function PGuid([string]$Text){if([string]::IsNullOrWhiteSpace($Text)){return $null};foreach($pat in @('serviceId=([0-9a-fA-F-]{36})','Software depot ID:\s*([0-9a-fA-F-]{36})','Software Depot ID:\s*([0-9a-fA-F-]{36})','\b([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\b')){$m=[regex]::Match($Text,$pat);if($m.Success){return $m.Groups[1].Value}};return $null}
        $oldLen=0;try{if(Test-Path $vdtLog){$oldLen=(Get-Item $vdtLog).Length}}catch{}
        $cmd='"'+$bat+'" configuration generate --software-depot-id'
        Write-Output ('Generate command: '+$cmd)
        $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName='cmd.exe';$psi.Arguments='/d /c '+$cmd;$psi.WorkingDirectory=$dir;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
        $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();$so=$p.StandardOutput.ReadToEnd();$se=$p.StandardError.ReadToEnd();$p.WaitForExit();if($so){Write-Output $so};if($se){Write-Output ('STDERR: '+$se)};Write-Output ('Generate exit code: '+$p.ExitCode)
        $g=PGuid ($so+"`n"+$se)
        if(-not $g -and (Test-Path $vdtLog)){try{$txt=Get-Content $vdtLog -Raw;$g=PGuid $txt}catch{}}
        if($g){Write-Output ('GUID_FOUND:'+ $g);exit 0}else{Write-Output 'ERROR: No Software Depot ID GUID parsed.';exit $p.ExitCode}
    }
    $script:JobTimer=[Windows.Threading.DispatcherTimer]::new();$script:JobTimer.Interval=[TimeSpan]::FromSeconds(1);$script:JobTimer.Add_Tick({ try{$out=Receive-Job $script:CurrentJob -Keep:$false -ErrorAction SilentlyContinue;foreach($l in @($out)){if($null-eq$l){continue};$s=[string]$l;if($s -match '^GUID_FOUND:([0-9a-fA-F-]{36})$'){$guid=$Matches[1];$script:txtDepotId.Text=$guid;[Windows.Clipboard]::SetText($guid);$url="https://vcf.broadcom.com/vcf/clm/download-manager/register?serviceId=$guid";Write-UiLog "Software Depot ID captured and copied to clipboard: $guid";Start-Process $url}else{Write-UiLog $s}};if($script:CurrentJob.State -in @('Completed','Failed','Stopped')){Remove-Job $script:CurrentJob -Force -ErrorAction SilentlyContinue;$script:CurrentJob=$null;$script:JobTimer.Stop();Set-Busy $false}}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false} });$script:JobTimer.Start()
}
function Parse-DepotIdFromExistingLog { try{$bat=Get-ToolBat;$vdtLog=Get-VdtLogPathFromBat $bat;if(-not(Test-Path $vdtLog)){throw "vdt.log not found: $vdtLog"};$guid=ParseGuid (Get-Content $vdtLog -Raw);if(-not$guid){throw 'No GUID found in vdt.log.'};$script:txtDepotId.Text=$guid;[Windows.Clipboard]::SetText($guid);Write-UiLog "Parsed GUID from vdt.log and copied to clipboard: $guid"}catch{Write-UiLog $_.Exception.Message 'ERROR'} }

function Start-Download {
    $bat=Get-ToolBat;$act=$script:txtActivationCode.Text.Trim();if(-not$act){throw 'Activation code is required.'}
    $depot=$script:txtDownloadDir.Text.Trim();New-Item -ItemType Directory -Force -Path $depot|Out-Null
    $af=Join-Path $env:TEMP ('vcfdt-activation-code-'+[guid]::NewGuid()+'.txt');Write-SecretFile $af $act
    $mode=[string]$script:cmbDownloadMode.SelectedItem.Content
    if($mode -match 'Full Compatible'){
        $args=@('binaries','download','--ceip','DISABLE','--depot-download-activation-code-file',$af,'--depot-store',$depot)
        Write-UiLog 'Download mode: Full Compatible Set. No --id filter will be used. VCFDT will download all available artifacts permitted by the activation code/catalog.'
    } else {
        $args=@('binaries','download','--ceip','DISABLE','--depot-download-activation-code-file',$af,'--id',($script:CuratedLatestIds -join ','),'--depot-store',$depot)
        Write-UiLog 'Download mode: Curated latest-only ID list.'
    }
    Start-JobWithPolling -TaskName 'Download Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),($args|ConvertTo-Json -Compress),$af) -ScriptBlock {
        param($bat,$dir,$argsJson,$secretFile)
        try{$args=@($argsJson|ConvertFrom-Json);Write-Output('Download job args: '+($args -join ' '));$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$bat;foreach($a in $args){[void]$psi.ArgumentList.Add([string]$a)};$psi.WorkingDirectory=$dir;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true;$psi.CreateNoWindow=$true;$p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();try{1..30|ForEach-Object{$p.StandardInput.WriteLine('Y')}}catch{};while(-not$p.StandardOutput.EndOfStream){Write-Output $p.StandardOutput.ReadLine()};while(-not$p.StandardError.EndOfStream){Write-Output('ERROR: '+$p.StandardError.ReadLine())};$p.WaitForExit();Write-Output('Exit code: '+$p.ExitCode);if($p.ExitCode-ne0){throw 'Download failed'}}finally{try{Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue;Write-Output 'Activation code temp file removed.'}catch{}} }
}
function Test-ConnectOpsFleet { foreach($fqdn in @($script:txtOpsFqdn.Text.Trim(),$script:txtDepotFqdn.Text.Trim())){Write-UiLog "Testing $fqdn TCP/443";if(-not(Test-NetConnection $fqdn -Port 443 -InformationLevel Quiet)){throw "TCP/443 failed to $fqdn"};Write-UiLog "TCP/443 OK to $fqdn"};[System.Windows.MessageBox]::Show('TCP/443 connectivity validated.','Connect','OK','Information')|Out-Null }

function Start-Upload {
    $bat=Get-ToolBat;$pass=$script:pbOpsPassword.Password;if(-not$pass){throw 'OPS password is required.'}
    $retryCount=3;try{$retryCount=[int]$script:txtUploadRetries.Text.Trim()}catch{$retryCount=3};if($retryCount-lt1){$retryCount=1};if($retryCount-gt10){$retryCount=10}
    $components=if($script:chkUploadAllComponents.IsChecked){$script:AllComponents}else{@('VCENTER','VRA','VSP','VRNI','NSX_T_MANAGER','SDDC_MANAGER_VCF')}
    $types=if($script:chkAllImageTypes.IsChecked){$script:AllImageTypes}else{@('INSTALL')}
    $common=@('depot','binaries','upload','--ops-fqdn',$script:txtOpsFqdn.Text.Trim(),'--ops-auth-source','LOCAL','--ops-user',$script:txtOpsUser.Text.Trim(),'--depot-fqdn',$script:txtDepotFqdn.Text.Trim(),'--vcf-version',$script:txtVcfVersion.Text.Trim(),'--depot-store',$script:txtUploadDir.Text.Trim(),'--sku',$script:txtSku.Text.Trim())
    Write-UiLog "Upload plan: $($components.Count) components x $($types.Count) image types = $($components.Count*$types.Count) upload checks. Missing/empty combinations will be skipped when VCFDT returns no binaries."
    Start-JobWithPolling -TaskName 'Upload Binary' -ArgumentList @($bat,(Split-Path -Parent $bat),($common|ConvertTo-Json -Compress),($components|ConvertTo-Json -Compress),($types|ConvertTo-Json -Compress),$pass,$retryCount,$script:txtUploadDir.Text.Trim()) -ScriptBlock {
        param($bat,$dir,$commonJson,$componentsJson,$typesJson,$opsPassword,$retryCount,$depotStore)
        $common=@($commonJson|ConvertFrom-Json);$components=@($componentsJson|ConvertFrom-Json);$types=@($typesJson|ConvertFrom-Json)
        function NewSecret($v){$path=Join-Path $env:TEMP ('vcfdt-ops-password-'+[guid]::NewGuid()+'.txt');[IO.File]::WriteAllText($path,$v.Trim(),[Text.Encoding]::ASCII);return $path}
        function CleanWD($store,$c,$t){try{$wd=Join-Path $store 'workingDir';if(Test-Path $wd){Write-Output "Cleaning workingDir before $c/$t upload: $wd";Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue;Start-Sleep -Seconds 3}}catch{Write-Output('WARN: workingDir cleanup failed: '+$_.Exception.Message)}}
        $succeeded=@();$skipped=@();$failed=@()
        foreach($t in $types){ foreach($c in $components){
            $ok=$false;$empty=$false
            for($attempt=1;$attempt -le $retryCount;$attempt++){
                CleanWD $depotStore $c $t
                $pf=NewSecret $opsPassword
                try{
                    $args=@($common+@('--type',$t,'--ops-user-password-file',$pf,'--component',$c))
                    Write-Output "==== Upload component=$c type=$t attempt $attempt of $retryCount ===="
                    Write-Output ('Upload job args: '+($args -join ' '))
                    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$bat;foreach($a in $args){[void]$psi.ArgumentList.Add([string]$a)};$psi.WorkingDirectory=$dir;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true;$psi.CreateNoWindow=$true
                    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();try{1..10|ForEach-Object{$p.StandardInput.WriteLine('Y')}}catch{}
                    $out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit()
                    if($out){Write-Output $out};if($err){Write-Output('ERROR: '+$err)}
                    Write-Output "Component $c type $t attempt $attempt exit code: $($p.ExitCode)"
                    $combined=$out+"`n"+$err
                    if($combined -match '0 element|No binaries|No binary|not found|Download dir for binaries.*not found|Binaries to be exported:\s*[-\s]*0'){Write-Output "SKIP: No matching binaries found for $c / $t.";$empty=$true;break}
                    if($p.ExitCode -eq 0){$ok=$true;break}
                } finally {try{Remove-Item $pf -Force -ErrorAction SilentlyContinue;Write-Output 'OPS password temp file removed.'}catch{}}
                if($attempt -lt $retryCount){Write-Output "Retrying $c / $t in 60 seconds...";Start-Sleep -Seconds 60}
            }
            if($ok){$succeeded+="$c/$t";Write-Output "SUCCESS: $c / $t"}elseif($empty){$skipped+="$c/$t"}else{$failed+="$c/$t";Write-Output "FAILED: $c / $t"}
        }}
        Write-Output "Upload summary: $($succeeded.Count) succeeded/imported, $($skipped.Count) skipped-empty, $($failed.Count) failed."
        if($failed.Count -gt 0){Write-Output ('FAILED COMBINATIONS: '+($failed -join ', '))}
    }
}

$xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VCF 9.1 Disconnected Software Depot Sync Tool - Full Compatible Set" Height="900" Width="1350" WindowStartupLocation="CenterScreen" Background="#0F0F0F">
<Window.Resources><Style TargetType="Label"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="3"/></Style><Style TargetType="TextBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="PasswordBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="Button"><Setter Property="Margin" Value="3"/><Setter Property="Padding" Value="6,4"/><Setter Property="Width" Value="125"/><Setter Property="Background" Value="#2B2B2B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="GroupBox"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="6"/></Style><Style TargetType="CheckBox"><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="ComboBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/></Style></Window.Resources>
<Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
<Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<GroupBox Header="Tool, Depot, Activation, Download Mode" Grid.Column="0"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="175"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCFDT bin or .bat"/><TextBox x:Name="txtToolPath" Grid.Row="0" Grid.Column="1" Text="C:\Installs\VCF_Download_Tool\bin"/><Button x:Name="btnBrowseTool" Grid.Row="0" Grid.Column="2" Content="..."/>
<Label Grid.Row="1" Grid.Column="0" Content="Download directory"/><TextBox x:Name="txtDownloadDir" Grid.Row="1" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseDownload" Grid.Row="1" Grid.Column="2" Content="..."/>
<Label Grid.Row="2" Grid.Column="0" Content="Upload directory"/><TextBox x:Name="txtUploadDir" Grid.Row="2" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseUpload" Grid.Row="2" Grid.Column="2" Content="..."/>
<Label Grid.Row="3" Grid.Column="0" Content="Generated Depot ID"/><TextBox x:Name="txtDepotId" Grid.Row="3" Grid.Column="1"/><Button x:Name="btnCopyDepotId" Grid.Row="3" Grid.Column="2" Content="Copy ID"/>
<Label Grid.Row="4" Grid.Column="0" Content="Activation code"/><TextBox x:Name="txtActivationCode" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2"/>
<Label Grid.Row="5" Grid.Column="0" Content="Download mode"/><ComboBox x:Name="cmbDownloadMode" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2"><ComboBoxItem Content="Mode C - Full Compatible Set - no ID filter" IsSelected="True"/><ComboBoxItem Content="Curated latest-only ID list"/></ComboBox>
<Label Grid.Row="6" Grid.Column="0" Content="Download note"/><TextBox Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" Text="Mode C can be very large. It intentionally avoids --id filtering so VCFDT can pull all catalog-permitted artifacts." IsReadOnly="True"/>
</Grid></GroupBox>
<GroupBox Header="Fleet Upload Connection and Scope" Grid.Column="1"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="155"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Label Grid.Row="0" Grid.Column="0" Content="VCF version / SKU"/><StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtVcfVersion" Width="130" Text="9.1.0.0"/><TextBox x:Name="txtSku" Width="80" Text="VCF"/></StackPanel>
<Label Grid.Row="1" Grid.Column="0" Content="OPS FQDN"/><TextBox x:Name="txtOpsFqdn" Grid.Row="1" Grid.Column="1" Text="pod01ops01.corp.achieve-1.com"/>
<Label Grid.Row="2" Grid.Column="0" Content="Fleet FQDN"/><TextBox x:Name="txtDepotFqdn" Grid.Row="2" Grid.Column="1" Text="pod01fleet01.corp.achieve-1.com"/>
<Label Grid.Row="3" Grid.Column="0" Content="OPS username"/><TextBox x:Name="txtOpsUser" Grid.Row="3" Grid.Column="1" Text="admin"/>
<Label Grid.Row="4" Grid.Column="0" Content="OPS password"/><PasswordBox x:Name="pbOpsPassword" Grid.Row="4" Grid.Column="1"/>
<Label Grid.Row="5" Grid.Column="0" Content="Upload retries"/><TextBox x:Name="txtUploadRetries" Grid.Row="5" Grid.Column="1" Width="60" Text="3" HorizontalAlignment="Left"/>
<Label Grid.Row="6" Grid.Column="0" Content="Upload scope"/><StackPanel Grid.Row="6" Grid.Column="1" Orientation="Vertical"><CheckBox x:Name="chkUploadAllComponents" Content="Upload all known components/modules including ESX_HOST and add-ons" IsChecked="True"/><CheckBox x:Name="chkAllImageTypes" Content="Upload all image types: INSTALL, UPGRADE, PATCH" IsChecked="True"/></StackPanel>
</Grid></GroupBox></Grid>
<GroupBox Grid.Row="1" Header="Workflow"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="4"><Button x:Name="btnReadme" Content="Readme"/><Button x:Name="btnValidateTool" Content="Validate Tool"/><Button x:Name="btnGenerateDepotId" Content="Generate ID"/><Button x:Name="btnParseDepotId" Content="Parse ID Log"/><Button x:Name="btnDownload" Content="Download Binary"/><Button x:Name="btnConnect" Content="Connect"/><Button x:Name="btnUpload" Content="Upload Binary"/><Button x:Name="btnStop" Content="Stop" Background="#5A1F1F" IsEnabled="False"/><CheckBox x:Name="chkAutoScroll" Content="Auto-scroll" IsChecked="True" Margin="12,6,0,0"/><CheckBox x:Name="chkDebug" Content="Debug" IsChecked="True" Margin="12,6,0,0"/><Label Content="Status:"/><Label x:Name="lblStatus" Content="Ready" Foreground="#7CFF7C"/></StackPanel></GroupBox>
<GroupBox Grid.Row="2" Header="Log"><TextBox x:Name="txtLog" FontFamily="Consolas" FontSize="12" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" IsReadOnly="True" Background="#000000" Foreground="#EDEDED"/></GroupBox>
</Grid></Window>
"@
$script:window=[Windows.Markup.XamlReader]::Parse($xaml)
foreach($n in @('txtToolPath','btnBrowseTool','txtDownloadDir','btnBrowseDownload','txtUploadDir','btnBrowseUpload','txtDepotId','btnCopyDepotId','txtActivationCode','cmbDownloadMode','txtVcfVersion','txtSku','txtOpsFqdn','txtDepotFqdn','txtOpsUser','pbOpsPassword','txtUploadRetries','chkUploadAllComponents','chkAllImageTypes','btnReadme','btnValidateTool','btnGenerateDepotId','btnParseDepotId','btnDownload','btnConnect','btnUpload','btnStop','txtLog','chkAutoScroll','chkDebug','lblStatus')){Set-Variable -Name $n -Scope Script -Value $script:window.FindName($n)}
function Browse-Folder($Target){$dlg=New-Object System.Windows.Forms.FolderBrowserDialog;if($dlg.ShowDialog()-eq[System.Windows.Forms.DialogResult]::OK){$Target.Text=$dlg.SelectedPath}}
$script:btnReadme.Add_Click({try{Start-Process $script:ReadmeUrl;Write-UiLog "Opened Readme: $script:ReadmeUrl"}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnBrowseTool.Add_Click({Browse-Folder $script:txtToolPath});$script:btnBrowseDownload.Add_Click({Browse-Folder $script:txtDownloadDir});$script:btnBrowseUpload.Add_Click({Browse-Folder $script:txtUploadDir})
$script:btnCopyDepotId.Add_Click({if($script:txtDepotId.Text){[Windows.Clipboard]::SetText($script:txtDepotId.Text);Write-UiLog 'Software Depot ID copied to clipboard.'}})
$script:btnParseDepotId.Add_Click({Parse-DepotIdFromExistingLog})
$script:btnValidateTool.Add_Click({try{Validate-ToolPath}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnGenerateDepotId.Add_Click({try{Start-GenerateDepotId}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnDownload.Add_Click({try{Start-Download}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnConnect.Add_Click({try{Test-ConnectOpsFleet}catch{Write-UiLog $_.Exception.Message 'ERROR'}})
$script:btnUpload.Add_Click({try{Start-Upload}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}})
$script:btnStop.Add_Click({Stop-ActiveWork})
$script:window.Add_ContentRendered({New-RunDir;Write-UiLog "==== VCF Depot Sync Tool started $script:AppVersion ====";Write-UiLog "Run folder: $script:RunDir";Write-UiLog $script:SelfSignStatus;Remove-StaleSecretFiles;Write-UiLog 'Mode C enabled: full download without --id filter and upload all known components across INSTALL, UPGRADE, PATCH.';Write-UiLog 'Warning: Mode C may consume significant time and disk space.'})
$null=$script:window.ShowDialog()

# SIG # Begin signature block
# MIIFvwYJKoZIhvcNAQcCoIIFsDCCBawCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA3eXP6YOS994Ow
# KaiDfwJdwoY8RJQKZbfx0iebVu1xmKCCAyYwggMiMIICCqADAgECAhB6z+lukcl/
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
# LwYJKoZIhvcNAQkEMSIEIFAVWhD53vi/DFoTlXsOMTt9g8L7JgOBx/d1+/z9wT+f
# MA0GCSqGSIb3DQEBAQUABIIBABRYYbAS91+vTYtfwgihmTqt/I9tBG4V3ySRwfdU
# t0OXRoXAVG1N1vVVd9V6LEYNtiUdkYJq9vaV639s2fg8mAi50Cmpp7yHnOK5l9ww
# bfKEBirJiAy6SLiunMGqCzufgAgseJC5x3yghdNIxegD7gHhl+Znwn6XVoyKUiOP
# qfYJTfu0/lJds3u6e5SEtMiDs7G5D0MZ1lhw90KzTDcsS7qJ5r+ct0u5/aCkS0Ju
# PmDXgOSkZDaML/nRlvC6urI2Myythha5deNSxu4F6mf11T1FOptojME931ph4Aeu
# 48l1vbHldeWo3SJ1lLa+6wQ84wLwlJp0th7F/ST6TkT6tpk=
# SIG # End signature block
