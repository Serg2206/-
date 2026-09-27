<#
.SYNOPSIS
    Проверка всех исправлений от 27.09.2026 (только чтение, ничего не меняет).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Verify-Fixes.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'
$out = New-Object System.Collections.Generic.List[string]
$cnt = @{ OK = 0; WARN = 0; FAIL = 0 }
function R($status, $name, $detail) {
    $cnt[$status]++
    $line = "[{0,-4}] {1,-42} {2}" -f $status, $name, $detail
    $out.Add($line)
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$status]
    Write-Host $line -ForegroundColor $color
}
function H($t) { $out.Add("`n=== $t ==="); Write-Host "`n=== $t ===" -ForegroundColor Cyan }

$os   = Get-CimInstance Win32_OperatingSystem
$boot = $os.LastBootUpTime
$out.Add("ПРОВЕРКА ИСПРАВЛЕНИЙ — $(Get-Date)   Загрузка: $boot")
Write-Host "Загрузка системы: $boot"

H 'СЛУЖБЫ И ПАМЯТЬ'
foreach ($s in 'WSearch', 'SysMain') {
    $svc = Get-Service $s
    if ($svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic') { R OK $s 'Running / Automatic' }
    else { R FAIL $s "$($svc.Status) / $($svc.StartType)" }
}
$auto = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
$pf   = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles -join '; '
if ($auto) { R OK 'Файл подкачки: автоматический' $pf } else { R FAIL 'Файл подкачки: автоматический' "нет — $pf" }
$v46 = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='volmgr'; Id=46; StartTime=$boot}).Count
if ($v46 -eq 0) { R OK 'Аварийный дамп (volmgr 46)' 'ошибок нет' } else { R FAIL 'Аварийный дамп (volmgr 46)' "$v46 ошибок" }
$tm = [Environment]::GetEnvironmentVariable('TEMP', 'Machine')
if ($tm -match '\\Windows\\Temp$') { R OK 'TEMP системная' $tm } else { R FAIL 'TEMP системная' $tm }
if ($env:TEMP -like "*\AppData\Local\Temp") { R OK 'TEMP пользователя' $env:TEMP } else { R WARN 'TEMP пользователя' $env:TEMP }

H 'ЗАДАЧИ ПЛАНИРОВЩИКА'
$t = Get-ScheduledTask -TaskName 'Weekly System Maintenance'
if (-not $t -or $t.State -eq 'Disabled') { R OK 'Weekly System Maintenance (Kimi)' 'отключена/удалена' } else { R FAIL 'Weekly System Maintenance (Kimi)' $t.State }
foreach ($n in 'PostReboot Optimization Check', 'Defender Full Scan Nightly') {
    if (Get-ScheduledTask -TaskName $n) { R WARN $n 'ещё существует' } else { R OK $n 'удалена' }
}
$sk = @(Get-ScheduledTask | Where-Object { ($_.TaskName -eq 'update-sys' -or $_.TaskName -like 'update-S-1-5-*') -and $_.State -ne 'Disabled' })
if ($sk.Count -eq 0) { R OK 'Обновлятор Lightshot (Skillbrains)' 'отключён' } else { R WARN 'Обновлятор Lightshot (Skillbrains)' "$($sk.Count) задач активны" }
$pol = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System').DefaultAssociationsConfiguration
if (-not $pol) { R OK 'Политика браузера по умолчанию' 'удалена' } else { R FAIL 'Политика браузера по умолчанию' $pol }

H 'WI-FI / BLUETOOTH'
$wifi = Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName -match 'AX210' | Select-Object -First 1
if ($wifi.DriverVersion -match '^(2[4-9]|[3-9]\d)\.') { R OK 'Драйвер Wi-Fi AX210' $wifi.DriverVersion } else { R FAIL 'Драйвер Wi-Fi AX210' $wifi.DriverVersion }
$pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable | Where-Object { $_.InstanceName -match 'VEN_8086&DEV_2725' }
if ($pm -and -not $pm.Enable) { R OK 'Wi-Fi: запрет отключения питания' 'включён' } elseif ($pm) { R WARN 'Wi-Fi: запрет отключения питания' 'не применён' } else { R OK 'Wi-Fi: запрет отключения питания' 'управляется драйвером' }
$wErr = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Netwtw14','BTHUSB'; Level=1,2,3; StartTime=$boot}).Count
if ($wErr -eq 0) { R OK 'Ошибки Wi-Fi/Bluetooth с загрузки' '0' } else { R WARN 'Ошибки Wi-Fi/Bluetooth с загрузки' $wErr }

H 'ОПТИМИЗАЦИЯ (Optimize-Workstation -Apply)'
$last = Get-ChildItem 'C:\SSV-Optimize' -Directory | Sort-Object Name | Select-Object -Last 1
if ($last) {
    $tr = Join-Path $last.FullName 'transcript.log'
    $applied = Select-String $tr -Pattern 'ПРИМЕНЕНИЕ ИЗМЕНЕНИЙ' -Quiet
    if ($applied) { R OK 'Режим -Apply выполнен' $last.Name } else { R FAIL 'Режим -Apply выполнен' "последний запуск ($($last.Name)) — только аудит" }
    $rp = Get-ComputerRestorePoint | Where-Object { $_.Description -like 'SSV-Optimize*' } | Select-Object -Last 1
    if ($rp) { R OK 'Точка восстановления' $rp.Description } else { R WARN 'Точка восстановления' 'SSV-Optimize не найдена' }
    $sfc = Select-String $tr -Pattern 'Защита ресурсов Windows|Windows Resource Protection' | Select-Object -Last 1
    if (-not $sfc) { R WARN 'SFC' 'не запускался (ответ N?)' }
    elseif ($sfc.Line -match 'не обнаружила|did not find') { R OK 'SFC' 'нарушений целостности нет' }
    elseif ($sfc.Line -match 'успешно|successfully') { R OK 'SFC' 'повреждения найдены и ИСПРАВЛЕНЫ' }
    else { R FAIL 'SFC' $sfc.Line.Trim() }
    $dism = Select-String $tr -Pattern 'Операция успешно завершена|operation completed successfully|Восстановление выполнено|restore operation completed' -Quiet
    if ($dism) { R OK 'DISM /RestoreHealth' 'успешно' } else { R WARN 'DISM /RestoreHealth' 'нет отметки об успехе в журнале' }
    $sum = Join-Path $last.FullName 'summary.txt'
    if (Test-Path $sum) { $out.Add('--- summary.txt ---'); Get-Content $sum | ForEach-Object { $out.Add("   $_") } }
} else { R FAIL 'Optimize-Workstation' 'папка C:\SSV-Optimize не найдена' }
$wsl = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wsl) { R OK '.wslconfig' ((Get-Content $wsl | Where-Object { $_ -match 'memory' }) -join ' ') } else { R WARN '.wslconfig' 'не создан (норма, если Docker не нужен)' }
$wg = winget upgrade --accept-source-agreements 2>$null | Select-String '^\s*\d+\s.*(upgrade|обновлен)'
if ($wg) { R WARN 'winget: осталось обновлений' ($wg.Line.Trim()) } else { R OK 'winget: программы' 'всё обновлено' }

H 'СТАБИЛЬНОСТЬ С МОМЕНТА ЗАГРУЗКИ'
$crit = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$boot}
$hours = [math]::Max(1, [math]::Round(((Get-Date) - $boot).TotalHours))
$perDay = [math]::Round(@($crit).Count / $hours * 24)
$msg = "{0} за {1} ч (~{2}/сутки; было ~24/сутки)" -f @($crit).Count, $hours, $perDay
if ($perDay -le 10) { R OK 'Ошибки в журнале System' $msg } else { R WARN 'Ошибки в журнале System' $msg }
$crit | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
    $l = "   {0,4} x {1} — {2}" -f $_.Count, $_.Name, (($_.Group[0].Message -split "`n")[0])
    $out.Add($l); Write-Host $l
}
$kp = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; StartTime=$boot}).Count
if ($kp -eq 0) { R OK 'Аварийные перезагрузки (Kernel-Power 41)' '0' } else { R FAIL 'Аварийные перезагрузки (Kernel-Power 41)' $kp }
$cx = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; StartTime=$boot}).Count
if ($cx -eq 0) { R OK 'Ошибки установки обновлений (Codex)' '0' } else { R WARN 'Ошибки установки обновлений (Codex)' $cx }
$bt = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 1
if ($bt) {
    $ms = (([xml]$bt.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
    $sec = [math]::Round([int]$ms / 1000)
    if ($sec -le 40) { R OK 'Время загрузки Windows' "$sec сек (было 48)" } else { R WARN 'Время загрузки Windows' "$sec сек (было 48)" }
}
$ram = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
R OK 'Занято памяти сейчас' "$ram %"

$tot = "`nИТОГ: OK={0}  WARN={1}  FAIL={2}" -f $cnt.OK, $cnt.WARN, $cnt.FAIL
$out.Add($tot); Write-Host $tot -ForegroundColor Magenta
$file = Join-Path ([Environment]::GetFolderPath('Desktop')) ("Verify_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))
$out | Out-File $file -Encoding UTF8
Write-Host "Отчёт сохранён: $file" -ForegroundColor Green
