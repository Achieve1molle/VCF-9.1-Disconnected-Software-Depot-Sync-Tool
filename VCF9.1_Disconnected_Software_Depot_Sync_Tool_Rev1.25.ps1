<#
.SYNOPSIS
  VCF 9.1 Disconnected Software Depot Sync Tool - Rev1.62 Production Full
.DESCRIPTION
  Production-ready PowerShell 7 / WPF UI wrapper for Broadcom VCF Download Tool.
.AUTHOR
  Michael Molle

.Rev1.25 includes:
    - Hard fix for idle tail-monitor null-path startup errors.
    - Tail monitor is only started by worker tasks and suppresses/stops stale null-path timer events.
    - Blue monochrome workflow step color scheme.
    - UNC-safe Download directory handling with existing mapped-drive reuse.
    - Download directory is also the upload source directory.
    - Metadata download uses Local catalog staging only.
    - Metadata/catalog/manifest content is copied to Download directory after metadata download.
    - INSTALL binaries download directly to Download directory without --automated-install.
    - Optional UPGRADE and ESX downloads target Download directory.
    - Fleet Day-2 uploads target VCF Operations / Fleet Depot Service using depot binaries upload.
    - Activation Code, Depot ID, and OPS password are never saved to config.

#>
[CmdletBinding()]
param([switch]$NoRelaunch)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:AppVersion = 'Rev1.62-production-existing-vcf-fleet-depot-full'
$script:DefaultVcfVersion = '9.1.0.0'
$script:ReadmeUrl = 'https://github.com/Achieve1molle/VCF-9.1-Disconnected-Software-Depot-Sync-Tool/blob/master/README.md'

try { $script:Pwsh = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path; if(-not $script:Pwsh){ $script:Pwsh = 'pwsh.exe' } } catch { $script:Pwsh = 'pwsh.exe' }
if(-not $NoRelaunch -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    & $script:Pwsh -NoProfile -ExecutionPolicy Bypass -STA -File $PSCommandPath -NoRelaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:ScriptDir = if($PSCommandPath){ Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:ConfigFile = Join-Path $script:ScriptDir 'VCFDepotSync.config.json'
$script:RunDir = $null
$script:LogFile = $null
$script:IsBusy = $false
$script:Proc = $null
$script:TailTimer = $null
$script:TailPosition = 0
$script:WorkerLog = $null
$script:WorkerTask = $null
$script:FleetDayNComponents = @('VROPS','VRA','VSP','VCF_FLEET_LCM','VIDB','VCF_SALT_RAAS','DEPOT_SERVICE','VCF_SALT','VCF_SDDC_LCM','TELEMETRY_ACCEPTOR','VCF_OBSERVABILITY_DATA_PLATFORM','VCFMS_METRICS_STORE','VRLI','VRNI','VCF_SERVICE_VCD_MIGRATION_BACKEND','HCX')
$script:ExpectedFullDepotComponents = @('HCX','VRLI','VRNI','VCFMS_METRICS_STORE','VCF_OBSERVABILITY_DATA_PLATFORM','VROPS','VRA','VSP','VCF_FLEET_LCM','DEPOT_SERVICE','VCF_SDDC_LCM','VCF_SALT','VCF_SALT_RAAS','VIDB','TELEMETRY_ACCEPTOR','VCENTER','NSX_T_MANAGER','SDDC_MANAGER_VCF')

function Reset-TailState {
    try { if($script:TailTimer){ $script:TailTimer.Stop() } } catch {}
    $script:TailTimer = $null
    $script:WorkerLog = $null
    $script:WorkerTask = $null
    $script:TailPosition = 0
}

function New-RunDir {
    $script:RunDir = Join-Path $script:ScriptDir ('VCFDepotSync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
    $script:LogFile = Join-Path $script:RunDir 'VCFDepotSync.log'
    '' | Set-Content -LiteralPath $script:LogFile -Encoding UTF8
}

function Write-UiLog {
    param([string]$Message,[string]$Level='INFO')
    # Hard suppress stale/idle tail monitor null-path noise and stop any orphaned timer.
    if($Level -eq 'ERROR' -and $Message -like 'Tail monitor error:*provided Path argument was null*'){
        Reset-TailState
        if(-not $script:IsBusy){ $script:Proc = $null }
        return
    }
    $line = '[{0}][{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$Level,$Message
    try { if($script:LogFile){ Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } } catch {}
    try {
        if($script:window -and $script:txtLog){
            $script:window.Dispatcher.Invoke([Action]{
                $script:txtLog.AppendText($line + [Environment]::NewLine)
                if($script:chkAutoScroll.IsChecked){ $script:txtLog.CaretIndex = $script:txtLog.Text.Length; $script:txtLog.ScrollToEnd() }
            }) | Out-Null
        }
    } catch {}
}

function Set-Busy([bool]$Busy){
    $script:IsBusy = $Busy
    $script:window.Dispatcher.Invoke([Action]{
        foreach($b in @($script:btnReadme,$script:btnLoadConfig,$script:btnSaveConfig,$script:btnValidateTool,$script:btnGenerateDepotId,$script:btnConnect,$script:btnDownloadDepot,$script:btnUploadAll,$script:btnUploadFleet,$script:btnCopyDepotId)){
            if($b){ $b.IsEnabled = -not $Busy }
        }
        $script:btnStop.IsEnabled = $Busy
        $script:lblStatus.Content = if($Busy){ 'Running' } else { 'Ready' }
        $script:lblStatus.Foreground = if($Busy){ [Windows.Media.Brushes]::DodgerBlue } else { [Windows.Media.Brushes]::LightGreen }
    }) | Out-Null
}

function Get-ToolBat {
    $p = $script:txtToolPath.Text.Trim()
    if(Test-Path $p -PathType Leaf){ return $p }
    $bat = Join-Path $p 'vcf-download-tool.bat'
    if(Test-Path $bat -PathType Leaf){ return $bat }
    throw 'vcf-download-tool.bat not found. Select the VCF Download Tool bin folder or vcf-download-tool.bat.'
}
function Assert-Vcf91([string]$Version){ if($Version -notmatch '^9\.1(\.|$)'){ throw "Only VCF 9.1.x is supported. Current value: $Version" } }
function Browse-Folder($Target){ $dlg=New-Object System.Windows.Forms.FolderBrowserDialog; if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ $Target.Text=$dlg.SelectedPath } }
function New-SecretFile($prefix,$value){ $p=Join-Path $env:TEMP ($prefix+'-'+[guid]::NewGuid()+'.txt'); [IO.File]::WriteAllText($p,$value.Trim(),[Text.Encoding]::ASCII); return $p }
function Remove-StaleSecretFiles { foreach($pat in @('vcfdt-ops-password*.txt','vcfdt-activation-code*.txt')){ foreach($i in @(Get-ChildItem -Path $env:TEMP -Filter $pat -File -ErrorAction SilentlyContinue)){ try{ Remove-Item -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue; Write-UiLog "Removed stale temp secret file: $($i.Name)" } catch {} } } }
function Test-DownloadDirectory([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){ throw 'Download directory is required.' }
    if($Path -match '^\\\\'){
        $m=[regex]::Match($Path,'^\\\\[^\\]+\\[^\\]+')
        if(-not $m.Success){ throw "UNC download directory must be in the form \\server\share or \\server\share\folder. Current value: $Path" }
        $root=$m.Value
        if(-not(Test-Path -LiteralPath $root)){ throw "UNC share root is not reachable by this user/session: $root" }
        Write-UiLog "UNC download directory detected. Existing mapped drive will be reused if available."
    }
}

function Get-ConfigObj{
    [ordered]@{
        ToolPath=$script:txtToolPath.Text; DownloadDir=$script:txtDownloadDir.Text; MetadataStageDir=$script:txtMetadataStageDir.Text
        VcfVersion=$script:txtVcfVersion.Text; Sku=$script:txtSku.Text
        IncludeUpgradeBinaries=[bool]$script:chkIncludeUpgradeBinaries.IsChecked; IncludeEsx=[bool]$script:chkIncludeEsx.IsChecked
        OpsFqdn=$script:txtOpsFqdn.Text; FleetFqdn=$script:txtFleetFqdn.Text; OpsUser=$script:txtOpsUser.Text; UploadRetries=$script:txtUploadRetries.Text
        AutoScroll=[bool]$script:chkAutoScroll.IsChecked; Debug=[bool]$script:chkDebug.IsChecked
        SavedAt=(Get-Date).ToString('o'); Note='Activation Code, Depot ID, and OPS password are intentionally not saved.'
    }
}
function Save-Config([string]$Path=$script:ConfigFile){ try{ New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)|Out-Null; Get-ConfigObj|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $Path -Encoding UTF8; Write-UiLog "Configuration saved to $Path. Secrets were not saved." }catch{ Write-UiLog ('Configuration save failed: '+$_.Exception.Message) 'ERROR' } }
function Load-Config([string]$Path=$script:ConfigFile){
    try{
        if(-not(Test-Path -LiteralPath $Path)){ Write-UiLog "No saved configuration found at $Path"; return }
        $cfg=(Get-Content -LiteralPath $Path -Raw)|ConvertFrom-Json -ErrorAction Stop
        foreach($p in @(@('ToolPath','txtToolPath'),@('DownloadDir','txtDownloadDir'),@('MetadataStageDir','txtMetadataStageDir'),@('VcfVersion','txtVcfVersion'),@('Sku','txtSku'),@('OpsFqdn','txtOpsFqdn'),@('FleetFqdn','txtFleetFqdn'),@('OpsUser','txtOpsUser'),@('UploadRetries','txtUploadRetries'))){ if($null -ne $cfg.($p[0])){ (Get-Variable -Scope Script -Name $p[1]).Value.Text=[string]$cfg.($p[0]) } }
        if($null -ne $cfg.IncludeUpgradeBinaries){ $script:chkIncludeUpgradeBinaries.IsChecked=[bool]$cfg.IncludeUpgradeBinaries }
        if($null -ne $cfg.IncludeEsx){ $script:chkIncludeEsx.IsChecked=[bool]$cfg.IncludeEsx }
        if($null -ne $cfg.AutoScroll){ $script:chkAutoScroll.IsChecked=[bool]$cfg.AutoScroll }
        if($null -ne $cfg.Debug){ $script:chkDebug.IsChecked=[bool]$cfg.Debug }
        $script:txtDepotId.Text=''; $script:txtActivationCode.Text=''; $script:pbOpsPassword.Password=''
        Write-UiLog "Configuration loaded from $Path. Secrets intentionally left blank."
    }catch{ Write-UiLog ('Configuration load failed: '+$_.Exception.Message) 'ERROR' }
}
function Browse-ConfigOpen{ $dlg=New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter='JSON config (*.json)|*.json|All files (*.*)|*.*'; $dlg.InitialDirectory=$script:ScriptDir; if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ $script:ConfigFile=$dlg.FileName; Load-Config $script:ConfigFile } }
function Browse-ConfigSave{ $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='JSON config (*.json)|*.json|All files (*.*)|*.*'; $dlg.FileName='VCFDepotSync.config.json'; $dlg.InitialDirectory=$script:ScriptDir; if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){ $script:ConfigFile=$dlg.FileName; Save-Config $script:ConfigFile } }

function New-WorkerScript{
@'
$ErrorActionPreference='Stop'
$script:MappedDrive=$null
$script:CreatedMapping=$false
function Log([string]$m){Add-Content -LiteralPath $env:VCF_WORKER_LOG -Value ('[{0}] {1}'-f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$m) -Encoding UTF8}
function Convert-JsonCommandToArray($o){if($null-eq$o){return @()};if($o -is [System.Array]){return @($o|ForEach-Object{[string]$_})};if($o -is [System.Collections.IEnumerable] -and -not($o -is [string])){return @($o|ForEach-Object{[string]$_})};return @([string]$o)}
function Get-UncParts([string]$p){$m=[regex]::Match($p,'^\\\\([^\\]+)\\([^\\]+)(.*)$');if(-not$m.Success){throw "Invalid UNC path: $p"};[pscustomobject]@{Root=('\\'+$m.Groups[1].Value+'\'+$m.Groups[2].Value);Rest=$m.Groups[3].Value.TrimStart('\')}}
function Get-ExistingDriveForUncRoot([string]$root){$n=$root.TrimEnd('\').ToLowerInvariant();try{$drives=Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue|Where-Object{$_.DriveType -eq 4 -and $_.ProviderName};foreach($d in $drives){if(([string]$d.ProviderName).TrimEnd('\').ToLowerInvariant()-eq$n){return [string]$d.DeviceID}}}catch{};try{foreach($line in @(cmd.exe /c net use 2>$null)){if($line -match '([A-Z]:)\s+(\\\\\S+)'){$drive=$Matches[1];$unc=$Matches[2].TrimEnd('\').ToLowerInvariant();if($unc -eq $n){return $drive}}}}catch{};return $null}
function Convert-UncToVdtPath([string]$p){if([string]::IsNullOrWhiteSpace($p)){return $p};if($p -notmatch '^\\\\'){New-Item -ItemType Directory -Force -Path $p|Out-Null;return $p};$parts=Get-UncParts $p;$existing=Get-ExistingDriveForUncRoot $parts.Root;if($existing){$mapped=if($parts.Rest){Join-Path ($existing+'\') $parts.Rest}else{($existing+'\')};New-Item -ItemType Directory -Force -Path $mapped|Out-Null;Log "Reusing existing mapped drive [$existing] for UNC share root [$($parts.Root)]. VCFDT depot-store path resolved to [$mapped].";return $mapped};foreach($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P'){$drive=$letter+':';if(-not(Test-Path ($drive+'\'))){Log "No existing drive mapping found for [$($parts.Root)]. Mapping temporary drive [$drive].";$np=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c','net','use',$drive,$parts.Root,'/persistent:no') -Wait -PassThru -NoNewWindow;if($np.ExitCode-ne 0){throw "net use failed for $($parts.Root) with exit code $($np.ExitCode). Ensure access and no conflicting credentials exist."};$script:MappedDrive=$drive;$script:CreatedMapping=$true;$mapped=if($parts.Rest){Join-Path ($drive+'\') $parts.Rest}else{($drive+'\')};New-Item -ItemType Directory -Force -Path $mapped|Out-Null;Log "VCFDT depot-store path resolved to [$mapped] for original UNC path [$p].";return $mapped}};throw 'No free drive letters P: through Z: available to map UNC download directory.'}
function Replace-DepotToken([object[]]$a,[string]$path){@($a|ForEach-Object{if([string]$_ -eq '__DEPOT_STORE__'){$path}else{[string]$_}})}
function CopyDepotMetadata([string]$src,[string]$dst){if([string]::IsNullOrWhiteSpace($src)-or[string]::IsNullOrWhiteSpace($dst)){return};New-Item -ItemType Directory -Force -Path $dst|Out-Null;$sr=(Resolve-Path -LiteralPath $src -ErrorAction SilentlyContinue).Path;$dr=(Resolve-Path -LiteralPath $dst -ErrorAction SilentlyContinue).Path;if($sr -and $dr -and $sr -eq $dr){Log 'Metadata staging path and download directory are the same. Metadata copy skipped.';return};Log ('Copying metadata/catalog/manifest from ['+$src+'] to ['+$dst+'] before binary download');robocopy.exe $src $dst /E /Z /R:2 /W:5 /XF *.ova *.iso *.zip *.tgz *.tar *.gz *.rpm *.bundle *.pak *.vib /NFL /NDL /NP|ForEach-Object{Log $_};if($LASTEXITCODE -gt 7){throw ('metadata robocopy failed '+$LASTEXITCODE)};Log ('metadata robocopy completed with exit code '+$LASTEXITCODE)}
function ValidateExpectedComponents([string]$depot,[object[]]$expected){if([string]::IsNullOrWhiteSpace($depot)-or-not(Test-Path -LiteralPath $depot)){Log ('WARN: Cannot validate expected components because depot path is missing: '+$depot);return};$names=@(Get-ChildItem -LiteralPath $depot -Recurse -Directory -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name -Unique);foreach($c in @($expected)){if($names -notcontains [string]$c){Log ('WARN: Expected full depot / Day-2 component not detected in depot tree yet: '+[string]$c)}}}
function RunVdt{param([string]$Bat,[object[]]$ArgList,[string]$WorkingDirectory);$final=@($ArgList|ForEach-Object{[string]$_});if($final.Count -eq 0){throw 'Internal worker error: VCFDT command argument list is empty.'};Log ('VCFDT args: '+($final -join ' '));$psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$Bat;foreach($x in $final){[void]$psi.ArgumentList.Add($x)};$psi.WorkingDirectory=$WorkingDirectory;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardInput=$true;$psi.CreateNoWindow=$true;$p=[Diagnostics.Process]::new();$p.StartInfo=$psi;[void]$p.Start();try{1..30|ForEach-Object{$p.StandardInput.WriteLine('Y')}}catch{};while(-not $p.StandardOutput.EndOfStream){Log $p.StandardOutput.ReadLine()};while(-not $p.StandardError.EndOfStream){Log ('ERROR: '+$p.StandardError.ReadLine())};$p.WaitForExit();Log ('Exit code: '+$p.ExitCode);if($p.ExitCode -ne 0){throw 'VCFDT failed with exit code '+$p.ExitCode}}
try{$task=Get-Content -LiteralPath $env:VCF_TASK_JSON -Raw|ConvertFrom-Json;$depotToolPath=Convert-UncToVdtPath ([string]$task.DepotStoreRaw);$cmds=@($task.Commands);Log ('Worker started: '+$task.Name);Log ('Command count: '+$cmds.Count);if($task.DepotStoreRaw){Log ('Original download/depot path: '+[string]$task.DepotStoreRaw);Log ('VCFDT depot-store path: '+$depotToolPath)};$i=0;foreach($cmd in $cmds){$i++;$args=Replace-DepotToken (Convert-JsonCommandToArray $cmd) $depotToolPath;Log ('Command '+$i+' arg count: '+$args.Count);try{RunVdt -Bat ([string]$task.Bat) -ArgList $args -WorkingDirectory ([string]$task.WorkingDirectory)}catch{if($task.ContinueOnCommandError){Log ('WARN: command skipped or failed: '+$_.Exception.Message)}else{throw}};if($task.CopyMetadataAfterCommandIndex -and $i -eq [int]$task.CopyMetadataAfterCommandIndex){CopyDepotMetadata ([string]$task.MetadataSource) ([string]$task.MetadataDestination)}};if($task.ValidateDepotPath){ValidateExpectedComponents $depotToolPath @($task.ExpectedComponents)};if($task.ParseGuidFromLog){$vdt=[string]$task.ParseGuidFromLog;if(Test-Path $vdt){$txt=Get-Content -LiteralPath $vdt -Raw;if($txt -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'){Log ('GUID_FOUND:'+$Matches[1])}}};Log ('Worker completed: '+$task.Name);exit 0}catch{Log ('ERROR: '+$_.Exception.Message);exit 1}finally{try{foreach($sf in @($task.SecretFiles)){if($sf){Remove-Item -LiteralPath ([string]$sf) -Force -ErrorAction SilentlyContinue;Log ('Removed temp secret file: '+[IO.Path]::GetFileName([string]$sf))}}}catch{};try{if($script:CreatedMapping -and $script:MappedDrive){Log ('Removing temporary UNC drive mapping '+$script:MappedDrive);Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c','net','use',$script:MappedDrive,'/delete','/y') -Wait -NoNewWindow|Out-Null}else{if($script:MappedDrive){Log ('Existing UNC drive mapping was reused and will not be removed: '+$script:MappedDrive)}}}catch{}}
'@
}

function Start-ExternalTask($name,[hashtable]$task){
    if($script:IsBusy){ throw 'A task is already running.' }
    Reset-TailState
    $safe=($name -replace '[^a-zA-Z0-9_-]','_')
    $script:WorkerLog=Join-Path $script:RunDir ($safe+'.worker.log')
    $script:WorkerTask=Join-Path $script:RunDir ($safe+'.task.json')
    $worker=Join-Path $script:RunDir ($safe+'.worker.ps1')
    ''|Set-Content -LiteralPath $script:WorkerLog -Encoding UTF8
    $task.Name=$name
    $task|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $script:WorkerTask -Encoding UTF8
    New-WorkerScript|Set-Content -LiteralPath $worker -Encoding UTF8
    Set-Busy $true
    Write-UiLog "Starting $name"
    $script:TailPosition=0
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$script:Pwsh
    foreach($a in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker)){[void]$psi.ArgumentList.Add($a)}
    $psi.UseShellExecute=$false
    $psi.Environment['VCF_WORKER_LOG']=$script:WorkerLog
    $psi.Environment['VCF_TASK_JSON']=$script:WorkerTask
    $script:Proc=[Diagnostics.Process]::Start($psi)
    Start-TailTimer $name
}
function Process-WorkerLine([string]$line){if($line -match 'GUID_FOUND:([0-9a-fA-F-]{36})'){$script:txtDepotId.Text=$Matches[1];[Windows.Clipboard]::SetText($Matches[1]);Write-UiLog ('Software Depot ID captured and copied to clipboard: '+$Matches[1])}else{Write-UiLog $line}}
function Start-TailTimer($name){
    if($script:TailTimer){try{$script:TailTimer.Stop()}catch{}}
    if([string]::IsNullOrWhiteSpace([string]$script:WorkerLog)){return}
    $script:TailTimer=[Windows.Threading.DispatcherTimer]::new()
    $script:TailTimer.Interval=[TimeSpan]::FromSeconds(1)
    $script:TailTimer.Add_Tick({
        try{
            if([string]::IsNullOrWhiteSpace([string]$script:WorkerLog)){Reset-TailState;return}
            if(Test-Path -LiteralPath $script:WorkerLog){
                $fs=[IO.File]::Open($script:WorkerLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                try{$fs.Seek($script:TailPosition,[IO.SeekOrigin]::Begin)|Out-Null;$sr=[IO.StreamReader]::new($fs);$new=$sr.ReadToEnd();$script:TailPosition=$fs.Position;$sr.Close();if($new){$new -split "`r?`n"|Where-Object{$_}|ForEach-Object{Process-WorkerLine $_}}}finally{$fs.Close()}
            }
            if($script:Proc -and $script:Proc.HasExited){
                if(Test-Path -LiteralPath $script:WorkerLog){$remaining=Get-Content -LiteralPath $script:WorkerLog -Raw;if($remaining.Length -gt $script:TailPosition){($remaining.Substring($script:TailPosition)-split "`r?`n")|Where-Object{$_}|ForEach-Object{Process-WorkerLine $_}}}
                $code=$script:Proc.ExitCode
                Reset-TailState
                $script:Proc=$null
                Set-Busy $false
                if($code -eq 0){Write-UiLog "$name completed"}else{Write-UiLog "$name failed with exit code $code" 'ERROR'}
            }elseif(-not $script:Proc){Reset-TailState}
        }catch{
            if($_.Exception.Message -like '*provided Path argument was null*'){Reset-TailState;return}
            Write-UiLog ('Tail monitor error: '+$_.Exception.Message) 'ERROR'
            Reset-TailState
            if($script:Proc -and -not $script:Proc.HasExited){Set-Busy $true}else{Set-Busy $false}
        }
    })
    $script:TailTimer.Start()
}
function Stop-ActiveWork{Write-UiLog 'Stop requested by operator.' 'WARN';try{if($script:Proc -and -not $script:Proc.HasExited){$script:Proc.Kill($true)}}catch{};Reset-TailState;Set-Busy $false}
function Get-VdtLogPath([string]$bat){Join-Path (Split-Path -Parent (Split-Path -Parent $bat)) 'log\vdt.log'}
function Start-GenerateDepotId{$bat=Get-ToolBat;$dir=Split-Path -Parent $bat;$task=@{Bat=$bat;WorkingDirectory=$dir;Commands=@(@('configuration','generate','--software-depot-id'));ContinueOnCommandError=$false;SecretFiles=@();ParseGuidFromLog=(Get-VdtLogPath $bat);DepotStoreRaw=''};Start-ExternalTask 'Generate_Depot_ID' $task}
function Start-DownloadDepot{$bat=Get-ToolBat;$dir=Split-Path -Parent $bat;$act=$script:txtActivationCode.Text.Trim();if(-not $act){throw 'Activation code is required.'};$ver=$script:txtVcfVersion.Text.Trim();if(-not $ver){$ver=$script:DefaultVcfVersion};Assert-Vcf91 $ver;$sku=$script:txtSku.Text.Trim();if(-not $sku){$sku='VCF'};$stage=$script:txtMetadataStageDir.Text.Trim();$final=$script:txtDownloadDir.Text.Trim();if(-not $stage){$stage=$final};Test-DownloadDirectory $final;New-Item -ItemType Directory -Force -Path $stage,$final|Out-Null;$af=New-SecretFile 'vcfdt-activation-code' $act;$cmds=@();$cmds+=,@('metadata','download','--depot-download-activation-code-file',$af,'--depot-store',$stage);$cmds+=,@('binaries','download','--sku',$sku,'--vcf-version',$ver,'--depot-download-activation-code-file',$af,'--type','INSTALL','--depot-store','__DEPOT_STORE__');if($script:chkIncludeUpgradeBinaries.IsChecked){$cmds+=,@('binaries','download','--sku',$sku,'--vcf-version',$ver,'--depot-download-activation-code-file',$af,'--type','UPGRADE','--depot-store','__DEPOT_STORE__')};if($script:chkIncludeEsx.IsChecked){$cmds+=,@('esx','download','--depot-download-activation-code-file',$af,'--depot-store','__DEPOT_STORE__')};Write-UiLog "Download plan: metadata -> [$stage], metadata copy -> [$final], full INSTALL binaries -> [$final].";$task=@{Bat=$bat;WorkingDirectory=$dir;Commands=$cmds;ContinueOnCommandError=$false;CopyMetadataAfterCommandIndex=1;MetadataSource=$stage;MetadataDestination=$final;ValidateDepotPath=$final;ExpectedComponents=$script:ExpectedFullDepotComponents;SecretFiles=@($af);DepotStoreRaw=$final};Start-ExternalTask 'Download_Depot' $task}
function Get-UploadBaseArgs([string]$type,[string]$pf){@('depot','binaries','upload','--ops-fqdn',$script:txtOpsFqdn.Text.Trim(),'--ops-auth-source','LOCAL','--ops-user',$script:txtOpsUser.Text.Trim(),'--ops-user-password-file',$pf,'--depot-fqdn',$script:txtFleetFqdn.Text.Trim(),'--vcf-version',$script:txtVcfVersion.Text.Trim(),'--depot-store','__DEPOT_STORE__','--sku',$script:txtSku.Text.Trim(),'--type',$type)}
function Assert-UploadReady{if(-not $script:pbOpsPassword.Password){throw 'OPS password is required.'};if(-not $script:txtOpsFqdn.Text.Trim()){throw 'OPS FQDN is required.'};if(-not $script:txtFleetFqdn.Text.Trim()){throw 'Fleet FQDN is required.'};Assert-Vcf91 $script:txtVcfVersion.Text.Trim();Test-DownloadDirectory $script:txtDownloadDir.Text.Trim()}
function Start-UploadAll{Assert-UploadReady;$bat=Get-ToolBat;$dir=Split-Path -Parent $bat;$pf=New-SecretFile 'vcfdt-ops-password' $script:pbOpsPassword.Password;$types=if($script:chkIncludeUpgradeBinaries.IsChecked){@('INSTALL','UPGRADE')}else{@('INSTALL')};$cmds=@();foreach($t in $types){$cmds+=,(Get-UploadBaseArgs $t $pf)};$task=@{Bat=$bat;WorkingDirectory=$dir;Commands=$cmds;ContinueOnCommandError=$false;SecretFiles=@($pf);DepotStoreRaw=$script:txtDownloadDir.Text.Trim()};Start-ExternalTask 'Upload_VCF_Binaries' $task}
function Start-UploadFleet{Assert-UploadReady;$bat=Get-ToolBat;$dir=Split-Path -Parent $bat;$pf=New-SecretFile 'vcfdt-ops-password' $script:pbOpsPassword.Password;$types=if($script:chkIncludeUpgradeBinaries.IsChecked){@('INSTALL','UPGRADE')}else{@('INSTALL')};$cmds=@();foreach($t in $types){foreach($c in $script:FleetDayNComponents){$cmds+=,@((Get-UploadBaseArgs $t $pf)+@('--component',$c))}};$task=@{Bat=$bat;WorkingDirectory=$dir;Commands=$cmds;ContinueOnCommandError=$true;SecretFiles=@($pf);DepotStoreRaw=$script:txtDownloadDir.Text.Trim()};Start-ExternalTask 'Upload_Fleet_Binaries' $task}
function Test-ConnectTargets{foreach($fqdn in @($script:txtOpsFqdn.Text.Trim(),$script:txtFleetFqdn.Text.Trim())|Where-Object{$_}){Write-UiLog "Testing $fqdn TCP/443";if(-not(Test-NetConnection $fqdn -Port 443 -InformationLevel Quiet)){throw "TCP/443 failed to $fqdn"};Write-UiLog "TCP/443 OK to $fqdn"};[System.Windows.MessageBox]::Show('TCP/443 connectivity validated for populated FQDNs.','Connect to VCF OPS','OK','Information')|Out-Null}

$xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VCF 9.1 Disconnected Software Depot Sync Tool - Existing VCF Fleet Depot" Height="900" Width="1580" MinWidth="1100" MinHeight="760" WindowStartupLocation="CenterScreen" Background="#0F0F0F"><Window.Resources><Style TargetType="Label"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="3"/><Setter Property="VerticalAlignment" Value="Center"/></Style><Style TargetType="TextBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="PasswordBox"><Setter Property="Margin" Value="3"/><Setter Property="MinHeight" Value="26"/><Setter Property="Background" Value="#1B1B1B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="Button"><Setter Property="Margin" Value="3"/><Setter Property="Padding" Value="6,4"/><Setter Property="MinWidth" Value="105"/><Setter Property="Background" Value="#2B2B2B"/><Setter Property="Foreground" Value="#EDEDED"/></Style><Style TargetType="GroupBox"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="Margin" Value="6"/></Style><Style TargetType="CheckBox"><Setter Property="Foreground" Value="#EDEDED"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style></Window.Resources><Grid Margin="10"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><GroupBox Header="Tool, Depot, Activation, Download" Grid.Column="0"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="175"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Label Grid.Row="0" Grid.Column="0" Content="VCFDT bin or .bat"/><TextBox x:Name="txtToolPath" Grid.Row="0" Grid.Column="1" Text="C:\Staging\vcf-download-tool\bin"/><Button x:Name="btnBrowseTool" Grid.Row="0" Grid.Column="2" Content="..."/><Label Grid.Row="1" Grid.Column="0" Content="Download directory"/><TextBox x:Name="txtDownloadDir" Grid.Row="1" Grid.Column="1" Text="C:\Staging\DepotStore"/><Button x:Name="btnBrowseDownload" Grid.Row="1" Grid.Column="2" Content="..."/><Label Grid.Row="2" Grid.Column="0" Content="Local catalog staging"/><TextBox x:Name="txtMetadataStageDir" Grid.Row="2" Grid.Column="1" Text="C:\Staging\VCF91-MetadataStage"/><Button x:Name="btnBrowseMetadataStage" Grid.Row="2" Grid.Column="2" Content="..."/><Label Grid.Row="3" Grid.Column="0" Content="Generated Depot ID"/><TextBox x:Name="txtDepotId" Grid.Row="3" Grid.Column="1"/><Button x:Name="btnCopyDepotId" Grid.Row="3" Grid.Column="2" Content="Copy ID"/><Label Grid.Row="4" Grid.Column="0" Content="Activation code"/><TextBox x:Name="txtActivationCode" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2"/><Label Grid.Row="5" Grid.Column="0" Content="Upgrade binaries"/><CheckBox x:Name="chkIncludeUpgradeBinaries" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" Content="Also download/upload UPGRADE binaries" IsChecked="False" Margin="3"/><Label Grid.Row="6" Grid.Column="0" Content="ESX binaries"/><CheckBox x:Name="chkIncludeEsx" Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" Content="Also download ESX binaries and metadata" IsChecked="True" Margin="3"/></Grid></GroupBox><GroupBox Header="Fleet Upload Target" Grid.Column="1"><Grid Margin="6"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="155"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Label Grid.Row="0" Grid.Column="0" Content="VCF version / SKU"/><StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal"><TextBox x:Name="txtVcfVersion" Width="130" Text="9.1.0.0"/><TextBox x:Name="txtSku" Width="80" Text="VCF"/></StackPanel><Label Grid.Row="1" Grid.Column="0" Content="OPS FQDN"/><TextBox x:Name="txtOpsFqdn" Grid.Row="1" Grid.Column="1"/><Label Grid.Row="2" Grid.Column="0" Content="Fleet FQDN"/><TextBox x:Name="txtFleetFqdn" Grid.Row="2" Grid.Column="1"/><Label Grid.Row="3" Grid.Column="0" Content="OPS username"/><TextBox x:Name="txtOpsUser" Grid.Row="3" Grid.Column="1" Text="admin"/><Label Grid.Row="4" Grid.Column="0" Content="OPS password"/><PasswordBox x:Name="pbOpsPassword" Grid.Row="4" Grid.Column="1"/><Label Grid.Row="5" Grid.Column="0" Content="Upload retries"/><TextBox x:Name="txtUploadRetries" Grid.Row="5" Grid.Column="1" Width="60" Text="3" HorizontalAlignment="Left"/></Grid></GroupBox></Grid><GroupBox Grid.Row="1" Header="Workflow"><Grid Margin="4"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><UniformGrid Grid.Row="0" Rows="1" Columns="9"><Border Background="#0B2E4A" Margin="3" Padding="3"><TextBlock Text="Step 1" Foreground="White" TextAlignment="Center"/></Border><Border Background="#123F63" Margin="3" Padding="3"><TextBlock Text="Step 2" Foreground="White" TextAlignment="Center"/></Border><Border Background="#18527F" Margin="3" Padding="3"><TextBlock Text="Step 3" Foreground="White" TextAlignment="Center"/></Border><Border Background="#1E659B" Margin="3" Padding="3"><TextBlock Text="Step 4" Foreground="White" TextAlignment="Center"/></Border><Border Background="#2478B8" Margin="3" Padding="3"><TextBlock Text="Step 5" Foreground="White" TextAlignment="Center"/></Border><Border Background="#2D8FD5" Margin="3" Padding="3"><TextBlock Text="Step 6" Foreground="White" TextAlignment="Center"/></Border><Border Background="#3BA3E8" Margin="3" Padding="3"><TextBlock Text="Step 7" Foreground="White" TextAlignment="Center"/></Border><Border Background="#57B5F0" Margin="3" Padding="3"><TextBlock Text="Step 8a" Foreground="White" TextAlignment="Center"/></Border><Border Background="#75C7F8" Margin="3" Padding="3"><TextBlock Text="Step 8b" Foreground="White" TextAlignment="Center"/></Border></UniformGrid><UniformGrid Grid.Row="1" Rows="1" Columns="9"><Button x:Name="btnReadme" Content="Readme"/><Button x:Name="btnLoadConfig" Content="Load Config..."/><Button x:Name="btnSaveConfig" Content="Save Config..."/><Button x:Name="btnValidateTool" Content="Validate Tool"/><Button x:Name="btnGenerateDepotId" Content="Generate ID"/><Button x:Name="btnConnect" Content="Connect to VCF OPS"/><Button x:Name="btnDownloadDepot" Content="Download Depot"/><Button x:Name="btnUploadAll" Content="Upload VCF Binaries"/><Button x:Name="btnUploadFleet" Content="Upload Fleet Binaries"/></UniformGrid><StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4"><Button x:Name="btnStop" Content="Stop" Background="#5A1F1F" IsEnabled="False"/><CheckBox x:Name="chkAutoScroll" Content="Auto-scroll" IsChecked="True" Margin="12,6,0,0" VerticalAlignment="Center"/><CheckBox x:Name="chkDebug" Content="Debug" IsChecked="True" Margin="12,6,0,0" VerticalAlignment="Center"/><Label Content="Status:" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center" Margin="12,3,0,0"/><Label x:Name="lblStatus" Content="Ready" Foreground="#7CFF7C" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center" Margin="3,3,0,0"/></StackPanel></Grid></GroupBox><GroupBox Grid.Row="2" Header="Log"><TextBox x:Name="txtLog" FontFamily="Consolas" FontSize="12" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" IsReadOnly="True" Background="#000000" Foreground="#EDEDED"/></GroupBox></Grid></Window>
"@
$script:window=[Windows.Markup.XamlReader]::Parse($xaml)
foreach($n in @('txtToolPath','btnBrowseTool','txtDownloadDir','btnBrowseDownload','txtMetadataStageDir','btnBrowseMetadataStage','txtDepotId','btnCopyDepotId','txtActivationCode','chkIncludeUpgradeBinaries','chkIncludeEsx','txtVcfVersion','txtSku','txtOpsFqdn','txtFleetFqdn','txtOpsUser','pbOpsPassword','txtUploadRetries','btnReadme','btnLoadConfig','btnSaveConfig','btnValidateTool','btnGenerateDepotId','btnConnect','btnDownloadDepot','btnUploadAll','btnUploadFleet','btnStop','txtLog','chkAutoScroll','chkDebug','lblStatus')){Set-Variable -Name $n -Scope Script -Value $script:window.FindName($n)}
$script:btnReadme.Add_Click({try{Start-Process $script:ReadmeUrl}catch{}});$script:btnLoadConfig.Add_Click({Browse-ConfigOpen});$script:btnSaveConfig.Add_Click({Browse-ConfigSave});$script:btnBrowseTool.Add_Click({Browse-Folder $script:txtToolPath});$script:btnBrowseDownload.Add_Click({Browse-Folder $script:txtDownloadDir});$script:btnBrowseMetadataStage.Add_Click({Browse-Folder $script:txtMetadataStageDir});$script:btnCopyDepotId.Add_Click({if($script:txtDepotId.Text){[Windows.Clipboard]::SetText($script:txtDepotId.Text);Write-UiLog 'Software Depot ID copied to clipboard.'}});$script:btnValidateTool.Add_Click({try{$bat=Get-ToolBat;Write-UiLog "Validated VCF Download Tool path: $bat";[System.Windows.MessageBox]::Show("Validated:`n$bat",'VCF Download Tool','OK','Information')|Out-Null}catch{Write-UiLog $_.Exception.Message 'ERROR'}});$script:btnGenerateDepotId.Add_Click({try{Start-GenerateDepotId}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}});$script:btnConnect.Add_Click({try{Test-ConnectTargets}catch{Write-UiLog $_.Exception.Message 'ERROR'}});$script:btnDownloadDepot.Add_Click({try{Start-DownloadDepot}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}});$script:btnUploadAll.Add_Click({try{Start-UploadAll}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}});$script:btnUploadFleet.Add_Click({try{Start-UploadFleet}catch{Write-UiLog $_.Exception.Message 'ERROR';Set-Busy $false}});$script:btnStop.Add_Click({Stop-ActiveWork})
$script:window.Add_ContentRendered({Reset-TailState;New-RunDir;Write-UiLog "==== VCF Depot Sync Tool started $script:AppVersion ====";Write-UiLog "Run folder: $script:RunDir";Write-UiLog 'Download plan: metadata uses Local catalog staging, metadata is copied to Download directory, full INSTALL binaries download directly to Download directory. Tail monitor null-path errors are hard-suppressed and worker-only.';Remove-StaleSecretFiles})
$null=$script:window.ShowDialog()
