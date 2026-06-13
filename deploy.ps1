# =========================================================================
# deploy.ps1 -- one-shot ComfyUI server bootstrap for Windows (dual-GPU)
#
# Designed for the dual RTX PRO 6000 Blackwell box but auto-detects GPU count.
#
# Run as Administrator in PowerShell:
#
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\deploy.ps1 `
#       -CFTunnelToken 'eyJ...' `
#       -R2AccessKeyId '6345537623b9314ffe93a9421085dabc' `
#       -R2SecretKey '520e9d10a4d382f6f707b74f55bb61c3e071355bfeb4c21cfa9b415bd0964cec' `
#       -PullLoras
#
# Idempotent -- safe to re-run if a phase fails. State lives under -InstallRoot.
#
# Phases:
#   1. Preflight (admin, driver, GPU count, Python/Git)
#   2. Clone ComfyUI + create venv
#   3. Install PyTorch (cu126 Blackwell wheels) + requirements
#   4. Clone public custom nodes + wifemaker-comfy-addons private nodes
#   5. (Optional) Install rclone + pull LoRAs from R2
#   6. Generate start_dual_comfy.ps1 (one process per GPU)
#   7. (Optional) Install cloudflared as a Windows service
#   8. Register Task Scheduler entry for autostart at boot
#   9. Print fleet registration cheatsheet
# =========================================================================

[CmdletBinding()]
param(
    # Where everything lives. Default C:\waifumaster.
    [string]$InstallRoot = 'C:\waifumaster',

    # CF Tunnel token for `cloudflared service install`. Skip CF setup if empty.
    [string]$CFTunnelToken = '',

    # Subdomains -- one per GPU. If not given, auto-named pro6000a..b..c..
    [string[]]$Subdomains = @('pro6000a.bestyiever.vip','pro6000b.bestyiever.vip'),

    # Per-GPU local ports.  Defaults match the Linux fleet (8190, 8189, 8188...).
    [int]$PortStart = 8190,

    # R2 / LoRA sync.  Leave both empty + don't set -PullLoras to skip.
    [string]$R2AccessKeyId  = '',
    [string]$R2SecretKey    = '',
    [string]$R2Endpoint     = 'https://c8efd2af5d0b88632ab3d997fca8542b.r2.cloudflarestorage.com',
    [string]$R2Bucket       = 'bestyiever-loras',
    [switch]$PullLoras,
    [string[]]$PullLoraGlobs = @('*'),   # '*' = everything

    # Repo for the private addons (uploader + lora_cleaner).
    [string]$AddonsRepoUrl = 'https://github.com/liuyi530975719/wifemaker-comfy-addons',
    [string]$AddonsBranch  = 'main',

    # Override GPU detection if you want.
    [int]$ForceGpuCount = 0,

    [switch]$SkipCFTunnel,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----- Pretty logging ---------------------------------------------------- #
function Phase($n, $msg) { Write-Host ("`n=== Phase {0}: {1} ===" -f $n, $msg) -ForegroundColor Cyan }
function Log  ($msg)     { Write-Host "[deploy] $msg" -ForegroundColor Gray }
function Ok   ($msg)     { Write-Host "[deploy] $msg" -ForegroundColor Green }
function Warn ($msg)     { Write-Host "[deploy] $msg" -ForegroundColor Yellow }
function Die  ($msg)     { Write-Host "[deploy] $msg" -ForegroundColor Red; exit 1 }

function Invoke-Step($cmd) {
    if ($DryRun) { Write-Host "  [DRY] $cmd" -ForegroundColor DarkGray; return }
    Write-Host "  $cmd" -ForegroundColor DarkGray
    & powershell.exe -NoProfile -Command $cmd
    if ($LASTEXITCODE -ne 0) { Die "step failed: $cmd" }
}

# ========================================================================
# Phase 1 -- Preflight
# ========================================================================
Phase 1 'Preflight (admin, driver, Python, Git)'

# Admin check
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($me)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "Must run in an elevated PowerShell. Right-click PowerShell -> Run as Administrator."
}
Ok 'running as Administrator'

# GPU count via nvidia-smi
try {
    $gpuList = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null
    if (-not $gpuList) { throw "no GPUs reported" }
    $gpuLines = @($gpuList) | Where-Object { $_ -and ($_.Trim().Length -gt 0) }
    $gpuCount = if ($ForceGpuCount -gt 0) { $ForceGpuCount } else { $gpuLines.Count }
    Ok "detected $gpuCount GPU(s):"
    $gpuLines | ForEach-Object { Write-Host "    $_" }
} catch {
    Die "nvidia-smi not found or no GPUs. Install NVIDIA driver R555+ for Blackwell first."
}

# Driver version sanity check -- Blackwell wants 555+
try {
    $drv = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader)[0].Trim()
    $drvMajor = [int]($drv.Split('.')[0])
    if ($drvMajor -lt 555) { Warn "driver $drv may be too old for Blackwell SM_120. Recommend 555+." }
    else { Ok "driver $drv looks Blackwell-ready" }
} catch { Warn "could not parse driver version" }

# Python + Git -- detect by RUNNING the tool and parsing output, not by
# trusting Get-Command (the MS Store stub registers as a valid command) or
# winget exit codes (winget returns non-zero when "already installed, no
# upgrade needed" which is actually success for our purposes).

function Test-PythonReal {
    # Real Python prints "Python 3.x.y". MS Store stub prints "Python was not
    # found; run without arguments to install from the Microsoft Store..."
    try {
        $out = (& python --version 2>&1 | Out-String).Trim()
        return ($out -match '^Python \d+\.\d+\.\d+')
    } catch { return $false }
}

function Test-Git {
    try {
        $out = (& git --version 2>&1 | Out-String).Trim()
        return ($out -match '^git version')
    } catch { return $false }
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + `
                [Environment]::GetEnvironmentVariable('Path','User')
}

# ---- Python ----
if (Test-PythonReal) {
    Ok "Python detected: $((& python --version 2>&1).Trim())"
} else {
    Log 'installing Python 3.12 via winget (this may take a minute)...'
    if (-not $DryRun) {
        & winget install --id Python.Python.3.12 --silent `
            --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
        # Ignore winget exit code entirely -- "already installed" returns non-zero
        # but is fine. Refresh PATH and re-test.
        Refresh-Path
        if (-not (Test-PythonReal)) {
            Die @"
Python still not callable after winget install.
This usually means the Microsoft Store 'python.exe' app-execution-alias is
intercepting. Open: Settings -> Apps -> Advanced app settings ->
App execution aliases. Turn OFF python.exe AND python3.exe. Then open a
fresh admin PowerShell and re-run this script.
"@
        }
        Ok "Python installed: $((& python --version 2>&1).Trim())"
    }
}

# ---- Git ----
if (Test-Git) {
    Ok "Git detected: $((& git --version 2>&1).Trim())"
} else {
    Log 'installing Git via winget...'
    if (-not $DryRun) {
        & winget install --id Git.Git --silent `
            --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
        Refresh-Path
        if (-not (Test-Git)) { Die 'Git still not callable after winget install.' }
        Ok "Git installed: $((& git --version 2>&1).Trim())"
    }
}

# Disk space -- need ~200GB for full LoRA sync
$driveLetter = (Split-Path -Qualifier $InstallRoot).TrimEnd(':')
$drv = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
if ($drv) {
    $freeGB = [Math]::Round($drv.Free / 1GB, 1)
    Ok "$($driveLetter): drive has $freeGB GB free"
    if ($PullLoras -and $freeGB -lt 200) { Warn "less than 200GB free -- full LoRA sync may not fit" }
} else { Warn "could not check drive space" }

# ========================================================================
# Phase 2 -- Layout + clone ComfyUI
# ========================================================================
Phase 2 'Clone ComfyUI'

$ComfyDir   = Join-Path $InstallRoot 'ComfyUI'
$LogsDir    = Join-Path $InstallRoot 'logs'
$ToolsDir   = Join-Path $InstallRoot 'tools'
$VenvDir    = Join-Path $InstallRoot '.venv'
$ScriptsDir = Join-Path $InstallRoot 'scripts'

foreach ($d in @($InstallRoot, $LogsDir, $ToolsDir, $ScriptsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Ok "layout under $InstallRoot"

if (Test-Path (Join-Path $ComfyDir '.git')) {
    Ok 'ComfyUI already cloned -- pulling latest'
    if (-not $DryRun) { Push-Location $ComfyDir; git pull --rebase 2>&1 | Out-Host; Pop-Location }
} else {
    Log "git clone ComfyUI -> $ComfyDir"
    if (-not $DryRun) { git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git $ComfyDir }
}

# ========================================================================
# Phase 3 -- Python venv + PyTorch (cu126 for Blackwell SM_120) + requirements
# ========================================================================
Phase 3 'Python venv + PyTorch + requirements'

if (-not (Test-Path (Join-Path $VenvDir 'Scripts\python.exe'))) {
    Log "create venv at $VenvDir"
    if (-not $DryRun) { python -m venv $VenvDir }
}
$Py    = Join-Path $VenvDir 'Scripts\python.exe'
$Pip   = Join-Path $VenvDir 'Scripts\pip.exe'

Log 'upgrade pip + install PyTorch cu126 (Blackwell-compatible)'
if (-not $DryRun) {
    & $Py -m pip install --upgrade pip wheel setuptools
    # PyTorch 2.6+ with CUDA 12.6 wheels -- has full SM_120 (Blackwell) kernels.
    & $Pip install --upgrade torch torchvision torchaudio `
        --index-url https://download.pytorch.org/whl/cu126
    if ($LASTEXITCODE -ne 0) {
        Warn 'cu126 wheel install failed -- falling back to cu124'
        & $Pip install --upgrade torch torchvision torchaudio `
            --index-url https://download.pytorch.org/whl/cu124
    }
}

Log 'install ComfyUI requirements'
if (-not $DryRun) {
    # Pin already-installed torch so requirements.txt does not yank it
    $pinFile = Join-Path $env:TEMP 'torch_pin.txt'
    & $Py -c "import torch, torchvision, torchaudio; print(f'torch=={torch.__version__}'); print(f'torchvision=={torchvision.__version__}'); print(f'torchaudio=={torchaudio.__version__}')" | Out-File -Encoding ascii $pinFile
    Get-Content $pinFile | ForEach-Object { Write-Host "    pin: $_" -ForegroundColor DarkGray }
    & $Pip install -r (Join-Path $ComfyDir 'requirements.txt') -c $pinFile
}

# Quick CUDA smoke test
if (-not $DryRun) {
    $cudaCheck = & $Py -c "import torch; print('cuda_ok', torch.cuda.is_available(), torch.cuda.device_count())"
    Ok "torch CUDA check: $cudaCheck"
}

# ========================================================================
# Phase 4 -- Custom nodes (public packs + private addons)
# ========================================================================
Phase 4 'Custom nodes -- public packs + private addons'

$CustomNodes = Join-Path $ComfyDir 'custom_nodes'
if (-not (Test-Path $CustomNodes)) { New-Item -ItemType Directory -Path $CustomNodes -Force | Out-Null }

$PublicNodes = @(
    'https://github.com/ltdrdata/ComfyUI-Manager',
    'https://github.com/ltdrdata/ComfyUI-Impact-Pack',
    'https://github.com/ltdrdata/ComfyUI-Impact-Subpack',
    'https://github.com/ssitu/ComfyUI_UltimateSDUpscale',
    'https://github.com/Fannovel16/comfyui_controlnet_aux',
    'https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite',
    'https://github.com/cubiq/ComfyUI_essentials'
)
foreach ($url in $PublicNodes) {
    $name = ($url.Split('/')[-1]) -replace '\.git$',''
    $tgt  = Join-Path $CustomNodes $name
    if (Test-Path (Join-Path $tgt '.git')) {
        Ok "$name already cloned"
    } else {
        Log "git clone $name"
        if (-not $DryRun) { git clone --depth 1 $url $tgt }
    }
    $req = Join-Path $tgt 'requirements.txt'
    if ((Test-Path $req) -and (-not $DryRun)) {
        & $Pip install -r $req --no-deps 2>$null | Out-Host
    }
}

# Private addons -- clone wifemaker-comfy-addons, then symlink the two node folders
$AddonsTmp = Join-Path $env:TEMP 'wifemaker-comfy-addons'
if (Test-Path $AddonsTmp) { Remove-Item -Recurse -Force $AddonsTmp }
if (-not $DryRun) {
    git clone --depth 1 --branch $AddonsBranch $AddonsRepoUrl $AddonsTmp
    foreach ($n in @('comfy_model_uploader','comfy_lora_cleaner')) {
        $src = Join-Path $AddonsTmp $n
        $dst = Join-Path $CustomNodes $n
        if (Test-Path $src) {
            if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
            Copy-Item -Recurse $src $dst
            $req = Join-Path $dst 'requirements.txt'
            if (Test-Path $req) { & $Pip install -r $req 2>&1 | Out-Host }
            Ok "installed addon: $n"
        }
    }
}

# ========================================================================
# Phase 5 -- rclone + R2 LoRA sync (optional)
# ========================================================================
Phase 5 'rclone install + R2 LoRA sync'

if ($PullLoras) {
    if (-not ($R2AccessKeyId -and $R2SecretKey)) {
        Die "-PullLoras given but -R2AccessKeyId / -R2SecretKey are empty"
    }
    $RcloneExe = Join-Path $ToolsDir 'rclone.exe'
    if (-not (Test-Path $RcloneExe)) {
        Log 'downloading rclone for Windows...'
        $zip = Join-Path $env:TEMP 'rclone.zip'
        if (-not $DryRun) {
            Invoke-WebRequest -UseBasicParsing 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile $zip
            $unzipDir = Join-Path $env:TEMP 'rclone-unzip'
            if (Test-Path $unzipDir) { Remove-Item -Recurse -Force $unzipDir }
            Expand-Archive -Force $zip $unzipDir
            $src = Get-ChildItem -Recurse -Filter rclone.exe $unzipDir | Select-Object -First 1
            Copy-Item $src.FullName $RcloneExe
            Ok "rclone -> $RcloneExe"
        }
    } else { Ok 'rclone already installed' }

    # Write rclone config (per-invocation env vars also work but config is tidier)
    $rcloneConf = Join-Path $env:APPDATA 'rclone\rclone.conf'
    $rcloneConfDir = Split-Path $rcloneConf -Parent
    if (-not (Test-Path $rcloneConfDir)) { New-Item -ItemType Directory -Path $rcloneConfDir -Force | Out-Null }
    if (-not $DryRun) {
@"
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2AccessKeyId
secret_access_key = $R2SecretKey
endpoint = $R2Endpoint
acl = private
"@ | Out-File -Encoding ascii $rcloneConf
        Ok 'rclone config written'
    }

    # Target dirs in ComfyUI
    $ModelsRoot = Join-Path $ComfyDir 'models'
    foreach ($sub in @('loras','checkpoints')) {
        $d = Join-Path $ModelsRoot $sub
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Sync LoRAs (default: '*' = whole bucket subtree under loras/)
    foreach ($glob in $PullLoraGlobs) {
        Log "rclone copy r2:$R2Bucket/$glob -> $ModelsRoot\loras"
        if (-not $DryRun) {
            & $RcloneExe copy "r2:$R2Bucket/$glob" (Join-Path $ModelsRoot 'loras') `
                --transfers 8 --checkers 16 --progress
        }
    }
    Ok 'LoRA sync complete'
} else {
    Warn 'PullLoras flag not set -- skipping LoRA sync (you can run this phase again later)'
}

# ========================================================================
# Phase 6 -- Generate dual-GPU start script
# ========================================================================
Phase 6 "Generate start_comfy.ps1 (one process per GPU)"

$startPs1 = Join-Path $ScriptsDir 'start_comfy.ps1'

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Auto-generated by deploy.ps1 -- starts one ComfyUI process per GPU.')
[void]$sb.AppendLine('# Each process pins a single GPU via CUDA_VISIBLE_DEVICES + its own user dir')
[void]$sb.AppendLine('# (output / temp / user_settings) so they do not stomp each other on disk.')
[void]$sb.AppendLine('$ErrorActionPreference = ''Stop''')
[void]$sb.AppendLine("`$ComfyDir = '$ComfyDir'")
[void]$sb.AppendLine("`$LogsDir  = '$LogsDir'")
[void]$sb.AppendLine("`$Py       = '$Py'")
[void]$sb.AppendLine('Set-Location $ComfyDir')
[void]$sb.AppendLine('if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }')
[void]$sb.AppendLine('')
for ($i = 0; $i -lt $gpuCount; $i++) {
    $port = $PortStart - $i
    $tag  = [char](97 + $i)
    [void]$sb.AppendLine("# ----- GPU $i  port $port  tag $tag -----")
    [void]$sb.AppendLine("`$env:CUDA_VISIBLE_DEVICES = '$i'")
    [void]$sb.AppendLine("`$userDir = Join-Path `$ComfyDir 'user_$tag'")
    [void]$sb.AppendLine("if (-not (Test-Path `$userDir)) { New-Item -ItemType Directory -Path `$userDir -Force | Out-Null }")
    [void]$sb.AppendLine("Start-Process -FilePath `$Py -ArgumentList @('main.py','--listen','0.0.0.0','--port','$port','--highvram','--user-directory',`$userDir,'--output-directory',(Join-Path `$userDir 'output'),'--temp-directory',(Join-Path `$userDir 'temp')) -RedirectStandardOutput (Join-Path `$LogsDir 'comfy_$tag.log') -RedirectStandardError (Join-Path `$LogsDir 'comfy_${tag}_err.log') -WorkingDirectory `$ComfyDir -WindowStyle Hidden")
    [void]$sb.AppendLine("Write-Host 'started GPU $i  port $port  log: ' (Join-Path `$LogsDir 'comfy_$tag.log')")
    [void]$sb.AppendLine('Start-Sleep -Seconds 2')
    [void]$sb.AppendLine('')
}
[void]$sb.AppendLine('Write-Host ''ComfyUI processes launched. Tail logs:'' -ForegroundColor Green')
[void]$sb.AppendLine('Write-Host ''  Get-Content -Wait $LogsDir\comfy_a.log''')
[void]$sb.AppendLine('Write-Host ''  Get-Content -Wait $LogsDir\comfy_b.log''')

if (-not $DryRun) {
    $sb.ToString() | Out-File -Encoding ascii $startPs1
    Ok "wrote $startPs1"
}

$stopPs1 = Join-Path $ScriptsDir 'stop_comfy.ps1'
@"
# Auto-generated. Kills every python.exe under `$ComfyDir.
Get-CimInstance Win32_Process |
    Where-Object { `$_.ExecutablePath -and `$_.ExecutablePath.StartsWith('$VenvDir') } |
    ForEach-Object { Write-Host "killing PID `$(`$_.ProcessId)"; Stop-Process -Id `$_.ProcessId -Force }
"@ | Out-File -Encoding ascii $stopPs1
Ok "wrote $stopPs1"

# ========================================================================
# Phase 7 -- cloudflared service install
# ========================================================================
Phase 7 'cloudflared install + service'

if ($SkipCFTunnel -or (-not $CFTunnelToken)) {
    Warn 'CF tunnel skipped -- bring your own networking (port-forward, Tailscale, etc.)'
} else {
    $CloudflaredExe = Join-Path $ToolsDir 'cloudflared.exe'
    if (-not (Test-Path $CloudflaredExe)) {
        Log 'downloading cloudflared.exe...'
        if (-not $DryRun) {
            Invoke-WebRequest -UseBasicParsing `
                'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' `
                -OutFile $CloudflaredExe
            Ok "cloudflared -> $CloudflaredExe"
        }
    } else { Ok 'cloudflared already present' }

    # Install as Windows service. Uninstall first in case of stale config.
    if (-not $DryRun) {
        Log 'cloudflared service uninstall (best-effort)'
        & $CloudflaredExe service uninstall 2>$null | Out-Host
        Log 'cloudflared service install <token>'
        & $CloudflaredExe service install $CFTunnelToken
        if ($LASTEXITCODE -ne 0) { Die 'cloudflared service install failed' }
        Start-Service cloudflared -ErrorAction SilentlyContinue
        Ok 'cloudflared service running'
    }
}

# ========================================================================
# Phase 8 -- Task Scheduler autostart
# ========================================================================
Phase 8 'Register Task Scheduler autostart'

$TaskName = 'WaifumasterComfyUI'
if (-not $DryRun) {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startPs1`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 `
                  -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit 0
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Start ComfyUI on all GPUs at boot' | Out-Null
    Ok "Task Scheduler entry registered: $TaskName"
}

# ========================================================================
# Phase 9 -- Final summary + fleet registration cheatsheet
# ========================================================================
Phase 9 'Done -- fleet registration cheatsheet'

Write-Host ''
Write-Host '=================================================================' -ForegroundColor Green
Write-Host '  ComfyUI deployment complete on this machine.' -ForegroundColor Green
Write-Host '=================================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Start ComfyUI right now (without rebooting):' -ForegroundColor Yellow
Write-Host "  & '$startPs1'"
Write-Host ''
Write-Host 'Tail the per-GPU logs:' -ForegroundColor Yellow
for ($i = 0; $i -lt $gpuCount; $i++) {
    $tag = [char](97 + $i)
    Write-Host "  Get-Content -Wait '$LogsDir\comfy_$tag.log'"
}
Write-Host ''
Write-Host 'CloudFlare dashboard -- add these public hostnames to your tunnel:' -ForegroundColor Yellow
for ($i = 0; $i -lt $gpuCount; $i++) {
    $port = $PortStart - $i
    $sub  = if ($i -lt $Subdomains.Count) { $Subdomains[$i] } else { "pro6000$([char](97+$i)).bestyiever.vip" }
    Write-Host "  $sub  ->  http://localhost:$port"
}
Write-Host ''
Write-Host 'Then in waifumaster admin, add each subdomain as a new server with:' -ForegroundColor Yellow
Write-Host "  auth_mode = cloudflare_access  (same CF Access service token as the rest of the fleet)"
Write-Host '  max_concurrent = 1   (pregen scheduler now enforces this)'
Write-Host '  default_face_detailer = 0    (skip on pregen for speed)'
Write-Host '  default_upscaler = 1         (USDU is the main quality lever)'
Write-Host ''
Ok 'all phases complete'
