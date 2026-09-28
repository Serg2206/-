#Requires -Version 5.1
<#
.SYNOPSIS
    Аудит Windows 11 Pro для рабочей станции хирурга-автора (видео операций,
    медицинские изображения, публикации, Docker/автоматизация).

.DESCRIPTION
    Скрипт ТОЛЬКО ЧИТАЕТ информацию и ничего не меняет в системе.
    Результат: папка SystemAudit_<дата> на Рабочем столе (report.txt,
    programs.csv, drivers.csv) и zip-архив с ней.
    Для полного отчёта (BitLocker, TPM, Secure Boot, SMART) запускайте
    PowerShell от имени администратора.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Collect-SystemAudit.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Collect-SystemAudit.ps1 -EventDays 14 -NoAnonymize
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = [Environment]::GetFolderPath('Desktop'),
    [int]$EventDays = 7,
    [switch]$NoAnonymize
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$outDir = Join-Path $OutputRoot "SystemAudit_$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$reportPath = Join-Path $outDir 'report.txt'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$sb = New-Object System.Text.StringBuilder
$findings = New-Object System.Collections.Generic.List[object]

function Add-Line([string]$text = '') { [void]$sb.AppendLine($text) }

function Add-Section([string]$title) {
    Write-Host "  -> $title" -ForegroundColor Cyan
    Add-Line
    Add-Line ('=' * 78)
    Add-Line "  $title"
    Add-Line ('=' * 78)
}

function Add-Table($data) {
    if ($null -eq $data -or @($data).Count -eq 0) { Add-Line '  (нет данных)'; return }
    Add-Line (($data | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd())
}

# Уровни: 1 = КРИТИЧНО, 2 = ВАЖНО, 3 = СОВЕТ
function Add-Finding([int]$level, [string]$text) {
    $findings.Add([pscustomobject]@{ Level = $level; Text = $text })
}

function Invoke-Safe([string]$name, [scriptblock]$block) {
    try { & $block }
    catch { Add-Line "  ! Не удалось получить '$name': $($_.Exception.Message)" }
}

function Format-Date($d) {
    if ($d) { try { return ([datetime]$d).ToString('yyyy-MM-dd') } catch { return "$d" } }
    return ''
}

function Get-AgeDays($d) {
    if (-not $d) { return $null }
    try { return [int]((Get-Date) - [datetime]$d).TotalDays } catch { return $null }
}

# Запуск внешней утилиты с таймаутом (docker/wsl могут зависать)
function Invoke-External([string]$exe, [string[]]$arguments, [int]$timeoutSec = 25) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $null }
    $job = Start-Job -ScriptBlock {
        param($e, $a)
        $env:WSL_UTF8 = '1'
        & $e @a 2>&1 | Out-String
    } -ArgumentList $exe, $arguments
    if (Wait-Job $job -Timeout $timeoutSec) { $out = Receive-Job $job }
    else { Stop-Job $job; $out = "(таймаут $timeoutSec с)" }
    Remove-Job $job -Force
    if ($out) { return (($out -replace "`0", '').Trim()) }
    return ''
}

Write-Host ''
Write-Host 'Аудит Windows: сбор данных (1-3 минуты)...' -ForegroundColor Green
if (-not $isAdmin) {
    Write-Host 'ВНИМАНИЕ: запущено без прав администратора - часть проверок будет пропущена.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
Add-Section '1. СИСТЕМА'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$uptime = (Get-Date) - $os.LastBootUpTime

Add-Line ("  Отчёт создан   : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Add-Line ("  Права админа   : {0}" -f $isAdmin)
Add-Line ("  PowerShell     : {0}" -f $PSVersionTable.PSVersion)
Add-Line ("  Система        : {0} ({1})" -f $os.Caption, $cv.DisplayVersion)
Add-Line ("  Сборка         : {0}.{1}" -f $os.BuildNumber, $cv.UBR)
Add-Line ("  Установлена    : {0}" -f (Format-Date $os.InstallDate))
Add-Line ("  Аптайм         : {0} д {1} ч" -f $uptime.Days, $uptime.Hours)
Add-Line ("  Компьютер      : {0} {1}" -f $cs.Manufacturer, $cs.Model)
Add-Line ("  ОЗУ всего      : {0:N1} ГБ" -f ($cs.TotalPhysicalMemory / 1GB))

switch -Regex ($cv.DisplayVersion) {
    '^(21H2|22H2|23H2)$' { Add-Finding 1 "Windows 11 $($cv.DisplayVersion) больше не получает обновлений безопасности - обновитесь до 25H2 (Параметры > Центр обновления Windows)." }
    '^24H2$' { Add-Finding 2 'Поддержка Windows 11 24H2 Pro заканчивается 13.10.2026 - запланируйте обновление до 25H2.' }
}
if ($uptime.TotalDays -gt 14) {
    Add-Finding 3 ("Компьютер не перезагружался {0} дней - обновления и драйверы применяются только после перезагрузки." -f $uptime.Days)
}

Invoke-Safe 'Активация' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
        Select-Object -First 1
    $state = if ($lic.LicenseStatus -eq 1) { 'активирована' } else { "НЕ активирована (код $($lic.LicenseStatus))" }
    Add-Line ("  Активация      : {0}" -f $state)
    if ($lic.LicenseStatus -ne 1) { Add-Finding 2 'Windows не активирована.' }
}

# ---------------------------------------------------------------------------
Add-Section '2. ПРОЦЕССОР, ПАМЯТЬ, ВИДЕОКАРТА, МОНИТОРЫ'
Invoke-Safe 'CPU' {
    Add-Table (Get-CimInstance Win32_Processor | Select-Object Name,
        @{ n = 'Ядер'; e = { $_.NumberOfCores } },
        @{ n = 'Потоков'; e = { $_.NumberOfLogicalProcessors } },
        @{ n = 'МГц'; e = { $_.MaxClockSpeed } })
}
Invoke-Safe 'RAM' {
    $ram = Get-CimInstance Win32_PhysicalMemory
    Add-Table ($ram | Select-Object @{ n = 'Слот'; e = { $_.DeviceLocator } },
        @{ n = 'ГБ'; e = { [math]::Round($_.Capacity / 1GB) } },
        @{ n = 'МГц'; e = { $_.ConfiguredClockSpeed } },
        Manufacturer, PartNumber)
    $totalGb = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
    if ($totalGb -lt 16) { Add-Finding 2 "ОЗУ $totalGb ГБ - мало для монтажа видео операций и Docker; минимум 16 ГБ, оптимально 32 ГБ." }
    elseif ($totalGb -lt 32) { Add-Finding 3 "ОЗУ $totalGb ГБ - для монтажа 4K-видео и одновременной работы Docker желательно 32 ГБ." }
    if (@($ram).Count -eq 1) { Add-Finding 3 'Установлен один модуль памяти - работает одноканальный режим (медленнее для видео и графики). Рассмотрите пару модулей.' }
}
Invoke-Safe 'GPU' {
    $gpus = Get-CimInstance Win32_VideoController
    Add-Table ($gpus | Select-Object Name, DriverVersion,
        @{ n = 'Дата драйвера'; e = { Format-Date $_.DriverDate } },
        @{ n = 'Режим'; e = { $_.VideoModeDescription } })
    foreach ($g in $gpus) {
        if ($g.Name -match 'Basic Display|Базовый видеоадаптер') {
            Add-Finding 1 "Видеокарта работает на стандартном драйвере Microsoft ($($g.Name)) - установите драйвер производителя (NVIDIA/AMD/Intel)."
            continue
        }
        $age = Get-AgeDays $g.DriverDate
        if ($age -gt 365) { Add-Finding 2 ("Драйвер видеокарты '{0}' старше года ({1}) - обновите с сайта производителя (важно для аппаратного кодирования видео)." -f $g.Name, (Format-Date $g.DriverDate)) }
    }
    $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue).HwSchMode
    $hagsText = switch ($hags) { 2 { 'включено' } 1 { 'выключено' } default { 'по умолчанию' } }
    Add-Line ("  Аппаратное планирование GPU (HAGS): {0}" -f $hagsText)
}
Invoke-Safe 'Мониторы' {
    $mons = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
    $list = foreach ($m in $mons) {
        $name = ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
        $vendor = ($m.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
        [pscustomobject]@{ 'Монитор' = $name; 'Производитель' = $vendor; 'Год выпуска' = $m.YearOfManufacture }
    }
    Add-Line '  Подключённые мониторы:'
    Add-Table $list
}

# ---------------------------------------------------------------------------
Add-Section '3. ДИСКИ И СВОБОДНОЕ МЕСТО'
Invoke-Safe 'Физические диски' {
    $disks = Get-PhysicalDisk
    Add-Table ($disks | Select-Object FriendlyName, MediaType, BusType,
        @{ n = 'Здоровье'; e = { $_.HealthStatus } },
        @{ n = 'ГБ'; e = { [math]::Round($_.Size / 1GB) } })
    foreach ($d in $disks) {
        if ($d.HealthStatus -ne 'Healthy') { Add-Finding 1 "Диск '$($d.FriendlyName)' в состоянии $($d.HealthStatus) - срочно сделайте резервную копию!" }
    }
    if ($isAdmin) {
        $rel = $disks | ForEach-Object {
            $c = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            [pscustomobject]@{
                'Диск'             = $_.FriendlyName
                'Температура'      = $c.Temperature
                'Износ %'          = $c.Wear
                'Ошибки чтения'    = $c.ReadErrorsUncorrected
                'Часов работы'     = $c.PowerOnHours
            }
        }
        Add-Line '  SMART:'
        Add-Table $rel
        foreach ($r in $rel) {
            if ($r.'Износ %' -ge 80) { Add-Finding 1 "SSD '$($r.'Диск')' изношен на $($r.'Износ %')% - готовьте замену." }
            if ($r.'Ошибки чтения' -gt 0) { Add-Finding 1 "На диске '$($r.'Диск')' есть неисправимые ошибки чтения - сделайте резервную копию." }
        }
    }
    $sysDisk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
    $sysPhys = $disks | Where-Object { $_.DeviceId -eq "$($sysDisk.Number)" }
    if ($sysPhys.MediaType -eq 'HDD') { Add-Finding 2 'Windows установлена на HDD - замена на NVMe SSD даст самый большой прирост скорости.' }
}
Invoke-Safe 'Тома' {
    $vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter
    Add-Table ($vols | Select-Object @{ n = 'Диск'; e = { "$($_.DriveLetter):" } },
        @{ n = 'Метка'; e = { $_.FileSystemLabel } }, FileSystem,
        @{ n = 'Всего ГБ'; e = { [math]::Round($_.Size / 1GB) } },
        @{ n = 'Свободно ГБ'; e = { [math]::Round($_.SizeRemaining / 1GB) } },
        @{ n = 'Свободно %'; e = { [math]::Round(100 * $_.SizeRemaining / $_.Size) } })
    foreach ($v in $vols) {
        $pct = 100 * $v.SizeRemaining / $v.Size
        if ($pct -lt 10) { Add-Finding 1 ("На диске {0}: свободно всего {1:N0}% - очистите место (видеофайлы, Загрузки, образы Docker)." -f $v.DriveLetter, $pct) }
        elseif ($pct -lt 20) { Add-Finding 2 ("На диске {0}: свободно {1:N0}% - для монтажа видео нужно 20%+ свободного места." -f $v.DriveLetter, $pct) }
    }
}

# ---------------------------------------------------------------------------
Add-Section '4. БЕЗОПАСНОСТЬ (данные пациентов!)'
Invoke-Safe 'Антивирус' {
    $thirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } | ForEach-Object { $_.displayName })
    if ($thirdParty.Count) { Add-Line ("  Сторонний антивирус : {0}" -f ($thirdParty -join ', ')) }
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Add-Line ("  Defender включён    : {0}" -f $mp.AntivirusEnabled)
    Add-Line ("  Защита в реал. врем.: {0}" -f $mp.RealTimeProtectionEnabled)
    Add-Line ("  Защита от подделки  : {0}" -f $mp.IsTamperProtected)
    Add-Line ("  Базы обновлены      : {0}" -f (Format-Date $mp.AntivirusSignatureLastUpdated))
    if (-not $mp.AntivirusEnabled -and -not $thirdParty.Count) { Add-Finding 1 'Антивирусная защита выключена.' }
    if ($mp.AntivirusEnabled -and (Get-AgeDays $mp.AntivirusSignatureLastUpdated) -gt 3) { Add-Finding 2 'Антивирусные базы Defender устарели более чем на 3 дня.' }
    if ($mp.AntivirusEnabled -and -not $mp.RealTimeProtectionEnabled) { Add-Finding 1 'Защита Defender в реальном времени выключена.' }
}
Invoke-Safe 'Брандмауэр' {
    $fw = Get-NetFirewallProfile
    Add-Line ("  Брандмауэр          : {0}" -f (($fw | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', '))
    foreach ($p in $fw) { if (-not $p.Enabled) { Add-Finding 1 "Брандмауэр выключен для профиля $($p.Name)." } }
}
Invoke-Safe 'UAC' {
    $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA
    Add-Line ("  UAC                 : {0}" -f ($(if ($uac -eq 1) { 'включён' } else { 'ВЫКЛЮЧЕН' })))
    if ($uac -ne 1) { Add-Finding 1 'Контроль учётных записей (UAC) выключен.' }
}
Invoke-Safe 'Удалённый рабочий стол' {
    $rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
    Add-Line ("  Удалённый стол (RDP): {0}" -f ($(if ($rdp -eq 0) { 'ВКЛЮЧЁН' } else { 'выключен' })))
    if ($rdp -eq 0) { Add-Finding 3 'Включён удалённый рабочий стол (RDP) - убедитесь, что он не открыт в интернет, и что у учётной записи сложный пароль.' }
}
Invoke-Safe 'Изоляция ядра' {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    $hvci = $dg.SecurityServicesRunning -contains 2
    Add-Line ("  Целостность памяти  : {0}" -f ($(if ($hvci) { 'включена' } else { 'выключена' })))
}
if ($isAdmin) {
    Invoke-Safe 'Secure Boot' {
        $sbState = Confirm-SecureBootUEFI -ErrorAction Stop
        Add-Line ("  Secure Boot         : {0}" -f $sbState)
        if (-not $sbState) { Add-Finding 2 'Secure Boot выключен в UEFI.' }
    }
    Invoke-Safe 'TPM' {
        $tpm = Get-Tpm
        Add-Line ("  TPM                 : присутствует={0}, готов={1}" -f $tpm.TpmPresent, $tpm.TpmReady)
    }
    Invoke-Safe 'BitLocker' {
        $bl = Get-BitLockerVolume -ErrorAction Stop
        Add-Line '  BitLocker:'
        Add-Table ($bl | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage)
        $sysVol = $bl | Where-Object { $_.MountPoint -eq $env:SystemDrive }
        if ($sysVol.ProtectionStatus -ne 'On') {
            Add-Finding 1 'Системный диск НЕ зашифрован BitLocker. При краже ноутбука/диска данные пациентов (фото, видео, выписки) будут доступны. Включите BitLocker (Windows 11 Pro) и сохраните ключ восстановления.'
        }
        foreach ($v in ($bl | Where-Object { $_.MountPoint -ne $env:SystemDrive -and $_.ProtectionStatus -ne 'On' })) {
            Add-Finding 3 "Диск $($v.MountPoint) не зашифрован - если на нём хранятся медицинские материалы, включите BitLocker."
        }
    }
    Invoke-Safe 'SMB1' {
        $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
        Add-Line ("  SMB1 (устаревший)   : {0}" -f $smb1)
        if ($smb1) { Add-Finding 2 'Включён устаревший протокол SMB1 (уязвим, WannaCry) - отключите.' }
    }
}
else {
    Add-Line '  (BitLocker, TPM, Secure Boot, SMB1 - требуются права администратора)'
}

# ---------------------------------------------------------------------------
Add-Section '5. ОБНОВЛЕНИЯ WINDOWS'
Invoke-Safe 'Обновления' {
    $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending
    Add-Table ($hf | Select-Object -First 8 HotFixID, Description, @{ n = 'Установлено'; e = { Format-Date $_.InstalledOn } })
    $lastAge = Get-AgeDays ($hf | Select-Object -First 1).InstalledOn
    if ($lastAge -gt 45) { Add-Finding 2 "Последнее обновление Windows установлено $lastAge дней назад - проверьте Центр обновления." }
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    Add-Line ("  Ожидает перезагрузки: {0}" -f $pending)
    if ($pending) { Add-Finding 2 'Обновления ожидают перезагрузки.' }
    $pause = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    if ($pause) {
        Add-Line ("  Обновления приостановлены до: {0}" -f $pause)
        try { if ([datetime]$pause -gt (Get-Date)) { Add-Finding 2 "Обновления Windows приостановлены до $pause." } } catch { }
    }
}

# ---------------------------------------------------------------------------
Add-Section '6. ДРАЙВЕРЫ И УСТРОЙСТВА'
Invoke-Safe 'BIOS' {
    $bios = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard
    Add-Line ("  Материнская плата : {0} {1}" -f $bb.Manufacturer, $bb.Product)
    Add-Line ("  BIOS/UEFI         : {0} от {1}" -f $bios.SMBIOSBIOSVersion, (Format-Date $bios.ReleaseDate))
    if ((Get-AgeDays $bios.ReleaseDate) -gt 730) { Add-Finding 3 'BIOS/UEFI старше 2 лет - проверьте обновление на сайте производителя ПК/платы (исправления безопасности и стабильности).' }
}
Invoke-Safe 'Проблемные устройства' {
    $bad = Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
    if ($bad) {
        Add-Line '  Устройства с ошибками (Диспетчер устройств):'
        Add-Table ($bad | Select-Object Name, @{ n = 'Код ошибки'; e = { $_.ConfigManagerErrorCode } }, PNPClass)
        foreach ($b in $bad) {
            $n = if ($b.Name) { $b.Name } else { $b.DeviceID }
            Add-Finding 2 "Устройство с ошибкой (код $($b.ConfigManagerErrorCode)): $n"
        }
    }
    else { Add-Line '  Устройств с ошибками нет.' }
}
Invoke-Safe 'Драйверы' {
    $drivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName } |
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion,
            @{ n = 'DriverDate'; e = { Format-Date $_.DriverDate } }
    $drivers | Sort-Object DeviceClass, DeviceName | Export-Csv (Join-Path $outDir 'drivers.csv') -NoTypeInformation -Encoding UTF8
    $keyClasses = 'DISPLAY', 'NET', 'MEDIA', 'CAMERA', 'IMAGE', 'SCSIADAPTER', 'HDC', 'BLUETOOTH', 'USB'
    $key = $drivers | Where-Object { $keyClasses -contains $_.DeviceClass -and $_.Manufacturer -notmatch '^(Microsoft|\(Стандартн|\(Standard|Generic)' } |
        Sort-Object DeviceClass, DeviceName -Unique
    Add-Line '  Ключевые драйверы (видео, сеть, звук, камеры, накопители):'
    Add-Table $key
    $old = @($key | Where-Object { (Get-AgeDays $_.DriverDate) -gt 1095 -and $_.DeviceClass -in 'DISPLAY', 'NET', 'MEDIA', 'CAMERA' })
    if ($old.Count) { Add-Finding 3 ("Драйверы старше 3 лет: {0} - проверьте обновления на сайте производителя ПК." -f (($old.DeviceName | Select-Object -Unique) -join '; ')) }
    Add-Line "  Полный список: drivers.csv ($(@($drivers).Count) шт.)"
}

# ---------------------------------------------------------------------------
Add-Section '7. УСТАНОВЛЕННЫЕ ПРОГРАММЫ'
$programs = @()
Invoke-Safe 'Программы' {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $script:programs = foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
            ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.DisplayName.Trim()
                    Version     = $_.DisplayVersion
                    Publisher   = $_.Publisher
                    InstallDate = $_.InstallDate
                }
            }
    }
    $script:programs = @($script:programs | Sort-Object Name, Version -Unique)
    $script:programs | Export-Csv (Join-Path $outDir 'programs.csv') -NoTypeInformation -Encoding UTF8
    Add-Line "  Всего классических программ: $($script:programs.Count) (полный список: programs.csv)"
}
$appx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework } | Select-Object -ExpandProperty Name)
Add-Line "  Приложений из Microsoft Store: $($appx.Count)"
$allNames = @($programs | ForEach-Object { if ($_.Version) { "$($_.Name) [$($_.Version)]" } else { $_.Name } }) + $appx

$categories = [ordered]@{
    'Видеомонтаж и запись'          = 'DaVinci|Premiere|After Effects|OBS Studio|Shotcut|Kdenlive|HandBrake|PowerDirector|Camtasia|VEGAS|Filmora|CapCut|Clipchamp|Movavi'
    'Кодеки и плееры'               = 'VLC|K-Lite|MPC-HC|PotPlayer|HEVCVideoExtension|AV1VideoExtension|VP9VideoExtensions|HEIFImageExtension'
    'Графика и фото'                = 'Photoshop|Lightroom|GIMP|Affinity|Krita|Inkscape|Illustrator|Canva|paint\.net|IrfanView|XnView|FastStone'
    'DICOM / мед. визуализация'     = 'RadiAnt|MicroDicom|Weasis|3D Slicer|Slicer|InVesalius|DICOM|Sante|Horos|Onis'
    'Офис и PDF'                    = 'Microsoft 365|Microsoft Office|LibreOffice|ONLYOFFICE|WPS Office|Acrobat|Foxit|Sumatra|PDF-XChange|PDF24'
    'Вёрстка и электронные книги'   = 'Kindle|Calibre|Sigil|Scribus|Pandoc|MiKTeX|TeX Live|Vellum|Atticus|InDesign|Affinity Publisher'
    'Библиография'                  = 'Zotero|Mendeley|EndNote|JabRef|Citavi'
    'Статистика и наука'            = 'SPSS|Statistica|RStudio|R for Windows|GraphPad|Prism|MedCalc|Stata|JASP|jamovi|Anaconda|MATLAB|OriginPro'
    'Разработка и инфраструктура'   = 'Docker|^Git|Visual Studio Code|Node\.js|Python 3|PowerShell 7|WindowsTerminal|WinSCP|FileZilla|PuTTY'
    'Браузеры'                      = 'Google Chrome|Mozilla Firefox|Microsoft Edge$|Opera|Brave|Vivaldi'
    'Связь'                         = 'Telegram|Zoom|Teams|Skype|Viber|WhatsApp|Signal|Discord'
    'Резервное копирование/синхр.'  = 'Acronis|Macrium|Veeam|Backblaze|Syncthing|Cobian|EaseUS Todo|AOMEI|Paragon|Duplicati|FreeFileSync|Google Drive|Dropbox|pCloud|MEGAsync|IDrive'
    'Удалённый доступ'              = 'AnyDesk|TeamViewer|RustDesk|Chrome Remote|Parsec|UltraVNC|TightVNC|RealVNC|Radmin'
    'Оптимизаторы (часто вредят)'   = 'CCleaner|Advanced SystemCare|IObit|Driver Booster|Wise Care|Glary|Auslogics|Reimage|Restoro|AVG TuneUp|Avast Cleanup|Driver Easy|DriverPack|Norton Utilities|Razer Cortex'
}
$catResult = @{}
foreach ($cat in $categories.Keys) {
    $hits = @($allNames | Where-Object { $_ -match $categories[$cat] } | Select-Object -Unique)
    $catResult[$cat] = $hits
    $shown = if ($hits.Count) { ($hits | Select-Object -First 10) -join '; ' } else { '-- не обнаружено --' }
    Add-Line ''
    Add-Line "  [$cat]"
    Add-Line "    $shown"
}

if ($catResult['Оптимизаторы (часто вредят)'].Count) {
    Add-Finding 2 ("Найдены «оптимизаторы»/драйвер-паки: {0}. Они часто ставят неподходящие драйверы и рекламное ПО - рекомендуется удалить." -f ($catResult['Оптимизаторы (часто вредят)'] -join '; '))
}
if (-not $catResult['Резервное копирование/синхр.'].Count) {
    Add-Finding 1 'Не найдено ПО резервного копирования (кроме OneDrive). Видео операций, статьи и рукописи книг должны храниться по правилу 3-2-1.'
}
if ($catResult['Удалённый доступ'].Count) {
    Add-Finding 3 ("Установлен удалённый доступ: {0} - включите двухфакторную защиту и отключите неконтролируемый доступ, если он не нужен." -f ($catResult['Удалённый доступ'] -join '; '))
}
if (-not $catResult['Библиография'].Count) {
    Add-Finding 3 'Нет менеджера литературы - для статей и книг рекомендуется бесплатный Zotero (плагин для Word/LibreOffice, стили ГОСТ/Vancouver).'
}
if (-not $catResult['DICOM / мед. визуализация'].Count) {
    Add-Finding 3 'Не найден DICOM-просмотрщик - для КТ/МРТ пациентов и иллюстраций к статьям подойдёт RadiAnt или MicroDicom.'
}
if (-not ($appx -match 'HEVCVideoExtension')) {
    Add-Finding 3 'Нет расширения HEVC (H.265) - видео с современных камер/смартфонов может не открываться в стандартных приложениях.'
}
$eol = @($allNames | Where-Object { $_ -match 'Microsoft Office .*(2007|2010|2013|2016|2019)|Python 2\.|Adobe Flash|Java.* [67] Update' })
if ($eol.Count) {
    Add-Finding 2 ("Устаревшее ПО без обновлений безопасности: {0}" -f ($eol -join '; '))
}

# ---------------------------------------------------------------------------
Add-Section '8. АВТОЗАГРУЗКА, ПЛАНИРОВЩИК, ФОНОВЫЕ ПРОЦЕССЫ'
Invoke-Safe 'Автозагрузка' {
    $startup = Get-CimInstance Win32_StartupCommand | Select-Object Name, Location
    Add-Line "  Программ в автозагрузке: $(@($startup).Count)"
    Add-Table $startup
    if (@($startup).Count -gt 15) { Add-Finding 3 "В автозагрузке $(@($startup).Count) программ - отключите лишние (Диспетчер задач > Автозагрузка)." }
}
Invoke-Safe 'Планировщик задач' {
    $okCodes = 0, 267008, 267009, 267011
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' }
    $rows = foreach ($t in $tasks) {
        $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        [pscustomobject]@{
            'Задача'          = ($t.TaskPath + $t.TaskName)
            'Состояние'       = $t.State
            'Последний запуск' = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
            'Результат'       = if ($null -ne $info) { '0x{0:X}' -f $info.LastTaskResult } else { '' }
            'Код'             = $info.LastTaskResult
        }
    }
    Add-Line '  Пользовательские задачи (не Microsoft) - ваши автоматизации:'
    Add-Table ($rows | Select-Object 'Задача', 'Состояние', 'Последний запуск', 'Результат')
    foreach ($r in ($rows | Where-Object { $null -ne $_.'Код' -and $okCodes -notcontains $_.'Код' })) {
        Add-Finding 2 ("Задача планировщика '{0}' завершилась с ошибкой {1}." -f $r.'Задача', $r.'Результат')
    }
}
Invoke-Safe 'Процессы' {
    Add-Line '  Топ-15 процессов по памяти:'
    Add-Table (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name,
        @{ n = 'Память МБ'; e = { [math]::Round($_.WorkingSet64 / 1MB) } },
        @{ n = 'CPU с'; e = { [math]::Round($_.CPU) } })
}
Invoke-Safe 'Службы' {
    $stopped = Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
        Select-Object Name, DisplayName
    Add-Line '  Автоматические службы, которые сейчас не запущены (многие это делают штатно):'
    Add-Table $stopped
}

# ---------------------------------------------------------------------------
Add-Section '9. ПРОИЗВОДИТЕЛЬНОСТЬ И ЭЛЕКТРОПИТАНИЕ'
Invoke-Safe 'Электропитание' {
    Add-Line ("  Схема питания: {0}" -f ((powercfg /getactivescheme) -join ' '))
    $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    Add-Line ("  Быстрый запуск: {0}" -f ($(if ($hib -eq 1) { 'включён' } else { 'выключен' })))
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) { Add-Line ("  Батарея: {0}, заряд {1}%" -f $battery.Name, $battery.EstimatedChargeRemaining) }
}
Invoke-Safe 'Файл подкачки' {
    Add-Line ("  Файл подкачки автоматически: {0}" -f $cs.AutomaticManagedPagefile)
    Add-Table (Get-CimInstance Win32_PageFileUsage | Select-Object Name,
        @{ n = 'Размер МБ'; e = { $_.AllocatedBaseSize } },
        @{ n = 'Пик МБ'; e = { $_.PeakUsage } })
}
Invoke-Safe 'Индекс стабильности' {
    $rel = Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if ($rel) {
        Add-Line ("  Индекс стабильности Windows: {0:N1} из 10" -f $rel.SystemStabilityIndex)
        if ($rel.SystemStabilityIndex -lt 5) { Add-Finding 2 ("Низкий индекс стабильности ({0:N1}/10) - см. «Монитор стабильности системы» (perfmon /rel)." -f $rel.SystemStabilityIndex) }
    }
}

# ---------------------------------------------------------------------------
Add-Section '10. DOCKER, WSL, ИНСТРУМЕНТЫ РАЗРАБОТКИ'
Invoke-Safe 'Виртуализация' {
    Add-Line ("  Гипервизор активен: {0}" -f $cs.HypervisorPresent)
    if ($isAdmin) {
        $feat = Get-WindowsOptionalFeature -Online -ErrorAction Stop |
            Where-Object { $_.FeatureName -in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All', 'Containers' }
        Add-Table ($feat | Select-Object FeatureName, State)
    }
}
$wslStatus = Invoke-External 'wsl.exe' @('--status')
if ($null -ne $wslStatus) {
    Add-Line '  wsl --status:'
    Add-Line ($wslStatus -replace '(?m)^', '    ')
    Add-Line '  wsl -l -v:'
    Add-Line ((Invoke-External 'wsl.exe' @('-l', '-v')) -replace '(?m)^', '    ')
}
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wslConfig) {
    Add-Line '  .wslconfig:'
    Add-Line ((Get-Content $wslConfig -Raw) -replace '(?m)^', '    ')
}
else {
    Add-Line '  .wslconfig: отсутствует (WSL2/Docker могут занимать до 50% ОЗУ)'
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Add-Finding 3 'Нет файла %USERPROFILE%\.wslconfig - Docker/WSL2 может забирать до половины ОЗУ. Ограничьте память (например memory=8GB).'
    }
}
$dockerVer = Invoke-External 'docker' @('version', '--format', 'Client {{.Client.Version}} / Server {{.Server.Version}}')
if ($null -ne $dockerVer) {
    Add-Line "  Docker: $dockerVer"
    $dockerInfo = Invoke-External 'docker' @('system', 'df')
    Add-Line '  docker system df:'
    Add-Line ($dockerInfo -replace '(?m)^', '    ')
    $dockerPs = Invoke-External 'docker' @('ps', '-a', '--format', '{{.Names}}  |  {{.Image}}  |  {{.Status}}')
    Add-Line '  Контейнеры:'
    Add-Line ($dockerPs -replace '(?m)^', '    ')
    if ($dockerPs -match 'Exited \((?!0\))') { Add-Finding 2 'Есть Docker-контейнеры, завершившиеся с ошибкой - см. раздел 10 отчёта.' }
}
else { Add-Line '  Docker: не установлен' }
foreach ($tool in @(
        @{ Exe = 'git'; Args = @('--version') },
        @{ Exe = 'pwsh'; Args = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') },
        @{ Exe = 'python'; Args = @('--version') },
        @{ Exe = 'node'; Args = @('--version') },
        @{ Exe = 'code'; Args = @('--version') },
        @{ Exe = 'winget'; Args = @('--version') })) {
    if (Get-Command $tool.Exe -ErrorAction SilentlyContinue) {
        $v = (& $tool.Exe @($tool.Args) 2>&1 | Select-Object -First 1)
        Add-Line ("  {0,-8}: {1}" -f $tool.Exe, $v)
    }
    else { Add-Line ("  {0,-8}: не найден" -f $tool.Exe) }
}
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Add-Finding 3 'Не установлен PowerShell 7 - для скриптов автоматизации он быстрее и удобнее встроенного 5.1 (winget install Microsoft.PowerShell).'
}

# ---------------------------------------------------------------------------
Add-Section '11. ЯЗЫКИ, РАСКЛАДКИ, РЕГИОН (мультиязычные публикации)'
Invoke-Safe 'Языки' {
    $langs = Get-WinUserLanguageList
    Add-Table ($langs | Select-Object LanguageTag, LocalizedName)
    Add-Line ("  Язык программ без Юникода: {0}" -f (Get-WinSystemLocale).Name)
    $acp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP
    Add-Line ("  Кодовая страница ANSI: {0}{1}" -f $acp, $(if ($acp -eq '65001') { ' (UTF-8 бета)' } else { '' }))
    Add-Line ("  Формат дат/чисел: {0};  Часовой пояс: {1}" -f (Get-Culture).Name, (Get-TimeZone).Id)
    $tags = $langs.LanguageTag
    $missing = @('uk', 'ru', 'en', 'bg' | Where-Object { $l = $_; -not ($tags | Where-Object { $_ -like "$l*" }) })
    if ($missing.Count) { Add-Finding 3 ("Не добавлены раскладки/проверка орфографии для языков сайта: {0} (Параметры > Время и язык > Язык и регион)." -f ($missing -join ', ')) }
}

# ---------------------------------------------------------------------------
Add-Section '12. СЕТЬ'
Invoke-Safe 'Сеть' {
    $up = Get-NetAdapter | Where-Object Status -eq 'Up'
    Add-Table ($up | Select-Object Name, InterfaceDescription, LinkSpeed, MediaType)
    Add-Line '  DNS-серверы:'
    Add-Table (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } |
        Select-Object InterfaceAlias, @{ n = 'DNS'; e = { $_.ServerAddresses -join ', ' } })
    if (-not ($up | Where-Object { $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|TAP|WSL' })) {
        Add-Finding 3 'Нет активного проводного подключения - для загрузки больших видео на YouTube кабель надёжнее и быстрее Wi-Fi.'
    }
}

# ---------------------------------------------------------------------------
Add-Section "13. ЖУРНАЛ СОБЫТИЙ (последние $EventDays дн.)"
$since = (Get-Date).AddDays(-$EventDays)
Invoke-Safe 'Системный журнал' {
    $sysErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 3000 -ErrorAction SilentlyContinue)
    Add-Line "  Ошибок/критических событий в журнале System: $($sysErr.Count)"
    Add-Table ($sysErr | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 15 Count, Name)
    $kp = @($sysErr | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 }).Count
    if ($kp) { Add-Finding 2 "Внезапные выключения/зависания (Kernel-Power 41): $kp раз - проверьте питание, перегрев, драйверы." }
    $whea = @($sysErr | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' }).Count
    if ($whea) { Add-Finding 1 "Аппаратные ошибки WHEA: $whea - возможны проблемы с процессором, памятью или шиной PCIe." }
    $diskErr = @($sysErr | Where-Object { $_.ProviderName -in 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci' }).Count
    if ($diskErr) { Add-Finding 1 "Ошибки диска/файловой системы: $diskErr - сделайте резервную копию и проверьте диск (chkdsk)." }
    $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since } -ErrorAction SilentlyContinue).Count
    if ($tdr) { Add-Finding 2 "Сбои видеодрайвера (Display 4101): $tdr раз - переустановите драйвер GPU начисто." }
}
Invoke-Safe 'Сбои программ' {
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue)
    Add-Line "  Аварийных завершений программ: $($crashes.Count)"
    if ($crashes.Count) {
        Add-Table ($crashes | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending |
            Select-Object -First 10 Count, @{ n = 'Программа'; e = { $_.Name } })
    }
}

# ---------------------------------------------------------------------------
Add-Section '14. РЕЗЕРВНОЕ КОПИРОВАНИЕ И ВОССТАНОВЛЕНИЕ'
Invoke-Safe 'Папки пользователя' {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $desk = [Environment]::GetFolderPath('Desktop')
    Add-Line "  Документы : $docs"
    Add-Line "  Рабочий стол: $desk"
    if ($docs -match 'OneDrive') { Add-Line '  -> Документы синхронизируются с OneDrive (это синхронизация, а не полноценный бэкап).' }
}
if ($isAdmin) {
    Invoke-Safe 'Точки восстановления' {
        $rp = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
        if ($rp.Count) {
            $last = $rp | Sort-Object SequenceNumber | Select-Object -Last 1
            Add-Line ("  Точек восстановления: {0}, последняя: {1} ({2})" -f $rp.Count,
                (Format-Date ([Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime))), $last.Description)
        }
        else {
            Add-Line '  Точек восстановления нет.'
            Add-Finding 2 "Защита системы (точки восстановления) выключена - включите для диска ${env:SystemDrive} (sysdm.cpl > Защита системы)."
        }
    }
}

# ---------------------------------------------------------------------------
# Итог: сводка находок в начале отчёта
$levelNames = @{ 1 = 'КРИТИЧНО'; 2 = 'ВАЖНО'; 3 = 'СОВЕТ' }
$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine('АУДИТ WINDOWS - РАБОЧАЯ СТАНЦИЯ ХИРУРГА И АВТОРА')
[void]$summary.AppendLine(('=' * 78))
[void]$summary.AppendLine(("Найдено: критично {0}, важно {1}, советов {2}" -f
    @($findings | Where-Object Level -eq 1).Count, @($findings | Where-Object Level -eq 2).Count, @($findings | Where-Object Level -eq 3).Count))
[void]$summary.AppendLine('')
foreach ($f in ($findings | Sort-Object Level)) {
    [void]$summary.AppendLine(("[{0}] {1}" -f $levelNames[$f.Level], $f.Text))
}
if (-not $findings.Count) { [void]$summary.AppendLine('Проблем не обнаружено.') }

$text = $summary.ToString() + $sb.ToString()
if (-not $NoAnonymize) {
    foreach ($pair in @(@($env:COMPUTERNAME, '<ПК>'), @($env:USERNAME, '<ПОЛЬЗОВАТЕЛЬ>'))) {
        if ($pair[0] -and $pair[0].Length -ge 3) { $text = $text -replace [regex]::Escape($pair[0]), $pair[1] }
    }
}
$text | Out-File -FilePath $reportPath -Encoding utf8

$zip = "$outDir.zip"
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip -Force

Write-Host ''
Write-Host 'Готово!' -ForegroundColor Green
Write-Host "  Отчёт : $reportPath"
Write-Host "  Архив : $zip"
Write-Host ''
Write-Host 'Сводка:' -ForegroundColor Green
foreach ($f in ($findings | Sort-Object Level)) {
    $color = switch ($f.Level) { 1 { 'Red' } 2 { 'Yellow' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}" -f $levelNames[$f.Level], $f.Text) -ForegroundColor $color
}
