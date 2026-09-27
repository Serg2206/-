<#
.SYNOPSIS
    Безопасная оптимизация и обслуживание рабочей станции Windows 11 Pro.
.DESCRIPTION
    Режим по умолчанию — АУДИТ: только проверяет и показывает план, ничего не меняет.
    С ключом -Apply выполняет изменения, спрашивая подтверждение перед каждым блоком.

    Принципы:
      * перед изменениями — точка восстановления с ПРОВЕРКОЙ, что она реально создана;
      * никаких «твиков-плацебо», не отключаются системные службы, не трогаются
        Defender, UAC, VBS/Memory Integrity, файл подкачки;
      * драйверы из Windows Update только показываются (автоустановка может откатить
        свежие драйверы AMD/Intel);
      * всё, что меняется, записывается в журнал, а обратимые изменения — в Rollback.ps1.

    Папка с журналами и откатом: C:\SSV-Optimize\<дата>\
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Optimize-Workstation.ps1           # аудит
    powershell -ExecutionPolicy Bypass -File .\Optimize-Workstation.ps1 -Apply    # применить
#>
param(
    [switch]$Apply,   # выполнить изменения (без него — только аудит)
    [switch]$Yes      # не спрашивать подтверждение для каждого блока
)

$ErrorActionPreference = 'Continue'
$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$workDir = "C:\SSV-Optimize\$stamp"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$rollback = Join-Path $workDir 'Rollback.ps1'
$summary  = New-Object System.Collections.Generic.List[string]
Start-Transcript -Path (Join-Path $workDir 'transcript.log') | Out-Null

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Head($n, $title) { Say "`n==================== [$n] $title ====================" 'Cyan' }
function Note($text) { $summary.Add($text); Say "  -> $text" 'Yellow' }
function AddRollback($line) { Add-Content -Path $rollback -Value $line -Encoding UTF8 }
function Confirm-Step($question) {
    if (-not $Apply) { return $false }
    if ($Yes) { return $true }
    $a = Read-Host "  $question [Y/N]"
    return ($a -match '^(y|д|yes|да)$')
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say "Запустите PowerShell ОТ ИМЕНИ АДМИНИСТРАТОРА." 'Red'; Stop-Transcript | Out-Null; exit 1 }

if ($Apply) { Say "РЕЖИМ: ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ (с подтверждением каждого блока)" 'Magenta' }
else        { Say "РЕЖИМ: АУДИТ — ничего не меняется. Для применения запустите с ключом -Apply" 'Green' }
Say "Журнал: $workDir"

Set-Content -Path $rollback -Encoding UTF8 -Value @(
    "# Откат обратимых изменений Optimize-Workstation.ps1 от $stamp",
    "# Запуск: powershell -ExecutionPolicy Bypass -File `"$rollback`"",
    "# Обновления Windows/программ и DISM/SFC откатываются через точку восстановления (rstrui.exe)."
)

# ---------------------------------------------------------------------------
Head 1 'ТОЧКА ВОССТАНОВЛЕНИЯ'
$rpKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$last = Get-ComputerRestorePoint | Sort-Object SequenceNumber | Select-Object -Last 1
if ($last) { Say ("  Последняя точка: {0} — {1}" -f [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime), $last.Description) }
else       { Say "  Точек восстановления нет (или защита системы выключена)." 'Yellow' }

if ($Apply) {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    $oldFreq = (Get-ItemProperty $rpKey -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    Set-ItemProperty $rpKey -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord   # снять лимит «1 точка в 24 ч»
    $before = Get-Date
    Checkpoint-Computer -Description "SSV-Optimize $stamp" -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue
    if ($null -ne $oldFreq) { Set-ItemProperty $rpKey -Name SystemRestorePointCreationFrequency -Value $oldFreq -Type DWord }
    else { Remove-ItemProperty $rpKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }

    $new = Get-ComputerRestorePoint | Where-Object { $_.Description -eq "SSV-Optimize $stamp" }
    if ($new) { Say "  [OK] Точка восстановления создана и проверена: SSV-Optimize $stamp" 'Green' }
    else {
        Say "  [СТОП] Точка восстановления НЕ создана. Изменения не будут применяться." 'Red'
        Say "  Проверьте: Win+R -> SystemPropertiesProtection -> диск C: -> «Настроить» -> «Включить защиту»." 'Red'
        Stop-Transcript | Out-Null; exit 2
    }
}

# ---------------------------------------------------------------------------
Head 2 'ЦЕЛОСТНОСТЬ СИСТЕМЫ (DISM + SFC)'
Say "  Проверяет и восстанавливает системные файлы Windows из эталона Microsoft. 15-30 минут."
$cbs = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue
Say ("  Критических/ошибок в журнале System за 7 дней: {0}" -f @($cbs).Count)
if (Confirm-Step "Запустить DISM /RestoreHealth и SFC /scannow?") {
    DISM.exe /Online /Cleanup-Image /RestoreHealth
    sfc.exe /scannow
    Note "Выполнены DISM /RestoreHealth и SFC /scannow (результат — в transcript.log)."
}

# ---------------------------------------------------------------------------
Head 3 'ОБНОВЛЕНИЯ WINDOWS'
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Say "  Поиск обновлений (1-3 минуты)..."
    $sw = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $dr = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
    Say ("  Обновлений ПО Windows: {0}" -f $sw.Updates.Count)
    foreach ($u in $sw.Updates) { Say ("    - {0}" -f $u.Title) }
    Say ("  Драйверов в Windows Update: {0} (только список — ставить вручную по необходимости)" -f $dr.Updates.Count)
    foreach ($u in $dr.Updates) { Say ("    - {0}" -f $u.Title) }

    if ($sw.Updates.Count -gt 0 -and (Confirm-Step "Скачать и установить обновления Windows (без драйверов)?")) {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $sw.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $res = $inst.Install()
        Note ("Установлено обновлений Windows: {0}. Код результата: {1}. Нужна перезагрузка: {2}" -f $coll.Count, $res.ResultCode, $res.RebootRequired)
    }
} catch { Say "  Ошибка Windows Update: $($_.Exception.Message)" 'Red' }

# ---------------------------------------------------------------------------
Head 4 'ОБНОВЛЕНИЯ ПРОГРАММ (winget)'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget upgrade --accept-source-agreements
    if (Confirm-Step "Обновить ВСЕ программы из списка выше через winget?") {
        winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
        Note "Программы обновлены через winget (список — в transcript.log)."
    }
} else { Say "  winget не найден — установите «App Installer» из Microsoft Store." 'Yellow' }

# ---------------------------------------------------------------------------
Head 5 'ДРАЙВЕРЫ (аудит ключевых устройств)'
$classes = 'Display','Net','System','SCSIAdapter','HDC','MEDIA','Bluetooth','USB'
$drivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -in $classes -and $_.DriverProviderName -notmatch '^Microsoft' -and $_.DeviceName }
$drivers | Sort-Object DeviceClass, DeviceName | ForEach-Object {
    $age = if ($_.DriverDate) { [int]((Get-Date) - $_.DriverDate).TotalDays / 365 } else { 0 }
    $mark = if ($age -ge 3) { '  <-- старше 3 лет' } else { '' }
    Say ("  {0,-12} {1,-50} {2,-18} {3:yyyy-MM-dd}{4}" -f $_.DeviceClass, $_.DeviceName, $_.DriverVersion, $_.DriverDate, $mark)
    if ($age -ge 3) { Note "Устаревший драйвер: $($_.DeviceName) ($($_.DriverVersion)). Обновите с сайта производителя." }
}
Say "  Источники драйверов: AMD — AMD Software: Adrenalin; Intel (Wi-Fi/BT/чипсет) — Intel DSA;"
Say "  материнская плата MSI MS-7D17 — msi.com -> Support -> ваша модель -> Drivers / BIOS."
$bad = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
foreach ($b in $bad) { Note "Устройство с ошибкой: $($b.Name) (код $($b.ConfigManagerErrorCode))" }

# ---------------------------------------------------------------------------
Head 6 'ДИСКИ: TRIM, ОПТИМИЗАЦИЯ, ОЧИСТКА'
$trim = fsutil behavior query DisableDeleteNotify
Say "  $($trim -join ' | ')"
if ($trim -match 'NTFS DisableDeleteNotify = 1') { Note "TRIM для NTFS ВЫКЛЮЧЕН — это вредно для SSD." }
$defrag = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
Say ("  Плановая оптимизация дисков: {0}" -f $defrag.State)

$ssdVolumes = Get-PhysicalDisk | Where-Object MediaType -eq 'SSD' | Get-Disk | Get-Partition | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter
Say ("  SSD-тома: {0}" -f ($ssdVolumes -join ', '))

$tempOld = @("$env:LOCALAPPDATA\Temp", "$env:windir\Temp") | ForEach-Object {
    Get-ChildItem $_ -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-7)
}
$tempGB = [math]::Round((($tempOld | Measure-Object Length -Sum).Sum) / 1GB, 2)
Say "  Временные файлы старше 7 дней: $tempGB ГБ"

if (Confirm-Step "Включить TRIM (если выключен), выполнить ReTrim SSD, удалить TEMP старше 7 дней и очистить хранилище компонентов?") {
    if ($trim -match 'NTFS DisableDeleteNotify = 1') {
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        AddRollback 'fsutil behavior set DisableDeleteNotify 1'
    }
    if ($defrag -and $defrag.State -eq 'Disabled') {
        Enable-ScheduledTask -InputObject $defrag | Out-Null
        AddRollback "Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'"
    }
    foreach ($l in $ssdVolumes) { Optimize-Volume -DriveLetter $l -ReTrim -ErrorAction SilentlyContinue }
    $tempOld | Remove-Item -Force -ErrorAction SilentlyContinue
    DISM.exe /Online /Cleanup-Image /StartComponentCleanup
    Note "TRIM проверен, SSD оптимизированы, TEMP (>7 дней) очищен ($tempGB ГБ), хранилище компонентов очищено."
}

$ssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
$ssOn  = (Get-ItemProperty $ssKey -ErrorAction SilentlyContinue).'01'
Say ("  Контроль памяти (Storage Sense): {0}" -f $(if ($ssOn -eq 1) { 'включён' } else { 'выключен' }))
if ($ssOn -ne 1 -and (Confirm-Step "Включить «Контроль памяти» (раз в месяц, только временные файлы, корзину НЕ трогать)?")) {
    New-Item -Path $ssKey -Force | Out-Null
    Set-ItemProperty $ssKey -Name '01'   -Value 1  -Type DWord   # включён
    Set-ItemProperty $ssKey -Name '04'   -Value 1  -Type DWord   # временные файлы приложений
    Set-ItemProperty $ssKey -Name '08'   -Value 0  -Type DWord   # корзину не очищать
    Set-ItemProperty $ssKey -Name '2048' -Value 30 -Type DWord   # раз в 30 дней
    AddRollback "Set-ItemProperty '$ssKey' -Name '01' -Value 0 -Type DWord"
    Note "Включён «Контроль памяти»: ежемесячно, только временные файлы."
}

# ---------------------------------------------------------------------------
Head 7 'DOCKER / WSL'
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $wslcfg) { Say "  .wslconfig уже есть:"; Get-Content $wslcfg | ForEach-Object { Say "    $_" } }
    else {
        Say "  .wslconfig нет — WSL2/Docker может занять до 16 ГБ RAM из 32."
        if (Confirm-Step "Создать .wslconfig: лимит 12 ГБ RAM, 8 потоков, автоматический возврат памяти Windows?") {
            Set-Content -Path $wslcfg -Encoding ASCII -Value @(
                '[wsl2]', 'memory=12GB', 'processors=8', 'swap=4GB', '',
                '[experimental]', 'autoMemoryReclaim=gradual', 'sparseVhd=true'
            )
            AddRollback "Remove-Item '$wslcfg' -Force"
            Note "Создан $wslcfg (12 ГБ / 8 потоков). Применится после «wsl --shutdown»."
        }
    }
} else { Say "  WSL не установлен — пропуск." }

# ---------------------------------------------------------------------------
Head 8 'ЗАЩИТНИК WINDOWS'
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp) {
    Say ("  Защита в реальном времени: {0}; сигнатуры от {1:yyyy-MM-dd}" -f $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureLastUpdated)
    if (-not $mp.RealTimeProtectionEnabled) { Note "Защита в реальном времени ВЫКЛЮЧЕНА — включите в «Безопасность Windows»." }
    if (Confirm-Step "Обновить сигнатуры Defender и выполнить быструю проверку (~5 мин)?") {
        Update-MpSignature -ErrorAction SilentlyContinue
        Start-MpScan -ScanType QuickScan
        Note "Сигнатуры Defender обновлены, быстрая проверка выполнена."
    }
}

# ---------------------------------------------------------------------------
Head 9 'АВТОЗАГРУЗКА И ФОНОВЫЕ ПРОГРАММЫ (только отчёт)'
Get-CimInstance Win32_StartupCommand | ForEach-Object { Say ("  {0,-30} {1}" -f $_.Name, $_.Command) }
$browsers = Get-ItemProperty 'HKLM:\SOFTWARE\Clients\StartMenuInternet\*', 'HKCU:\SOFTWARE\Clients\StartMenuInternet\*' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.'(default)' } | Where-Object { $_ } | Sort-Object -Unique
Say ("  Установленные браузеры ({0}): {1}" -f @($browsers).Count, ($browsers -join ', '))
if (@($browsers).Count -gt 3) { Note "Установлено $(@($browsers).Count) браузеров — каждый держит фоновые службы обновления. Удалите ненужные." }
Say "  Отключать автозагрузку лучше вручную: Ctrl+Shift+Esc -> «Автозагрузка приложений»."

# ---------------------------------------------------------------------------
Head 10 'ОШИБКИ ЖУРНАЛА: РАСШИФРОВКА DCOM 10010'
$dcom = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-DistributedCOM'; Id=10010; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue
$ids = $dcom | ForEach-Object { if ($_.Message -match '\{[0-9A-Fa-f-]{36}\}') { $Matches[0] } } | Sort-Object -Unique
foreach ($id in $ids) {
    $name = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$id" -ErrorAction SilentlyContinue).'(default)'
    if (-not $name) { $name = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\AppID\$id" -ErrorAction SilentlyContinue).'(default)' }
    $srv = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$id\LocalServer32" -ErrorAction SilentlyContinue).'(default)'
    Say ("  {0}  x{1}  {2}  {3}" -f $id, @($dcom | Where-Object Message -match [regex]::Escape($id)).Count, $name, $srv)
}
if (-not $ids) { Say "  Ошибок DCOM 10010 за 7 дней нет." 'Green' }

# ---------------------------------------------------------------------------
Head 11 'ВРЕМЯ И СИНХРОНИЗАЦИЯ'
if (Confirm-Step "Синхронизировать системное время с сервером времени?") {
    Start-Service w32time -ErrorAction SilentlyContinue
    w32tm /resync | Out-Null
    Note "Время синхронизировано."
}

# ---------------------------------------------------------------------------
Head 'ИТОГ' 'РЕЗУЛЬТАТЫ'
if ($summary.Count -eq 0) { Say "  Замечаний нет." 'Green' } else { $i = 1; foreach ($s in $summary) { Say "  $i. $s" 'Yellow'; $i++ } }
$summary | Out-File (Join-Path $workDir 'summary.txt') -Encoding UTF8
if ($Apply) {
    Say "`n  Откат обратимых изменений: $rollback" 'Green'
    Say "  Полный откат: Win+R -> rstrui.exe -> точка «SSV-Optimize $stamp»" 'Green'
    Say "  РЕКОМЕНДУЕТСЯ ПЕРЕЗАГРУЗКА." 'Magenta'
} else {
    Say "`n  Это был аудит. Для применения: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply" 'Green'
}
Stop-Transcript | Out-Null
