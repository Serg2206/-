<#
.SYNOPSIS
    Диагностика MCP-сервера Hermes: прямой запуск hermes.exe против обёртки hermes-mcp.ps1.
.DESCRIPTION
    Без -Apply — только проверка. С -Apply и при успешном прямом запуске переписывает блок
    [mcp_servers.hermes-tools] в config.toml Codex на прямой вызов hermes.exe (с копией конфига).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-HermesMcp.ps1
    powershell -ExecutionPolicy Bypass -File .\Test-HermesMcp.ps1 -Apply
#>
param([switch]$Apply, [int]$TimeoutSec = 120)
$ErrorActionPreference = 'Continue'
$wh       = 'E:\WorkHub'
$hermes   = "$wh\.hermes-venv313\Scripts\hermes.exe"
$codexCfg = "$env:USERPROFILE\.codex\config.toml"
$utf8     = New-Object Text.UTF8Encoding $false

function Write-Head($t) { Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }
function Write-Info($t) { Write-Host "  $t" }
function Hide-Secrets([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '(sk-|sk_|ghp_|xox[bp]-|AIza|hf_|xai-)[A-Za-z0-9_\-]{6,}', '[скрыто]')
    return [regex]::Replace($s, '(?i)((api[_-]?key|token|secret|password)["'']?\s*[:=]\s*["'']?)[^\s"'',]+', '$1[скрыто]')
}

function Test-McpServer($fileName, $arguments, $label) {
    Write-Info "Запуск: $label"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $fileName; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $wh
    $psi.EnvironmentVariables['HERMES_HOME'] = "$wh\.hermes"
    $psi.EnvironmentVariables['CODEX_HOME'] = "$env:USERPROFILE\.codex"
    $psi.EnvironmentVariables['HERMES_REDACT_SECRETS'] = 'true'
    $psi.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ssv-check","version":"1.0"}}}')
    $p.StandardInput.Flush()
    $ok = $false; $other = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
        $t = $p.StandardOutput.ReadLineAsync()
        $left = [int]([math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds))
        if (-not $t.Wait($left)) { break }
        $line = $t.Result
        if ($null -eq $line) { break }
        if ($line -match '"id"\s*:\s*1' -and $line -match '"result"') {
            $ok = $true
            $name = ([regex]::Match($line, '"serverInfo"\s*:\s*\{[^}]*"name"\s*:\s*"([^"]+)"')).Groups[1].Value
            Write-Host ("  [OK] Ответ за {0:N1} сек: {1}" -f $sw.Elapsed.TotalSeconds, $name) -ForegroundColor Green
            $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
            $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}'); $p.StandardInput.Flush()
            $t2 = $p.StandardOutput.ReadLineAsync()
            if ($t2.Wait(20000) -and $t2.Result) {
                $tools = [regex]::Matches($t2.Result, '"name"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
                Write-Info ("Инструментов: {0}. Примеры: {1}" -f @($tools).Count, (($tools | Select-Object -First 15) -join ', '))
            }
            break
        } else { $other += $line }
    }
    if (-not $ok) { Write-Host ("  [FAIL] Нет ответа за {0:N0} сек (процесс {1})" -f $sw.Elapsed.TotalSeconds, $(if ($p.HasExited) { "завершился, код $($p.ExitCode)" } else { 'висел' })) -ForegroundColor Red }
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    if ($other.Count) { Write-Info 'Лишние строки в stdout (мешают протоколу MCP):'; $other | Select-Object -First 10 | ForEach-Object { Write-Info ("   " + (Hide-Secrets $_)) } }
    $err = if ($errTask.Wait(5000)) { $errTask.Result } else { '' }
    if ($err) { Write-Info 'stderr (последние строки):'; ($err -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 20) | ForEach-Object { Write-Info ("   " + (Hide-Secrets $_)) } }
    return $ok
}

if (-not (Test-Path $hermes)) { Write-Host "Нет $hermes" -ForegroundColor Red; exit 1 }

Write-Head '1. КОМАНДЫ MCP В HERMES'
$env:HERMES_HOME = "$wh\.hermes"
& $hermes mcp --help 2>&1 | Select-Object -First 30 | ForEach-Object { Write-Info $_ }

Write-Head '2. ПРЯМОЙ ЗАПУСК hermes.exe mcp serve'
$direct = Test-McpServer $hermes 'mcp serve' 'hermes.exe mcp serve'

Write-Head '3. ЗАПУСК ЧЕРЕЗ ОБЁРТКУ hermes-mcp.ps1'
$wrapped = Test-McpServer 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$wh\hermes-mcp.ps1`"" 'powershell -File hermes-mcp.ps1'

Write-Head '4. ВЫВОД И НАСТРОЙКА CODEX'
if ($direct) {
    Write-Info 'Hermes MCP работает при прямом запуске. Правильная настройка Codex — вызывать hermes.exe напрямую:'
    $block = @'
[mcp_servers.hermes-tools]
command = 'E:\WorkHub\.hermes-venv313\Scripts\hermes.exe'
args = ["mcp", "serve"]
startup_timeout_sec = 120
env = { HERMES_HOME = 'E:\WorkHub\.hermes', HERMES_REDACT_SECRETS = "true", PYTHONUNBUFFERED = "1", PYTHONIOENCODING = "utf-8" }
'@
    $block -split "`n" | ForEach-Object { Write-Info "   $_" }
    if ($Apply -and ((Read-Host '  Записать эту настройку в config.toml Codex? [Y/N]') -match '^(y|д|yes|да)$')) {
        $bak = "$codexCfg.bak-" + (Get-Date -Format 'yyyyMMdd-HHmm')
        Copy-Item $codexCfg $bak -Force
        $txt = [IO.File]::ReadAllText($codexCfg, $utf8)
        $txt = [regex]::Replace($txt, '(?ms)^\[mcp_servers\.hermes-tools\]\r?\n.*?(?=^\[|\z)', '')
        $txt = $txt.TrimEnd() + "`r`n`r`n" + ($block -replace "`r?`n", "`r`n") + "`r`n"
        [IO.File]::WriteAllText($codexCfg, $txt, $utf8)
        Write-Host "  -> Записано. Копия прежнего конфига: $bak. Перезапустите Codex." -ForegroundColor Green
    }
} elseif ($wrapped) {
    Write-Info 'Работает только через обёртку — текущая настройка Codex верна.'
} else {
    Write-Info 'Hermes MCP не отвечает ни напрямую, ни через обёртку. Пришлите вывод разделов 1-3 (stderr покажет причину).'
}
