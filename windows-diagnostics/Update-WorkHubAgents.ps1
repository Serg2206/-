<#
.SYNOPSIS
    WorkHub: проверка связки Hermes/Codex/Kimi и добавление правил системной безопасности.
.DESCRIPTION
    Без -Apply — только чтение. С -Apply — дописывает (не перезаписывает) правила в
    E:\WorkHub\AGENTS.md и E:\WorkHub\.hermes\SOUL.md, предварительно сделав копии.
    Файлы сохраняются в UTF-8 без BOM, как в оригинале. Секреты не выводятся.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Update-WorkHubAgents.ps1
    powershell -ExecutionPolicy Bypass -File .\Update-WorkHubAgents.ps1 -Apply
#>
param([switch]$Apply)
$ErrorActionPreference = 'SilentlyContinue'
$wh     = 'E:\WorkHub'
$utf8   = New-Object Text.UTF8Encoding $false
$base   = 'https://raw.githubusercontent.com/Serg2206/-/claude/windows-11-slow-performance-8e59eq/windows-diagnostics'
$stamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$bakDir = "C:\SSV-Agents\workhub-$stamp"
$marker = '2026-09-27'

function Write-Head($t) { Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }
function Write-Info($t) { Write-Host "  $t" }
function Write-Warn($t) { Write-Host "  !! $t" -ForegroundColor Yellow }
function Read-Utf8($p)  { [IO.File]::ReadAllText($p, $utf8) }
function Hide-Secrets([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '(sk-|sk_|ghp_|gho_|xox[bp]-|AIza|hf_|nvapi-|xai-)[A-Za-z0-9_\-]{6,}', '[скрыто]')
    return [regex]::Replace($s, '(?i)((api[_-]?key|token|secret|password|passwd|bearer)["'']?\s*[:=]\s*["'']?)[^\s"'',]+', '$1[скрыто]')
}
function Show-File($p, $n) {
    if (Test-Path $p) { Write-Info "--- $p ---"; (Read-Utf8 $p) -split "`r?`n" | Select-Object -First $n | ForEach-Object { Write-Info ("   " + (Hide-Secrets $_)) } }
    else { Write-Warn "нет файла $p" }
}

if ($Apply) { Write-Host 'РЕЖИМ: ПРИМЕНЕНИЕ' -ForegroundColor Magenta } else { Write-Host 'РЕЖИМ: ТОЛЬКО ЧТЕНИЕ (для применения: -Apply)' -ForegroundColor Green }

# ---------------------------------------------------------------------------
Write-Head '1. HERMES: УСТАНОВКИ И ВЕРСИИ'
foreach ($exe in "$wh\.hermes-venv313\Scripts\hermes.exe", "$wh\.venv\Scripts\hermes.exe") {
    if (Test-Path $exe) {
        $v = & $exe --version 2>&1 | Select-Object -First 1
        Write-Info ("{0}  ->  {1}" -f $exe, $v)
    } else { Write-Info "нет: $exe" }
}
if ((Test-Path "$wh\.hermes-venv313\Scripts\hermes.exe") -and (Test-Path "$wh\.venv\Scripts\hermes.exe")) {
    Write-Warn 'Две установки Hermes (.hermes-venv313 и .venv). По AGENTS.md основная — .hermes-venv313.'
}
$hp = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'hermes' -and $_.Name -notmatch 'powershell' }
if ($hp) { $hp | ForEach-Object { Write-Info ("Запущен: [{0}] {1}" -f $_.ProcessId, (Hide-Secrets $_.CommandLine)) } }
else { Write-Info 'Hermes сейчас не запущен (cron-задачи Hermes выполняются только при работающем Hermes).' }

# ---------------------------------------------------------------------------
Write-Head '2. HERMES: НАСТРОЙКИ, CRON, MCP'
$env1 = "$wh\.env"
if (Test-Path $env1) {
    Write-Info "Переменные в $env1 (только имена):"
    (Read-Utf8 $env1) -split "`r?`n" | Where-Object { $_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' } | ForEach-Object {
        $name = $Matches[1]
        $val  = ($_ -split '=', 2)[1].Trim()
        if ($name -match '(?i)key|token|secret|password') { Write-Info "   $name = [скрыто, длина $($val.Length)]" } else { Write-Info "   $name = $val" }
    }
}
$cfgY = "$wh\.hermes\config.yaml"
if (Test-Path $cfgY) { Show-File $cfgY 60 } else { Write-Info 'config.yaml в HERMES_HOME нет — Hermes работает с настройками по умолчанию.' }
Write-Info 'Cron-задачи Hermes:'
Get-ChildItem "$wh\.hermes\cron" -Recurse -Force -File | ForEach-Object {
    Write-Info ("   {0}  ({1} байт, {2:yyyy-MM-dd})" -f $_.FullName, $_.Length, $_.LastWriteTime)
    if ($_.Extension -eq '.json' -and $_.Length -lt 20000) { (Read-Utf8 $_.FullName) -split "`r?`n" | Select-Object -First 40 | ForEach-Object { Write-Info ("      " + (Hide-Secrets $_)) } }
}
Show-File "$wh\hermes-mcp.ps1" 40
Show-File "$wh\start-workhub.ps1" 40

# ---------------------------------------------------------------------------
Write-Head '3. СВЯЗКА CODEX <-> HERMES (MCP hermes-tools)'
$codexCfg = "$env:USERPROFILE\.codex\config.toml"
$ctext = Read-Utf8 $codexCfg
if ($ctext -match '\[mcp_servers\.hermes-tools\]') { Write-Info 'В Codex подключён MCP-сервер hermes-tools.' }
else { Write-Warn 'В config.toml Codex НЕТ [mcp_servers.hermes-tools] — Codex сейчас не видит Hermes (интеграция из документации не работает).' }
$old = Get-ChildItem $wh -Recurse -Force -Include *.md, *.ps1, *.toml, *.bat, *.json -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(node_modules|\.venv|\.hermes-venv313|site-packages)\\' } |
    Select-String -Pattern 'C:\\+Users\\+Suxow' -SimpleMatch:$false -List
if ($old) {
    Write-Warn ("Ссылки на старый профиль C:\Users\Suxow (до переустановки Windows) в {0} файлах:" -f @($old).Count)
    $old | Select-Object -First 15 | ForEach-Object { Write-Info ("   {0}:{1}" -f $_.Path, $_.LineNumber) }
}
if (Test-Path 'C:\Users\Suxow') { Write-Info 'Папка C:\Users\Suxow существует.' } else { Write-Warn 'Папки C:\Users\Suxow нет — пути в этих файлах не работают.' }
$wrapper = "$env:LOCALAPPDATA\hermes\hermes-mcp-wrapper.bat"
if (Test-Path $wrapper) { Write-Info "Обёртка MCP найдена: $wrapper" } else { Write-Info "Обёртки $wrapper нет." }

# ---------------------------------------------------------------------------
Write-Head '4. АВТОМАТИЗАЦИИ WORKHUB И БОТ MARIA'
$tasks = Get-ScheduledTask | Where-Object { ($_.Actions.Arguments -join ' ') -match 'WorkHub' -or $_.TaskName -match 'WorkHub|maria|hermes' }
if ($tasks) { $tasks | ForEach-Object { Write-Info ("Задача: {0} [{1}]" -f $_.TaskName, $_.State) } }
else { Write-Info 'Задач планировщика WorkHub нет (скрипты register-workhub-*.ps1 не применялись после переустановки).' }
$bot = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'maria-bot|telegram-bot' }
if ($bot) { Write-Info 'Бот MARIA запущен на этом ПК.' } else { Write-Info 'Бот MARIA на этом ПК не запущен (если он работает на сервере — это норма).' }

# ---------------------------------------------------------------------------
Write-Head '5. ПРАВИЛА СИСТЕМНОЙ БЕЗОПАСНОСТИ'
$targets = @(
    @{ Path = "$wh\AGENTS.md";       Src = "$base/workhub-rules-append.md" },
    @{ Path = "$wh\.hermes\SOUL.md"; Src = "$base/hermes-soul-append.md" }
)
foreach ($t in $targets) {
    if (-not (Test-Path $t.Path)) { Write-Warn "нет файла $($t.Path)"; continue }
    $cur = Read-Utf8 $t.Path
    if ($cur -match [regex]::Escape($marker)) { Write-Info "Правила уже есть: $($t.Path)"; continue }
    Write-Info "Будут дописаны правила в конец: $($t.Path)"
    if ($Apply -and ((Read-Host "  Дописать? [Y/N]") -match '^(y|д|yes|да)$')) {
        New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
        $bak = Join-Path $bakDir ((Split-Path $t.Path -Leaf) + '.bak')
        Copy-Item $t.Path $bak -Force
        $add = (Invoke-WebRequest $t.Src -UseBasicParsing).Content
        if ($add -is [byte[]]) { $add = $utf8.GetString($add) }
        [IO.File]::AppendAllText($t.Path, "`r`n" + ($add -replace "`r?`n", "`r`n"), $utf8)
        Write-Host "  -> Дописано. Копия оригинала: $bak" -ForegroundColor Green
        Add-Content (Join-Path $bakDir 'Rollback.ps1') "Copy-Item '$bak' '$($t.Path)' -Force" -Encoding UTF8
    }
}
if ($Apply -and (Test-Path $bakDir)) { Write-Host "`n  Откат: powershell -ExecutionPolicy Bypass -File `"$bakDir\Rollback.ps1`"" -ForegroundColor Green }
