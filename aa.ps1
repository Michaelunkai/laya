# ==========================================
# Laya & Claude Code Launcher
# ==========================================
# Starts (or reuses) the local laya decision server, proves it answers the exact
# questions the laya-model-router plugin asks, then launches Claude Code with the
# plugin loaded so every task is routed to the right Claude tier + effort.
#
#   .\aa.ps1                  start laya, launch claude in the CURRENT directory
#   .\aa.ps1 -SelfTest        verify everything end to end, then exit (no claude)
#   .\aa.ps1 -Restart         replace a laya server that is already running
#   .\aa.ps1 -KeepServer      leave the laya server running after claude exits
#   .\aa.ps1 --resume ...     any other arguments are passed through to claude
#
# Env: LAYA_PORT (default 8756), LAYA_PYTHON (python.exe to use), LAYA_DEVICE.
# Works in Windows PowerShell 5.1 and PowerShell 7.

# Parsed by hand (no param block): a CmdletBinding would swallow claude's own
# -p / --verbose / --resume flags as PowerShell common parameters.
$SelfTest = $false; $Restart = $false; $KeepServer = $false; $KeepEnv = $false
$ClaudeArgs = @()
foreach ($a in $args) {
    switch -Regex ("$a") {
        '^-SelfTest$'   { $SelfTest = $true; continue }
        '^-Restart$'    { $Restart = $true; continue }
        '^-KeepServer$' { $KeepServer = $true; continue }
        '^-KeepEnv$'    { $KeepEnv = $true; continue }
        default         { $ClaudeArgs += "$a" }
    }
}

$ErrorActionPreference = "Stop"
$MinClaudeVersion = [version]"2.1.259"   # function hooks do not exist before this

$LayaPort = if ($env:LAYA_PORT) { $env:LAYA_PORT } else { "8756" }
$BaseUrl  = "http://127.0.0.1:$LayaPort"

$root      = $PSScriptRoot
$targetDir = Join-Path $root "laya-integration"
$serverDir = Join-Path $targetDir "laya-server"
$pluginDir = Join-Path $targetDir "laya-model-router"
$serverPy  = Join-Path $serverDir "laya_server.py"
$reqFile   = Join-Path $serverDir "requirements.txt"
$startDir  = (Get-Location).Path          # claude works where the user ran this

function Step($m) { Write-Host $m -ForegroundColor Yellow }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Info($m) { Write-Host $m -ForegroundColor Gray }

# ---- 0. Preconditions ----------------------------------------------------------
foreach ($p in @($serverPy, $pluginDir, (Join-Path $pluginDir "hooks\hooks.json"))) {
    if (-not (Test-Path $p)) { throw "Missing required path: $p" }
}

# -CommandType Application: bypass profile functions/aliases named claude (they have no .Source).
$claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claudeCmd) { throw "Claude Code CLI ('claude') was not found in PATH." }
$verText = (& $claudeCmd.Source --version 2>&1 | Out-String)
if ($verText -notmatch '(\d+\.\d+\.\d+)') { throw "Could not read claude version from: $verText" }
$claudeVer = [version]$Matches[1]
if ($claudeVer -lt $MinClaudeVersion) {
    throw "Claude Code $claudeVer is too old; the laya plugin needs >= $MinClaudeVersion (npm install -g @anthropic-ai/claude-code)."
}

# Pick a python that already has laya, else the first python on PATH (deps get installed below).
$pythonExe = $null
$candidates = @()
if ($env:LAYA_PYTHON) { $candidates += $env:LAYA_PYTHON }
$candidates += (Join-Path $targetDir ".venv\Scripts\python.exe")   # CUDA venv, preferred when present
$candidates += @(Get-Command python -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
foreach ($c in $candidates) {
    if (-not $c -or -not (Test-Path $c)) { continue }
    & $c -c "import laya" 2>$null
    if ($LASTEXITCODE -eq 0) { $pythonExe = $c; break }
}
if (-not $pythonExe -and $candidates.Count -gt 0) { $pythonExe = ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1) }
if (-not $pythonExe) { throw "Python ('python') was not found in PATH." }

function Invoke-Laya([string]$Path, $Body, [int]$TimeoutSec = 5) {
    if ($null -ne $Body) {
        return Invoke-RestMethod -Uri "$BaseUrl$Path" -Method Post -Body $Body -ContentType "application/json" -TimeoutSec $TimeoutSec
    }
    return Invoke-RestMethod -Uri "$BaseUrl$Path" -Method Get -TimeoutSec $TimeoutSec
}

function Get-LayaHealth {
    try {
        $h = Invoke-Laya "/health" $null 2
        if ($h.status -eq "ok" -and $h.ready) { return $h }
    } catch { }
    return $null
}

function Test-PortListening {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", [int]$LayaPort, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

# The exact questions laya-model-router asks (hooks/policy.ts), so the probe tests the real contract.
function New-DecideBody([string]$Task) {
    $q = [ordered]@{
        tier = [ordered]@{
            type = "choice"
            instructions = "Which is the cheapest tier that can complete this coding task well?"
            criteria = [ordered]@{
                fast     = "Mechanical and local: read or summarise a file, run one command, rename a symbol, answer something already in context."
                balanced = "Ordinary engineering: implement a well-specified change across a few files, write tests, fix a clearly described bug, review a small diff."
                deep     = "Hard or high-stakes: architecture and design, debugging a failure whose cause is unknown, security, data migrations, concurrency, anything touching production or money."
            }
        }
        effort = [ordered]@{
            type = "score"
            instructions = "How much step-by-step reasoning does this task need?"
            criteria = @("almost none", "some", "a lot", "as much as possible")
        }
        risky = [ordered]@{
            type = "noul"
            instructions = "Carrying out this task would itself change production, move real money, or alter data that cannot be undone."
        }
    }
    return (@{ model = "laya"; state = @{ prompt = $Task }; questions = $q } | ConvertTo-Json -Depth 8 -Compress)
}

function Test-Decision([string]$Task) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Laya "/v1/decide" (New-DecideBody $Task) 10
    $sw.Stop()
    $a = $r.answers
    if (-not $a -or -not $a.tier -or $a.tier.choice -notin @("fast", "balanced", "deep")) {
        throw "laya returned an unusable decision for '$Task': $($r | ConvertTo-Json -Depth 6 -Compress)"
    }
    return [pscustomobject]@{
        Task = $Task; Tier = $a.tier.choice; TierConf = $a.tier.confidence
        Effort = $a.effort.score; Risky = $a.risky.noul; Ms = [int]$sw.ElapsedMilliseconds
    }
}

Write-Host "=== Starting Laya & Claude Code ===" -ForegroundColor Cyan
Info "claude $claudeVer | python $pythonExe | laya $BaseUrl"

# ---- 1. Python dependencies (installed only when missing) ----------------------
& $pythonExe -c "import laya, transformers, torch" 2>$null
if ($LASTEXITCODE -ne 0) {
    Step "Installing laya server dependencies (first run only)..."
    $env:HF_HUB_DISABLE_XET = "1"
    & $pythonExe -m pip install -r $reqFile
    if ($LASTEXITCODE -ne 0) { throw "pip install -r requirements.txt failed" }
}

# ---- 2. Reuse a healthy server, or (re)start one ------------------------------
$serverProcess = $null
$weStartedIt = $false
$health = Get-LayaHealth

if ($health -and -not $Restart) {
    Ok "Reusing running laya server (model=$($health.model), device=$($health.device))."
} else {
    if (Test-PortListening) {
        $listeners = Get-NetTCPConnection -LocalPort ([int]$LayaPort) -State Listen -ErrorAction SilentlyContinue
        foreach ($l in $listeners) {
            if (-not $l.OwningProcess) { continue }
            $proc = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
            $isLaya = $health -or ($proc -and $proc.ProcessName -match '^python')
            if (-not $isLaya) {
                throw "Port $LayaPort is held by '$($proc.ProcessName)' (PID $($l.OwningProcess)), which is not a laya/python server. Set LAYA_PORT to a free port."
            }
            Step "Replacing old listener on port $LayaPort (PID $($l.OwningProcess), $($proc.ProcessName))..."
            Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
        }
        $t = 0
        while ((Test-PortListening) -and $t -lt 20) { Start-Sleep -Milliseconds 250; $t++ }
        if (Test-PortListening) { throw "Port $LayaPort is still busy after stopping the old listener." }
    }

    $env:LAYA_PORT = $LayaPort
    if (-not $env:HF_HUB_DISABLE_XET) { $env:HF_HUB_DISABLE_XET = "1" }
    $logDir = Join-Path $env:TEMP "laya"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $outLog = Join-Path $logDir "laya-server.out.log"
    $errLog = Join-Path $logDir "laya-server.err.log"

    Step "Starting laya server on port $LayaPort (hidden)..."
    $serverProcess = Start-Process -FilePath $pythonExe `
        -ArgumentList "`"$serverPy`"" `
        -WorkingDirectory $serverDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru
    $weStartedIt = $true
    Ok "Laya server PID: $($serverProcess.Id)  logs: $logDir"

    $deadline = (Get-Date).AddSeconds(240)   # first run downloads/loads the model
    while (-not ($health = Get-LayaHealth)) {
        if ($serverProcess.HasExited) {
            $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 15) -join "`n" } else { "" }
            throw "laya server exited early (exit $($serverProcess.ExitCode)). See $errLog`n$tail"
        }
        if ((Get-Date) -gt $deadline) {
            Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
            throw "laya server was not ready within 240s. See $errLog"
        }
        Start-Sleep -Milliseconds 500
    }
    Ok "Laya server ready on 127.0.0.1:$LayaPort (device=$($health.device))."
}

function Stop-OurServer {
    if ($weStartedIt -and $serverProcess -and -not $KeepServer -and -not $serverProcess.HasExited) {
        Info "Stopping laya server (PID $($serverProcess.Id))..."
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

$anthropicVars = @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_SMALL_FAST_MODEL','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC')
$savedEnv = @{}
try {
    # ---- 3. Prove the contract: the real questions, easy vs hard task ----------
    Step "Probing laya with the router's exact questions..."
    $null = Test-Decision "warm up"   # absorb any first-call latency
    $easy = Test-Decision "rename the variable foo to bar in utils.py"
    $hard = Test-Decision "design a fault-tolerant distributed lock manager and find the race conditions in our payment migration on production"
    foreach ($d in @($easy, $hard)) {
        Info ("  [{0,-4} ms] tier={1} ({2:N2}) effort={3:N2} risky={4:N2}  <- {5}" -f $d.Ms, $d.Tier, $d.TierConf, $d.Effort, $d.Risky, $d.Task.Substring(0, [Math]::Min(55, $d.Task.Length)))
    }
    if ($easy.Tier -eq $hard.Tier -and $easy.Effort -eq $hard.Effort) {
        Write-Warning "laya gave the easy and hard task identical decisions; routing may not be discriminating."
    }
    if ($easy.Ms -gt 800 -or $hard.Ms -gt 800) {
        Write-Warning "laya took >800ms (the plugin's default timeoutMs); on a slow device set LAYA_DEVICE=cuda or raise timeoutMs, else it falls back to the built-in classifier."
    }
    Ok "laya decision contract OK."

    if ($LayaPort -ne "8756") {
        Write-Warning "Non-default port: set pluginConfigs -> laya-model-router -> options.layaBaseUrl = $BaseUrl in ~/.claude/settings.json, or the plugin will look on 8756."
    }

    # ---- 4. Verify claude accepts the plugin -----------------------------------
    Step "Validating the plugin with claude..."
    $env:CLAUDE_CODE_ENABLE_FUNCTION_HOOKS = "1"
    $v = & $claudeCmd.Source plugin validate $pluginDir 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "claude plugin validate failed:`n$v" }
    Ok "Plugin validated."

    if ($SelfTest) {
        Ok "SELFTEST PASSED: server, decisions, plugin all good."
        return
    }

    # ---- 5. Launch Claude Code in the caller's directory with the plugin -------
    Set-Location $startDir
    # Plain `claude` in this profile uses the claude.ai login: a stale user-level
    # ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL (litellm bridge) breaks it with "No connected db".
    if (-not $KeepEnv) {
        foreach ($n in $anthropicVars) {
            $v = [Environment]::GetEnvironmentVariable($n, "Process")
            if ($null -ne $v) { $savedEnv[$n] = $v; Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        }
    }
    Write-Host "Launching Claude Code session in $startDir ..." -ForegroundColor Cyan
    & $claudeCmd.Source --plugin-dir "$pluginDir" @ClaudeArgs
}
finally {
    foreach ($k in $savedEnv.Keys) { Set-Item "Env:$k" $savedEnv[$k] }
    Stop-OurServer
}
