<#
.SYNOPSIS
    Диагностика медленной работы Windows 11 (только чтение, ничего не меняет).
.DESCRIPTION
    Собирает сведения о CPU, RAM, дисках, автозагрузке, процессах, Docker/WSL,
    Defender, журналах ошибок и формирует отчёт с автоматическими выводами.
    Отчёт сохраняется на рабочий стол: SlowPC_Report_<дата>.txt
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-SlowPC.ps1
#>

$ErrorActionPreference = 'SilentlyContinue'
$stamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) "SlowPC_Report_$stamp.txt"
$issues = New-Object System.Collections.Generic.List[string]
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Section($title) { "`n==================== $title ====================" }
function Flag($text)     { $issues.Add($text) }

$out = @()
$out += "ОТЧЁТ ДИАГНОСТИКИ ПРОИЗВОДИТЕЛЬНОСТИ — $(Get-Date)"
$out += "Компьютер: $env:COMPUTERNAME   Пользователь: $env:USERNAME   Админ: $isAdmin"
if (-not $isAdmin) { $out += "!! Запущено без прав администратора — часть данных (SMART, журналы) может быть неполной." }

Write-Host "[1/12] Система..." -ForegroundColor Cyan
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$uptime = (Get-Date) - $os.LastBootUpTime
$out += Section 'СИСТЕМА'
$out += "ОС: $($os.Caption) build $($os.BuildNumber)"
$out += "Модель: $($cs.Manufacturer) $($cs.Model)"
$out += "CPU: $($cpu.Name)  ядер/потоков: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors)  частота: $($cpu.CurrentClockSpeed)/$($cpu.MaxClockSpeed) МГц"
$out += "Аптайм: {0} дн {1} ч {2} мин" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
if ($uptime.TotalDays -gt 7) { Flag "Компьютер не перезагружался $([int]$uptime.TotalDays) дней — сделайте полную перезагрузку (Пуск → Перезагрузка, не «Завершение работы»)." }
if ($cpu.MaxClockSpeed -gt 0 -and $cpu.CurrentClockSpeed -lt ($cpu.MaxClockSpeed * 0.5)) {
    Flag "CPU работает на $($cpu.CurrentClockSpeed) из $($cpu.MaxClockSpeed) МГц — возможен троттлинг (перегрев / режим энергосбережения)."
}

Write-Host "[2/12] Память..." -ForegroundColor Cyan
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
$out += Section 'ПАМЯТЬ'
$out += "Всего: $totalGB ГБ   Свободно: $freeGB ГБ   Занято: $usedPct %"
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    $out += "  Модуль: {0} ГБ  {1} МГц  {2}" -f ($_.Capacity/1GB), $_.ConfiguredClockSpeed, $_.PartNumber
}
$pf = Get-CimInstance Win32_PageFileUsage
foreach ($p in $pf) { $out += "Файл подкачки: $($p.Name)  размер $($p.AllocatedBaseSize) МБ  использовано $($p.CurrentUsage) МБ  пик $($p.PeakUsage) МБ" }
if ($totalGB -lt 8)  { Flag "Всего $totalGB ГБ RAM — для Windows 11 + браузер + Docker это мало; рекомендуется 16 ГБ и больше." }
if ($usedPct -ge 85) { Flag "Память занята на $usedPct % — система активно использует файл подкачки (главная причина «тормозов»)." }

Write-Host "[3/12] Диски..." -ForegroundColor Cyan
$out += Section 'ДИСКИ'
Get-PhysicalDisk | ForEach-Object {
    $out += "Физ. диск: $($_.FriendlyName)  тип: $($_.MediaType)  шина: $($_.BusType)  состояние: $($_.HealthStatus)  $([math]::Round($_.Size/1GB)) ГБ"
    if ($_.MediaType -eq 'HDD') { Flag "Диск «$($_.FriendlyName)» — механический HDD. Если на нём система, замена на SSD даст самый большой прирост скорости." }
    if ($_.HealthStatus -ne 'Healthy') { Flag "Диск «$($_.FriendlyName)» в состоянии $($_.HealthStatus) — СРОЧНО сделайте резервную копию данных!" }
    $rel = $_ | Get-StorageReliabilityCounter
    if ($rel) {
        $out += "   Температура: $($rel.Temperature) °C  износ: $($rel.Wear) %  ошибки чтения: $($rel.ReadErrorsTotal)  ошибки записи: $($rel.WriteErrorsTotal)"
        if ($rel.Wear -ge 80) { Flag "SSD «$($_.FriendlyName)» изношен на $($rel.Wear) %." }
        if ($rel.Temperature -ge 70) { Flag "Диск «$($_.FriendlyName)» нагрет до $($rel.Temperature) °C — возможен троттлинг." }
    }
}
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $pct = if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100) } else { 0 }
    $out += "Том $($_.DeviceID)  свободно $([math]::Round($_.FreeSpace/1GB,1)) из $([math]::Round($_.Size/1GB,1)) ГБ ($pct %)"
    if ($pct -lt 15) { Flag "На диске $($_.DeviceID) свободно всего $pct % — Windows замедляется при заполнении >85–90 %." }
}

Write-Host "[4/12] Загрузка CPU/диска (замер 10 сек)..." -ForegroundColor Cyan
$out += Section 'НАГРУЗКА (замер 10 сек)'
$ctr = Get-Counter -Counter '\Processor(_Total)\% Processor Time','\PhysicalDisk(_Total)\% Disk Time','\Memory\Pages/sec' -SampleInterval 2 -MaxSamples 5
if ($ctr) {
    $avg = $ctr.CounterSamples | Group-Object Path | ForEach-Object {
        [pscustomobject]@{ Counter = $_.Name; Avg = [math]::Round(($_.Group | Measure-Object CookedValue -Average).Average, 1) }
    }
    $avg | ForEach-Object { $out += "{0,-55} {1}" -f $_.Counter, $_.Avg }
    $cpuAvg  = ($avg | Where-Object Counter -like '*processor time*').Avg
    $diskAvg = ($avg | Where-Object Counter -like '*disk time*').Avg
    $pages   = ($avg | Where-Object Counter -like '*pages/sec*').Avg
    if ($cpuAvg  -ge 70)  { Flag "CPU загружен в среднем на $cpuAvg % в простое — смотрите «ТОП процессов по CPU»." }
    if ($diskAvg -ge 80)  { Flag "Диск загружен на $diskAvg % — узкое место в диске (HDD, индексация, антивирус, обновления)." }
    if ($pages   -ge 500) { Flag "Активный свопинг ($pages стр/с) — не хватает оперативной памяти." }
} else { $out += "(счётчики производительности недоступны — возможно, неанглийские имена счётчиков)" }

Write-Host "[5/12] Процессы..." -ForegroundColor Cyan
$out += Section 'ТОП-15 ПРОЦЕССОВ ПО ПАМЯТИ'
$procs = Get-Process
$procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
    $out += "{0,-35} {1,8} МБ" -f $_.ProcessName, [math]::Round($_.WorkingSet64/1MB)
}
$out += Section 'ТОП-15 ПРОЦЕССОВ ПО CPU (замер 5 сек)'
$s1 = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total','Idle' }
Start-Sleep -Seconds 5
$s2 = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total','Idle' }
$s2 | Sort-Object PercentProcessorTime -Descending | Select-Object -First 15 | ForEach-Object {
    $out += "{0,-35} {1,5} % (от одного ядра)" -f $_.Name, $_.PercentProcessorTime
}
$out += Section 'СУММАРНО ПО ПРИЛОЖЕНИЯМ (МБ)'
$groups = $procs | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
} | Sort-Object MB -Descending | Select-Object -First 10
$groups | ForEach-Object { $out += "{0,-30} x{1,-4} {2,8} МБ" -f $_.Name, $_.Count, $_.MB }
foreach ($b in 'chrome','msedge','firefox','opera','browser') {
    $g = $groups | Where-Object Name -eq $b
    if ($g -and $g.MB -gt 3000) { Flag "Браузер $b занимает $($g.MB) МБ ($($g.Count) процессов) — закройте лишние вкладки / расширения." }
}

Write-Host "[6/12] Docker / WSL..." -ForegroundColor Cyan
$out += Section 'DOCKER / WSL / ВИРТУАЛИЗАЦИЯ'
$vm = $procs | Where-Object { $_.ProcessName -match '^(vmmem|vmmemWSL|VmmemWSL|com\.docker|Docker Desktop|vmwp)' }
if ($vm) {
    $vm | ForEach-Object { $out += "{0,-30} {1,8} МБ" -f $_.ProcessName, [math]::Round($_.WorkingSet64/1MB) }
    $vmMB = [math]::Round(($vm | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    if ($vmMB -gt 3000) { Flag "Docker/WSL (vmmem) занимает $vmMB МБ. Ограничьте память в %USERPROFILE%\.wslconfig ([wsl2] memory=4GB) и выполните «wsl --shutdown», когда Docker не нужен." }
} else { $out += "vmmem / Docker не запущены." }
$wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wslcfg) { $out += ".wslconfig:"; $out += (Get-Content $wslcfg) } else { $out += ".wslconfig отсутствует (WSL2 может забрать до 50 % RAM)." }
$vhdx = Get-ChildItem "$env:LOCALAPPDATA" -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object FullName, @{n='GB';e={[math]::Round($_.Length/1GB,1)}}
$vhdx | ForEach-Object { $out += "VHDX: $($_.FullName)  $($_.GB) ГБ"; if ($_.GB -gt 40) { Flag "Образ диска WSL/Docker $($_.FullName) весит $($_.GB) ГБ — выполните «docker system prune -a» и сжатие VHDX." } }

Write-Host "[7/12] Автозагрузка..." -ForegroundColor Cyan
$out += Section 'АВТОЗАГРУЗКА'
$startup = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location
$startup | ForEach-Object { $out += "{0,-35} [{1}]  {2}" -f $_.Name, $_.Location, $_.Command }
if ($startup.Count -gt 12) { Flag "В автозагрузке $($startup.Count) программ — отключите лишние: Диспетчер задач (Ctrl+Shift+Esc) → «Автозагрузка приложений»." }
$out += "`nЗапланированные задачи сторонних программ (активные):"
Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
    ForEach-Object { $out += "  $($_.TaskPath)$($_.TaskName)" }

Write-Host "[8/12] Питание..." -ForegroundColor Cyan
$out += Section 'ЭЛЕКТРОПИТАНИЕ'
$plan = powercfg /getactivescheme
$out += $plan
if ($plan -match 'Power saver|Экономия|Энергосбереж') { Flag "Активна схема «Экономия энергии» — переключите на «Сбалансированная» или «Высокая производительность»." }
$bat = Get-CimInstance Win32_Battery
if ($bat) { $out += "Батарея: заряд $($bat.EstimatedChargeRemaining) %  статус $($bat.BatteryStatus)" }

Write-Host "[9/12] Защитник и службы..." -ForegroundColor Cyan
$out += Section 'АНТИВИРУС / СЛУЖБЫ'
$av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct
$av | ForEach-Object { $out += "Антивирус: $($_.displayName)" }
if (@($av).Count -gt 1) { Flag "Установлено несколько антивирусов ($(@($av).displayName -join ', ')) — они конфликтуют и сильно тормозят систему. Оставьте один." }
$mp = Get-MpComputerStatus
if ($mp) {
    $out += "Defender: RealTime=$($mp.RealTimeProtectionEnabled)  последнее полное сканирование: $($mp.FullScanEndTime)"
    $threats = Get-MpThreatDetection
    if ($threats) { Flag "Defender обнаруживал угрозы ($(@($threats).Count)) — проверьте «Безопасность Windows → Журнал защиты» и выполните полное сканирование." }
}
foreach ($svc in 'SysMain','WSearch','DiagTrack','wuauserv') {
    $s = Get-Service $svc
    if ($s) { $out += "{0,-12} {1,-8} {2}" -f $svc, $s.Status, $s.StartType }
}

Write-Host "[10/12] Временные файлы..." -ForegroundColor Cyan
$out += Section 'ВРЕМЕННЫЕ ФАЙЛЫ'
foreach ($path in "$env:TEMP", "$env:windir\Temp", "$env:windir\SoftwareDistribution\Download", "$env:LOCALAPPDATA\CrashDumps") {
    if (Test-Path $path) {
        $size = [math]::Round(((Get-ChildItem $path -Recurse -Force -File | Measure-Object Length -Sum).Sum) / 1GB, 2)
        $out += "{0,-60} {1} ГБ" -f $path, $size
        if ($size -gt 5) { Flag "Папка $path занимает $size ГБ — очистите через «Параметры → Система → Память → Временные файлы»." }
    }
}

Write-Host "[11/12] Журналы ошибок (7 дней)..." -ForegroundColor Cyan
$out += Section 'КРИТИЧЕСКИЕ СОБЫТИЯ ЗА 7 ДНЕЙ'
$since = (Get-Date).AddDays(-7)
$ev = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=$since } -MaxEvents 300
$ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
    $msg = ($_.Group[0].Message -split "`n")[0]
    $out += "{0,4} x  {1}  —  {2}" -f $_.Count, $_.Name, $msg
}
$diskErr = $ev | Where-Object { $_.ProviderName -match '^(disk|Ntfs|stornvme|storahci)$' -or $_.Id -in 7,51,153,129 }
if ($diskErr) { Flag "В журнале $(@($diskErr).Count) ошибок диска/контроллера — возможна деградация накопителя или кабеля. Сделайте резервную копию и запустите «chkdsk C: /scan»." }
$whea = $ev | Where-Object ProviderName -eq 'Microsoft-Windows-WHEA-Logger'
if ($whea) { Flag "Аппаратные ошибки WHEA ($(@($whea).Count)) — проблема с CPU/RAM/PCIe (перегрев, разгон, нестабильная память)." }
$bsod = $ev | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' }
if ($bsod) { Flag "Неожиданные перезагрузки/зависания (Kernel-Power 41): $(@($bsod).Count) раз." }
$boot = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100 } -MaxEvents 1
if ($boot) {
    $bootSec = [math]::Round(([xml]$boot.ToXml()).Event.EventData.Data | Where-Object Name -eq 'BootTime' | ForEach-Object { [int]$_.'#text' / 1000 }, 0)
    $out += "Время последней загрузки: $bootSec сек"
    if ($bootSec -gt 60) { Flag "Загрузка Windows занимает $bootSec сек (норма для SSD 15–30 сек) — смотрите автозагрузку." }
}

Write-Host "[12/12] Обновления и драйверы..." -ForegroundColor Cyan
$out += Section 'ОБНОВЛЕНИЯ'
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 | ForEach-Object { $out += "$($_.HotFixID)  $($_.InstalledOn)" }
$last = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn
if ($last -and ((Get-Date) - $last).TotalDays -gt 60) { Flag "Последнее обновление Windows было $([int]((Get-Date)-$last).TotalDays) дней назад." }
$out += Section 'ВИДЕОКАРТА'
Get-CimInstance Win32_VideoController | ForEach-Object { $out += "$($_.Name)  драйвер $($_.DriverVersion) от $($_.DriverDate)" }
$bad = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
if ($bad) { $bad | ForEach-Object { $out += "Проблемное устройство: $($_.Name) (код $($_.ConfigManagerErrorCode))" }; Flag "Есть устройства с ошибками драйверов ($(@($bad).Count)) — см. Диспетчер устройств." }

# ---------- Итог ----------
$summary = @()
$summary += Section 'ВЫВОДЫ (ВЕРОЯТНЫЕ ПРИЧИНЫ ТОРМОЗОВ)'
if ($issues.Count -eq 0) { $summary += "Явных проблем не найдено. Пришлите отчёт для ручного анализа." }
else { $i = 1; foreach ($x in $issues) { $summary += "$i. $x"; $i++ } }

($out[0..2] + $summary + $out[3..($out.Count-1)]) | Out-File -FilePath $report -Encoding UTF8
Write-Host "`n$($summary -join "`n")" -ForegroundColor Yellow
Write-Host "`nПолный отчёт сохранён: $report" -ForegroundColor Green
