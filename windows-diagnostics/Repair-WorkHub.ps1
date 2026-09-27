<#
.SYNOPSIS
    Восстановление связки Codex <-> Hermes в WorkHub после переустановки Windows.
.DESCRIPTION
    1) Заменяет старый путь профиля C:\Users\Suxow на текущий в РАБОЧИХ файлах WorkHub
       (архивы, venv, node_modules, данные Hermes не трогаются). Кодировка каждого файла сохраняется.
    2) Подключает Hermes к Codex как MCP-сервер hermes-tools (stdio, без сетевого порта).
    3) Проверяет, что Hermes действительно отвечает по протоколу MCP.
    Без -Apply — только показывает план. Перед изменениями — копии файлов и Rollback.ps1.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-WorkHub.ps1
    powershell -ExecutionPolicy Bypass -File .\Repair-WorkHub.ps1 -Apply
#>
param([switch]$Apply, [string]$OldUser = 'Suxow')

$ErrorActionPreference = 'Continue'
$wh       = 'E:\WorkHub'
$hermes   = "$wh\.hermes-venv313\Scripts\hermes.exe"
$codexCfg = "$env:USERPROFILE\.codex\config.toml"
$stamp    = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$bakDir   = "C:\SSV-Agents\workhub-repair-$stamp"
$rollback = Join-Path $bakDir 'Rollback.ps1'
$pathRx   = "(?i)C:([\\/]+)Users([\\/]+)$([regex]::Escape($OldUser))(?=[\\/""'\s;]|$)"
$exclude  = '\\(archives|node_modules|\.venv|\.hermes-venv313|site-packages|\.git|\.hermes|__pycache__|\.next)\\'
$exts     = '.ps1', '.psm1', '.md', '.toml', '.json', '.yaml', '.yml', '.env', '.bat', '.cmd', '.txt', '.py', '.ini'

function Write-Head($t) { Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }
function Write-Info($t) { Write-Host "  $t" }
function Confirm-Step($q) { if (-not $Apply) { return $false }; return ((Read-Host "  $q [Y/N]") -match '^(y|д|yes|да)$') }
function Save-Backup($path) {
    New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
    $rel = $path -replace '^[A-Za-z]:\\', '' -replace '\\', '__'
    $bak = Join-Path $bakDir $rel
    Copy-Item $path $bak -Force
    Add-Content $rollback "Copy-Item '$bak' '$path' -Force" -Encoding UTF8
}
# Чтение с определением кодировки: UTF-8 BOM / UTF-16 / UTF-8 без BOM / ANSI
function Read-TextKeepEncoding($path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return @{ Text = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3); Enc = (New-Object Text.UTF8Encoding $true) } }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return @{ Text = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2); Enc = [Text.Encoding]::Unicode } }
    try   { $strict = New-Object Text.UTF8Encoding($false, $true); return @{ Text = $strict.GetString($b); Enc = (New-Object Text.UTF8Encoding $false) } }
    catch { return @{ Text = [Text.Encoding]::Default.GetString($b); Enc = [Text.Encoding]::Default } }
}

if ($Apply) { Write-Host 'РЕЖИМ: ПРИМЕНЕНИЕ' -ForegroundColor Magenta } else { Write-Host 'РЕЖИМ: ТОЛЬКО ПЛАН (для применения: -Apply)' -ForegroundColor Green }
if (-not (Test-Path $hermes)) { Write-Host "Не найден $hermes" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
Write-Head "1. СТАРЫЙ ПУТЬ C:\Users\$OldUser -> $env:USERPROFILE"
$files = Get-ChildItem $wh -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch $exclude -and ($exts -contains $_.Extension.ToLower() -or $_.Name -like '.env*') -and $_.Length -lt 2MB
}
$hits = @()
foreach ($f in $files) {
    $r = Read-TextKeepEncoding $f.FullName
    $n = ([regex]::Matches($r.Text, $pathRx)).Count
    if ($n -gt 0) { $hits += [pscustomobject]@{ Path = $f.FullName; Count = $n; Data = $r } }
}
$hits | ForEach-Object { Write-Info ("{0,3} x  {1}" -f $_.Count, $_.Path) }
Write-Info ("Итого файлов: {0}. Архивы, venv, node_modules и данные Hermes не затрагиваются." -f $hits.Count)
if ($hits.Count -gt 0 -and (Confirm-Step "Заменить C:\Users\$OldUser на $env:USERPROFILE в этих файлах?")) {
    foreach ($h in $hits) {
        Save-Backup $h.Path
        $newText = [regex]::Replace($h.Data.Text, $pathRx, { param($m) "C:$($m.Groups[1].Value)Users$($m.Groups[2].Value)$env:USERNAME" })
        [IO.File]::WriteAllText($h.Path, $newText, $h.Data.Enc)
    }
    Write-Host "  -> Исправлено файлов: $($hits.Count)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Head '2. ПОДКЛЮЧЕНИЕ HERMES К CODEX (MCP hermes-tools)'
$cfgText = if (Test-Path $codexCfg) { (Read-TextKeepEncoding $codexCfg).Text } else { '' }
if ($cfgText -match '(?m)^\[mcp_servers\.hermes-tools\]') { Write-Info 'hermes-tools уже подключён к Codex.' }
else {
    $block = @'

[mcp_servers.hermes-tools]
command = "powershell.exe"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "E:\\WorkHub\\hermes-mcp.ps1"]
startup_timeout_sec = 60
env = { HERMES_REDACT_SECRETS = "true" }
'@
    Write-Info 'Будет добавлено в конец config.toml Codex:'
    $block -split "`n" | ForEach-Object { Write-Info "   $_" }
    if (Confirm-Step 'Подключить Hermes к Codex?') {
        Save-Backup $codexCfg
        [IO.File]::AppendAllText($codexCfg, ($block -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding $false))
        Write-Host '  -> hermes-tools добавлен. Перезапустите Codex.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
Write-Head '3. ПРОВЕРКА: HERMES ОТВЕЧАЕТ ПО ПРОТОКОЛУ MCP'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wh\hermes-mcp.ps1`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.EnvironmentVariables['HERMES_REDACT_SECRETS'] = 'true'
$proc = [Diagnostics.Process]::Start($psi)
$errTask = $proc.StandardError.ReadToEndAsync()
$init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ssv-check","version":"1.0"}}}'
$proc.StandardInput.WriteLine($init); $proc.StandardInput.Flush()
$deadline = (Get-Date).AddSeconds(45); $answer = $null
while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
    $lineTask = $proc.StandardOutput.ReadLineAsync()
    if ($lineTask.Wait(([int](($deadline - (Get-Date)).TotalMilliseconds)))) {
        $line = $lineTask.Result
        if ($line -match '"id"\s*:\s*1' -and $line -match '"result"') { $answer = $line; break }
    } else { break }
}
if ($answer) {
    $name = ([regex]::Match($answer, '"serverInfo"\s*:\s*\{[^}]*"name"\s*:\s*"([^"]+)"')).Groups[1].Value
    $ver  = ([regex]::Match($answer, '"serverInfo"\s*:\s*\{[^}]*"version"\s*:\s*"([^"]+)"')).Groups[1].Value
    Write-Host "  [OK] Hermes MCP отвечает: $name $ver" -ForegroundColor Green
    $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    $proc.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}'); $proc.StandardInput.Flush()
    $t2 = $proc.StandardOutput.ReadLineAsync()
    if ($t2.Wait(15000)) {
        $tools = [regex]::Matches($t2.Result, '"name"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
        Write-Info ("Инструментов Hermes: {0}. Примеры: {1}" -f @($tools).Count, (($tools | Select-Object -First 12) -join ', '))
    }
} else {
    Write-Host '  [FAIL] Hermes не ответил по MCP за 45 сек.' -ForegroundColor Red
    if (-not $proc.HasExited) { $proc.Kill() }
    $errText = if ($errTask.Wait(3000)) { $errTask.Result } else { '' }
    if ($errText) { Write-Info 'Сообщения Hermes (stderr, последние строки):'; ($errText -split "`r?`n" | Select-Object -Last 15) | ForEach-Object { Write-Info "   $_" } }
}
if (-not $proc.HasExited) { $proc.Kill() }

# ---------------------------------------------------------------------------
Write-Head '4. ВТОРАЯ УСТАНОВКА HERMES (.venv)'
if (Test-Path "$wh\.venv\Scripts\hermes.exe") {
    Write-Info "$wh\.venv\Scripts\hermes.exe не выводит версию — установка повреждена или устарела."
    Write-Info 'Рабочая установка — .hermes-venv313 (v0.18.2). Удалять .venv пока не нужно: сначала убедимся,'
    Write-Info 'что никакие скрипты WorkHub его не используют:'
    $uses = Get-ChildItem $wh -Recurse -Force -File -Include *.ps1, *.bat, *.cmd, *.md, *.toml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $exclude } | Select-String -Pattern 'WorkHub\\\.venv\\' -List
    if ($uses) { $uses | ForEach-Object { Write-Info "   используется в: $($_.Path)" } } else { Write-Info '   ссылок на .venv нет — её можно будет удалить.' }
}

if ($Apply -and (Test-Path $rollback)) { Write-Host "`n  Откат: powershell -ExecutionPolicy Bypass -File `"$rollback`"" -ForegroundColor Green }
