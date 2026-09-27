<#
.SYNOPSIS
    Аудит ИИ-агентов (Kimi, Codex, Hermes, Claude, Pinokio, Ollama и др.) — ТОЛЬКО ЧТЕНИЕ.
.DESCRIPTION
    Показывает: что установлено, что запущено и сколько потребляет, что стартует
    автоматически, какие задачи планировщика созданы агентами и с какими правами,
    какие сетевые порты открыты, настройки разрешений агентов, исключения Defender.
    Секреты (ключи API, токены, пароли) НЕ выводятся — только имена и отметка [скрыто].
    Отчёт: Рабочий стол\AgentsAudit_<дата>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Audit-Agents.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'
$agentRx = 'Kimi|Moonshot|Codex|OpenAI|ChatGPT|Hermes|Nous|Claude|Anthropic|Pinokio|Ollama|LM ?Studio|Cursor|Windsurf|Copilot|Perplexity|Comet|Gemini|DeepSeek|Jan\b|n8n|Docker|AnythingLLM|Open ?WebUI|ComfyUI|Continue|Cline|Aider'
$out   = New-Object System.Collections.Generic.List[string]
$flags = New-Object System.Collections.Generic.List[string]

function Write-Section($t) { $l = "`n==================== $t ===================="; $out.Add($l); Write-Host $l -ForegroundColor Cyan }
function Write-Line($t)    { $out.Add($t); Write-Host $t }
function Add-Flag($t)      { $flags.Add($t); $l = "  !! $t"; $out.Add($l); Write-Host $l -ForegroundColor Yellow }
function Hide-Secrets([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, '(sk-|sk_|ghp_|gho_|xox[bp]-|AIza|hf_|nvapi-)[A-Za-z0-9_\-]{6,}', '[скрыто]')
    $s = [regex]::Replace($s, '(?i)((api[_-]?key|token|secret|password|passwd|bearer)["'']?\s*[:=]\s*["'']?)[^\s"'',]+', '$1[скрыто]')
    return $s
}
function Get-DirSizeGB($p) {
    $sum = (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    return [math]::Round($sum / 1GB, 2)
}

Write-Line "АУДИТ ИИ-АГЕНТОВ — $(Get-Date)   Пользователь: $env:USERNAME"

# ---------------------------------------------------------------------------
Write-Section '1. УСТАНОВЛЕННЫЕ ПРОГРАММЫ'
$uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $uninst | Where-Object { $_.DisplayName -match $agentRx } |
    Sort-Object DisplayName -Unique | ForEach-Object { Write-Line ("  {0,-45} {1,-15} {2}" -f $_.DisplayName, $_.DisplayVersion, $_.InstallLocation) }
Write-Line "  --- Приложения Microsoft Store ---"
Get-AppxPackage | Where-Object { $_.Name -match $agentRx -or $_.PackageFamilyName -match $agentRx } |
    ForEach-Object { Write-Line ("  {0,-45} {1}" -f $_.Name, $_.Version) }
Write-Line "  --- Командные инструменты ---"
foreach ($c in 'codex', 'claude', 'hermes', 'kimi', 'ollama', 'docker', 'wsl', 'node', 'python', 'uv', 'git') {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { Write-Line ("  {0,-8} {1}" -f $c, $cmd.Source) }
}

# ---------------------------------------------------------------------------
Write-Section '2. ЗАПУЩЕННЫЕ ПРОЦЕССЫ АГЕНТОВ'
$procs = Get-CimInstance Win32_Process
$agentProcs = $procs | Where-Object { $_.Name -match $agentRx -or $_.CommandLine -match $agentRx -or $_.ExecutablePath -match $agentRx }
$byName = $agentProcs | Group-Object Name | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MB = [math]::Round(($_.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB) }
} | Sort-Object MB -Descending
$byName | ForEach-Object { Write-Line ("  {0,-35} x{1,-3} {2,7} МБ" -f $_.Name, $_.Count, $_.MB) }
$totalMB = ($byName | Measure-Object MB -Sum).Sum
Write-Line "  Всего памяти у агентов: $totalMB МБ"
if ($totalMB -gt 6000) { Add-Flag "Агенты вместе занимают $totalMB МБ RAM." }
Write-Line "  --- Скрипты и фоновые агенты (python/node/powershell) ---"
$procs | Where-Object { $_.Name -match '^(python|pythonw|node|powershell|pwsh|uv|bun|deno)\.exe$' } | ForEach-Object {
    $cl = Hide-Secrets $_.CommandLine
    if ($cl.Length -gt 180) { $cl = $cl.Substring(0, 180) + '…' }
    Write-Line ("  [{0}] {1}" -f $_.ProcessId, $cl)
}

# ---------------------------------------------------------------------------
Write-Section '3. АВТОЗАГРУЗКА'
$runKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
           'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
foreach ($k in $runKeys) {
    $props = (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }
    foreach ($p in $props) {
        $apprKey = ($k -replace 'CurrentVersion\\Run$', 'CurrentVersion\Explorer\StartupApproved\Run') -replace 'WOW6432Node\\', ''
        $st = (Get-ItemProperty $apprKey -Name $p.Name).($p.Name)
        $state = if ($st -and $st[0] -eq 3) { 'выкл' } else { 'ВКЛ' }
        Write-Line ("  [{0,-4}] {1,-30} {2}" -f $state, $p.Name, (Hide-Secrets $p.Value))
    }
}
$sf = [Environment]::GetFolderPath('Startup')
Get-ChildItem $sf | ForEach-Object { Write-Line ("  [ВКЛ ] Папка автозагрузки: {0}" -f $_.Name) }
Write-Line "  --- Приложения Store с автозапуском ---"
$appModel = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
Get-ChildItem $appModel | ForEach-Object {
    $pkg = $_.PSChildName
    Get-ChildItem $_.PSPath | ForEach-Object {
        $s = (Get-ItemProperty $_.PSPath).State
        if ($null -ne $s) {
            $state = if ($s -eq 2 -or $s -eq 4) { 'ВКЛ' } else { 'выкл' }
            Write-Line ("  [{0,-4}] {1}" -f $state, ($pkg -replace '_[a-z0-9]{13}$', ''))
            if ($state -eq 'ВКЛ' -and $pkg -match $agentRx) { Add-Flag "Автозапуск агента из Store: $pkg" }
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section '4. ЗАДАЧИ ПЛАНИРОВЩИКА (сторонние)'
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    $act  = Hide-Secrets (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | ')
    if ($act.Length -gt 160) { $act = $act.Substring(0, 160) + '…' }
    $trig = ($_.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace 'MSFT_Task|Trigger', '' }) -join ','
    $lvl  = $_.Principal.RunLevel
    Write-Line ("  [{0,-8}] {1}{2}" -f $_.State, $_.TaskPath, $_.TaskName)
    Write-Line ("             запуск: {0}; права: {1} ({2}); посл.: {3} код {4}" -f $trig, $lvl, $_.Principal.UserId, $info.LastRunTime, $info.LastTaskResult)
    Write-Line ("             команда: {0}" -f $act)
    $isScript = $act -match 'powershell|pwsh|python|node|cmd\.exe|\.ps1|\.py|\.bat'
    if ($_.State -ne 'Disabled' -and $isScript -and ($lvl -eq 'Highest' -or $_.Principal.UserId -match 'SYSTEM')) {
        Add-Flag "Задача '$($_.TaskName)' запускает скрипт С ПРАВАМИ АДМИНИСТРАТОРА/SYSTEM."
    }
    if ($env:OneDrive -and $act -like "*$env:OneDrive*") { Add-Flag "Задача '$($_.TaskName)' запускает файл из OneDrive (при синхронизации файл может отсутствовать или быть подменён)." }
}

# ---------------------------------------------------------------------------
Write-Section '5. СЛУЖБЫ АГЕНТОВ'
Get-CimInstance Win32_Service | Where-Object { $_.Name -match $agentRx -or $_.DisplayName -match $agentRx -or $_.PathName -match $agentRx -or $_.PathName -match '\\Users\\' } |
    ForEach-Object { Write-Line ("  {0,-30} {1,-8} {2,-8} {3}" -f $_.Name, $_.State, $_.StartMode, (Hide-Secrets $_.PathName)) }

# ---------------------------------------------------------------------------
Write-Section '6. ОТКРЫТЫЕ СЕТЕВЫЕ ПОРТЫ'
$pmap = @{}; foreach ($p in $procs) { $pmap[[int]$p.ProcessId] = $p.Name }
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -ge 1024 } | Sort-Object LocalPort -Unique | ForEach-Object {
    $pn = $pmap[[int]$_.OwningProcess]
    $scope = if ($_.LocalAddress -in '0.0.0.0', '::') { 'ВСЯ СЕТЬ' } elseif ($_.LocalAddress -match '^(127\.|::1)') { 'только этот ПК' } else { $_.LocalAddress }
    Write-Line ("  {0,-6} {1,-15} {2}" -f $_.LocalPort, $scope, $pn)
    if ($scope -eq 'ВСЯ СЕТЬ' -and $pn -match '^(python|pythonw|node|ollama|uv|docker|com\.docker|wslrelay)' ) {
        Add-Flag "Порт $($_.LocalPort) ($pn) открыт для ВСЕЙ сети, а не только для этого ПК."
    }
}

# ---------------------------------------------------------------------------
Write-Section '7. ПАПКИ АГЕНТОВ И ИХ РАЗМЕР'
$od = $env:OneDrive
$dirs = @("$env:USERPROFILE\.codex", "$env:USERPROFILE\.hermes", "$env:USERPROFILE\.claude", "$env:USERPROFILE\.kimi",
          "$env:USERPROFILE\.cache", "$env:USERPROFILE\.ollama", "$env:USERPROFILE\pinokio", 'C:\pinokio', 'D:\pinokio',
          "$env:APPDATA\Kimi", "$env:LOCALAPPDATA\Kimi", "$env:APPDATA\Codex", "$env:LOCALAPPDATA\Programs",
          "$od\Documents\kimi", 'E:\WorkHub', 'E:\AI', 'E:\ПЛАТФОРМА')
foreach ($d in $dirs) {
    if (Test-Path $d) {
        $gb = Get-DirSizeGB $d
        Write-Line ("  {0,8} ГБ  {1}" -f $gb, $d)
        if ($od -and $d -like "$od*" -and $gb -gt 1) { Add-Flag "Рабочая папка агента в OneDrive ($d, $gb ГБ) — постоянная синхронизация тысяч мелких файлов." }
    }
}
if ($od) {
    Get-ChildItem $od -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in 'node_modules', '.venv', 'venv', '__pycache__', '.git' } | Select-Object -First 15 |
        ForEach-Object { Add-Flag "В OneDrive синхронизируется служебная папка: $($_.FullName)" }
}

# ---------------------------------------------------------------------------
Write-Section '8. НАСТРОЙКИ РАЗРЕШЕНИЙ АГЕНТОВ (секреты скрыты)'
$cfgs = "$env:USERPROFILE\.codex\config.toml", "$env:USERPROFILE\.codex\AGENTS.md",
        "$env:USERPROFILE\.hermes\config.yaml", "$env:USERPROFILE\.hermes\SOUL.md",
        "$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.claude\CLAUDE.md",
        "$env:USERPROFILE\.kimi\config.toml", "$env:USERPROFILE\.kimi\config.json", "$env:APPDATA\Kimi\config.json"
foreach ($c in $cfgs) {
    if (Test-Path $c) {
        Write-Line "  --- $c ---"
        Get-Content $c -TotalCount 80 | ForEach-Object { Write-Line ("    " + (Hide-Secrets $_)) }
        $txt = Get-Content $c -Raw
        if ($txt -match '(?i)danger-full-access|approval_policy\s*=\s*"never"|bypassPermissions|dangerously|yolo|auto_approve\s*[:=]\s*true') {
            Add-Flag "В $c агенту разрешено выполнять команды БЕЗ подтверждения."
        }
    }
}
Write-Line "  --- Файлы .env (только расположение) ---"
foreach ($root in "$env:USERPROFILE\.hermes", 'E:\WorkHub', 'E:\AI', 'E:\ПЛАТФОРМА', "$env:USERPROFILE\.codex") {
    Get-ChildItem $root -Recurse -Force -Filter '.env' -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object { Write-Line "    $($_.FullName)" }
}

# ---------------------------------------------------------------------------
Write-Section '9. КЛЮЧИ API В ПЕРЕМЕННЫХ СРЕДЫ (только имена)'
foreach ($scope in 'User', 'Machine') {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
        if ($k -match '(?i)key|token|secret|api|password') {
            Write-Line ("  [{0,-7}] {1} = [скрыто, длина {2}]" -f $scope, $k, ([string]$vars[$k]).Length)
            if ($scope -eq 'Machine') { Add-Flag "Секрет $k хранится в СИСТЕМНЫХ переменных — доступен всем программам и пользователям." }
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section '10. БЕЗОПАСНОСТЬ'
$uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Write-Line ("  UAC (EnableLUA): {0}; запрос для админа (ConsentPromptBehaviorAdmin): {1}" -f $uac.EnableLUA, $uac.ConsentPromptBehaviorAdmin)
if ($uac.EnableLUA -ne 1) { Add-Flag "UAC ОТКЛЮЧЁН — любая программа и агент работают с полными правами." }
elseif ($uac.ConsentPromptBehaviorAdmin -eq 0) { Add-Flag "UAC повышает права БЕЗ запроса — агент получит права администратора молча." }
Write-Line ("  ExecutionPolicy: " + ((Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', '))
$mpp = Get-MpPreference
Write-Line "  Исключения Defender (пути):";    $mpp.ExclusionPath    | ForEach-Object { Write-Line "    $_" }
Write-Line "  Исключения Defender (процессы):"; $mpp.ExclusionProcess | ForEach-Object { Write-Line "    $_" }
if ($mpp.ExclusionPath -match '^[A-Z]:\\?$|\\Users\\?$|\\Users\\[^\\]+\\?$') { Add-Flag "Defender исключает целый диск или профиль пользователя — защита фактически отключена для этих файлов." }
if ($mpp.ExclusionProcess -match 'powershell|python|node|cmd') { Add-Flag "Defender не проверяет действия интерпретаторов (powershell/python/node) — опасно." }
Write-Line "  Правила брандмауэра для агентов (входящие, разрешающие):"
Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | Where-Object { $_.DisplayName -match "$agentRx|python|node" } |
    ForEach-Object { Write-Line ("    {0} ({1})" -f $_.DisplayName, $_.Profile) }
$sc = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'; Id=7040; StartTime=(Get-Date).AddDays(-14)}
Write-Line "  Изменения типа запуска служб за 14 дней: $(@($sc).Count)"
$sc | Select-Object -First 15 | ForEach-Object { Write-Line ("    {0:dd.MM HH:mm}  {1}" -f $_.TimeCreated, (($_.Message -split "`n")[0])) }

# ---------------------------------------------------------------------------
Write-Section 'ЗАМЕЧАНИЯ'
if ($flags.Count -eq 0) { Write-Line '  Замечаний нет.' } else { $i = 1; foreach ($f in $flags) { Write-Line "  $i. $f"; $i++ } }
$file = Join-Path ([Environment]::GetFolderPath('Desktop')) ("AgentsAudit_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))
$out | Out-File $file -Encoding UTF8
Write-Host "`nОтчёт сохранён: $file" -ForegroundColor Green
Write-Host "Секреты в отчёте скрыты, но перед отправкой всё равно просмотрите его." -ForegroundColor Green
