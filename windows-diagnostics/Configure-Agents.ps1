<#
.SYNOPSIS
    Безопасная настройка ИИ-агентов (Codex, Kimi, Hermes и др.) по итогам Audit-Agents.ps1.
.DESCRIPTION
    По умолчанию — АУДИТ (ничего не меняет). С ключом -Apply — изменения с подтверждением
    каждого блока. Все изменения обратимы: команды отката пишутся в Rollback.ps1.
    Папка: C:\SSV-Agents\<дата>\
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Configure-Agents.ps1
    powershell -ExecutionPolicy Bypass -File .\Configure-Agents.ps1 -Apply
#>
param([switch]$Apply)

$ErrorActionPreference = 'Continue'
$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$workDir = "C:\SSV-Agents\$stamp"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$rollback = Join-Path $workDir 'Rollback.ps1'
Set-Content $rollback -Encoding UTF8 -Value "# Откат Configure-Agents.ps1 от $stamp"
$notes = New-Object System.Collections.Generic.List[string]
Start-Transcript -Path (Join-Path $workDir 'transcript.log') | Out-Null
$rulesUrl = 'https://raw.githubusercontent.com/Serg2206/-/claude/windows-11-slow-performance-8e59eq/windows-diagnostics/AGENTS.md'

function Write-Head($t) { Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }
function Write-Info($t) { Write-Host "  $t" }
function Add-Note($t)   { $notes.Add($t); Write-Host "  -> $t" -ForegroundColor Yellow }
function Add-Rollback($t) { Add-Content $rollback -Value $t -Encoding UTF8 }
function Hide-Secrets([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '(sk-|sk_|ghp_|gho_|xox[bp]-|AIza|hf_|nvapi-)[A-Za-z0-9_\-]{6,}', '[скрыто]')
    return [regex]::Replace($s, '(?i)((api[_-]?key|token|secret|password|passwd|bearer)["'']?\s*[:=]\s*["'']?)[^\s"'',]+', '$1[скрыто]')
}
function Confirm-Step($q) {
    if (-not $Apply) { return $false }
    return ((Read-Host "  $q [Y/N]") -match '^(y|д|yes|да)$')
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Запустите PowerShell ОТ ИМЕНИ АДМИНИСТРАТОРА.' -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
if ($Apply) { Write-Host 'РЕЖИМ: ПРИМЕНЕНИЕ (с подтверждением каждого блока)' -ForegroundColor Magenta }
else        { Write-Host 'РЕЖИМ: АУДИТ — ничего не меняется. Для применения: -Apply' -ForegroundColor Green }

# ---------------------------------------------------------------------------
Write-Head '1. ПРАВИЛА ДЛЯ ВСЕХ АГЕНТОВ (AGENTS.md)'
$rulesTargets = @("$env:USERPROFILE\.codex\AGENTS.md", 'E:\WorkHub\AGENTS.md')
foreach ($t in $rulesTargets) {
    if (Test-Path $t) { Write-Info "Уже есть: $t (не перезаписывается — сверьте вручную)" }
    else { Write-Info "Нет файла правил: $t" }
}
if (Confirm-Step 'Создать файлы правил AGENTS.md там, где их нет?') {
    $rules = Join-Path $workDir 'AGENTS.md'
    Invoke-WebRequest $rulesUrl -OutFile $rules -UseBasicParsing
    foreach ($t in $rulesTargets) {
        $dir = Split-Path $t
        if ((Test-Path $dir) -and -not (Test-Path $t)) {
            Copy-Item $rules $t
            Add-Rollback "Remove-Item '$t' -Force"
            Add-Note "Создан файл правил: $t"
        }
    }
    New-Item -ItemType Directory -Force -Path 'E:\WorkHub\agents' | Out-Null
}

# ---------------------------------------------------------------------------
Write-Head '2. CODEX: РЕЖИМ ПОДТВЕРЖДЕНИЙ'
$cfg = "$env:USERPROFILE\.codex\config.toml"
if (Test-Path $cfg) {
    $txt = Get-Content $cfg -Raw
    $hasApproval = $txt -match '(?m)^\s*approval_policy\s*='
    $hasSandbox  = $txt -match '(?m)^\s*sandbox_mode\s*='
    Write-Info ("approval_policy: {0}; sandbox_mode: {1}; [windows] sandbox: {2}" -f `
        $(if ($hasApproval) { ([regex]::Match($txt, '(?m)^\s*approval_policy\s*=\s*(.+)$')).Groups[1].Value } else { 'не задан (значение по умолчанию)' }),
        $(if ($hasSandbox)  { ([regex]::Match($txt, '(?m)^\s*sandbox_mode\s*=\s*(.+)$')).Groups[1].Value } else { 'не задан (значение по умолчанию)' }),
        ([regex]::Match($txt, '(?ms)^\[windows\].*?sandbox\s*=\s*"([^"]+)"')).Groups[1].Value)
    $plugins = [regex]::Matches($txt, '(?m)^\[plugins\."([^"]*computer-use[^"]*)"\]\s*\r?\nenabled\s*=\s*true') | ForEach-Object { $_.Groups[1].Value }
    if ($plugins) { Write-Info ("Включено управление мышью/клавиатурой (computer-use): {0}" -f ($plugins -join ', ')) }
    if (-not $hasApproval -or -not $hasSandbox) {
        if (Confirm-Step 'Явно задать Codex: спрашивать разрешение (on-request) и писать только в рабочую папку (workspace-write)?') {
            $bak = Join-Path $workDir 'codex-config.toml.bak'
            Copy-Item $cfg $bak
            Add-Rollback "Copy-Item '$bak' '$cfg' -Force"
            $head = @()
            if (-not $hasApproval) { $head += 'approval_policy = "on-request"' }
            if (-not $hasSandbox)  { $head += 'sandbox_mode = "workspace-write"' }
            # Ключи верхнего уровня TOML должны стоять до первой секции [..]
            # Без BOM: парсер TOML в Codex может не принять метку BOM в начале файла
            [IO.File]::WriteAllText($cfg, (($head -join "`r`n") + "`r`n" + $txt), (New-Object Text.UTF8Encoding $false))
            Add-Note 'Codex: approval_policy = on-request, sandbox_mode = workspace-write (копия конфига сохранена). Перезапустите Codex.'
        }
    } else { Write-Info 'Режимы уже заданы явно — без изменений.' }
} else { Write-Info 'Codex config.toml не найден.' }

# ---------------------------------------------------------------------------
Write-Head '3. БРАНДМАУЭР: ВХОДЯЩИЕ ПРАВИЛА АГЕНТОВ'
$fw = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | Where-Object { $_.DisplayName -match 'kimi|ChatGPT|Codex|python|node|ollama' }
$toDisable = @()
foreach ($r in $fw) {
    $prog = ($r | Get-NetFirewallApplicationFilter).Program
    $exists = $prog -and $prog -ne 'Any' -and (Test-Path ([Environment]::ExpandEnvironmentVariables($prog)))
    $public = $r.Profile -match 'Public|Any'
    $reason = if (-not $exists -and $prog -ne 'Any') { 'программа удалена' } elseif ($public) { 'открыт вход из ПУБЛИЧНЫХ сетей' } else { '' }
    Write-Info ("{0,-25} профиль: {1,-22} {2} {3}" -f $r.DisplayName, $r.Profile, $prog, $(if ($reason) { "<-- $reason" }))
    if ($reason) { $toDisable += $r }
}
if ($toDisable.Count -gt 0 -and (Confirm-Step "Отключить (не удалять) $($toDisable.Count) входящих правил из списка с пометкой '<--'?")) {
    foreach ($r in $toDisable) {
        Disable-NetFirewallRule -Name $r.Name
        Add-Rollback "Enable-NetFirewallRule -Name '$($r.Name)'"
    }
    Add-Note "Отключено входящих правил брандмауэра: $($toDisable.Count). Исходящие соединения агентов работают как раньше."
}

# ---------------------------------------------------------------------------
Write-Head '4. ИСКЛЮЧЕНИЯ DEFENDER'
$ex = @((Get-MpPreference).ExclusionPath)
$ex | ForEach-Object { Write-Info "Исключение: $_" }
$bad = @($ex | Where-Object { $_ -in 'C:\Temp', 'C:\Temp\', 'False', 'True' -or $_ -match '^[A-Za-z]:\\?$' })
if ($bad.Count -gt 0) {
    Write-Info ("Рискованные: {0} (папка загрузок/временных файлов не проверяется; 'False' — ошибочная запись какого-то скрипта)" -f ($bad -join ', '))
    if (Confirm-Step 'Удалить рискованные исключения Defender (C:\Projects оставить)?') {
        foreach ($b in $bad) {
            Remove-MpPreference -ExclusionPath $b
            Add-Rollback "Add-MpPreference -ExclusionPath '$b'"
        }
        Add-Note ("Удалены исключения Defender: {0}" -f ($bad -join ', '))
    }
}

# ---------------------------------------------------------------------------
Write-Head '5. HERMES: ПОИСК УСТАНОВКИ И НАСТРОЕК'
$hermesHits = @()
foreach ($root in 'E:\WorkHub', "$env:USERPROFILE", 'E:\AI') {
    $hermesHits += Get-ChildItem $root -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(\.hermes.*|hermes.*\.(ya?ml|toml|json|md)|SOUL\.md)$' -and $_.FullName -notmatch '\\(node_modules|site-packages|Lib)\\' }
}
$hermesHits | Select-Object -First 20 | ForEach-Object { Write-Info $_.FullName }
foreach ($f in ($hermesHits | Where-Object { -not $_.PSIsContainer -and $_.Extension -match '\.(ya?ml|toml|json)$' } | Select-Object -First 3)) {
    Write-Info "--- $($f.FullName) ---"
    Get-Content $f.FullName -TotalCount 60 | ForEach-Object { Write-Info ("   " + (Hide-Secrets $_)) }
}
if (-not $hermesHits) { Write-Info 'Hermes не найден (ни в E:\WorkHub, ни в профиле, ни в E:\AI).' }

# ---------------------------------------------------------------------------
Write-Head '6. СЕКРЕТЫ .env: НЕ ПОПАДАЮТ ЛИ В GIT'
$envFiles = Get-ChildItem 'E:\WorkHub' -Recurse -Depth 4 -Force -Filter '.env' -ErrorAction SilentlyContinue
foreach ($e in $envFiles) {
    $dir = $e.DirectoryName
    $inRepo = git -C $dir rev-parse --is-inside-work-tree 2>$null
    if ($inRepo -eq 'true') {
        git -C $dir check-ignore -q $e.FullName 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Info "OK  $($e.FullName) — в .gitignore" }
        else { Add-Note "$($e.FullName) НЕ в .gitignore — ключи могут попасть в репозиторий! Добавьте строку .env в .gitignore." }
    } else { Write-Info "OK  $($e.FullName) — не в git-репозитории" }
}

# ---------------------------------------------------------------------------
Write-Head '7. ФОНОВАЯ ТЕЛЕМЕТРИЯ'
$tel = Get-ScheduledTask -TaskPath '\Intel\' -TaskName 'Intel Telemetry 3' -ErrorAction SilentlyContinue
if ($tel -and $tel.State -ne 'Disabled') {
    Write-Info 'Задача Intel Telemetry 3 (SYSTEM, ежедневно) — сбор данных Intel, для работы не нужна.'
    if (Confirm-Step 'Отключить задачу Intel Telemetry 3?') {
        Disable-ScheduledTask -InputObject $tel | Out-Null
        Add-Rollback "Enable-ScheduledTask -TaskPath '\Intel\' -TaskName 'Intel Telemetry 3'"
        Add-Note 'Отключена задача Intel Telemetry 3.'
    }
}

# ---------------------------------------------------------------------------
Write-Head '8. ONEDRIVE И ДУБЛИ PINOKIO (только рекомендации)'
$bk = Join-Path $env:OneDrive 'Backup_Pre_Reinstall_2026-07-09'
if (Test-Path $bk) {
    $files = (Get-ChildItem $bk -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum)
    Write-Info ("{0}: {1} файлов, {2} ГБ — постоянно синхронизируется с облаком." -f $bk, $files.Count, [math]::Round($files.Sum / 1GB, 2))
    Add-Note "Архив $bk ($($files.Count) файлов) лучше перенести на D:\ (HDD-архив) — это разгрузит OneDrive."
}
foreach ($p in 'C:\pinokio', 'D:\pinokio') { if (Test-Path $p) { Write-Info "Pinokio: $p" } }
if ((Test-Path 'C:\pinokio') -and (Test-Path 'D:\pinokio')) {
    Add-Note 'Две установки Pinokio (C: и D:). D: — медленный HDD: модели грузятся долго. Оставьте одну, лучше на E: (SSD).'
}

# ---------------------------------------------------------------------------
Write-Head 'ИТОГ'
if ($notes.Count -eq 0) { Write-Host '  Замечаний нет.' -ForegroundColor Green }
else { $i = 1; foreach ($n in $notes) { Write-Host "  $i. $n" -ForegroundColor Yellow; $i++ } }
$notes | Out-File (Join-Path $workDir 'summary.txt') -Encoding UTF8
if ($Apply) { Write-Host "`n  Откат: powershell -ExecutionPolicy Bypass -File `"$rollback`"" -ForegroundColor Green }
else { Write-Host "`n  Это был аудит. Для применения: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply" -ForegroundColor Green }
Stop-Transcript | Out-Null
