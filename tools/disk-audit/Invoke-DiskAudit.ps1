<#
.SYNOPSIS
    Аудит дисков Windows: здоровье, производительность, занятое место, структура, дубликаты.

.DESCRIPTION
    Скрипт ТОЛЬКО ЧИТАЕТ данные — ничего не удаляет и не меняет.
    Результат сохраняется в папку на Рабочем столе:
        report.html   — наглядный отчёт (открыть в браузере)
        report.json   — полные данные (отправить для анализа)
        summary.txt   — краткая сводка и найденные проблемы

    Для полных данных (SMART, температура, износ SSD, BitLocker, теневые копии)
    запускайте PowerShell от имени администратора.

.PARAMETER Quick
    Не сканировать файлы целиком (только здоровье дисков, тома, системные папки). 1-2 минуты.

.PARAMETER Benchmark
    Замер скорости дисков через winsat (нужны права администратора, ~1-2 мин на диск).

.PARAMETER AnalyzeFragmentation
    Анализ фрагментации HDD (только анализ, без дефрагментации; нужны права администратора).

.PARAMETER Drives
    Ограничить полное сканирование буквами дисков, например: -Drives C,D

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-DiskAudit.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-DiskAudit.ps1 -Benchmark -Drives C,D
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$Quick,
    [switch]$Benchmark,
    [switch]$AnalyzeFragmentation,
    [string[]]$Drives,
    [int]$TopFiles = 50,
    [int]$BigFileMB = 200,
    [int]$DupMinMB = 50,
    [int]$OldYears = 2
)

$ErrorActionPreference = 'Continue'
$Sep = [IO.Path]::DirectorySeparatorChar

# ---------------------------------------------------------------- helpers

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return ('{0:N0} B' -f $Bytes)
}

function To-GB([double]$Bytes) { [math]::Round($Bytes / 1GB, 2) }

function HtmlEnc($Value) {
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

$script:Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param(
        [ValidateSet('CRITICAL', 'WARNING', 'INFO', 'ORDER')][string]$Level,
        [string]$Area, [string]$Text, [string]$Action
    )
    $script:Findings.Add([pscustomobject][ordered]@{ Level = $Level; Area = $Area; Text = $Text; Action = $Action })
}

function Write-Step([string]$Text) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Text) -ForegroundColor Cyan }

function Invoke-Safe([scriptblock]$Block, $Default = $null) {
    try { & $Block } catch { $Default }
}

# 0x1000 Offline, 0x40000 RecallOnOpen, 0x400000 RecallOnDataAccess — облачные файлы (OneDrive), которых нет на диске
$script:CloudMask = 0x441000
$script:ReparseFlag = [int][IO.FileAttributes]::ReparsePoint

function Test-SkipDir([IO.DirectoryInfo]$Dir) {
    # Пропускаем junction/symlink (иначе двойной учёт и циклы), но не облачные папки OneDrive
    if (([int]$Dir.Attributes -band $script:ReparseFlag) -eq 0) { return $false }
    $lt = Invoke-Safe { $Dir.LinkType }
    return ($lt -eq 'Junction' -or $lt -eq 'SymbolicLink')
}

# Размер папки (или файла) без учёта ссылок и облачных заглушек
function Measure-Tree([string]$Path) {
    $r = [ordered]@{ Path = $Path; Exists = $false; Bytes = [long]0; Files = 0; Errors = 0; Size = '' }
    if (-not (Test-Path -LiteralPath $Path)) { $r.Size = '-'; return [pscustomobject]$r }
    $r.Exists = $true
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer) {
        $r.Bytes = [long]$item.Length; $r.Files = 1; $r.Size = Format-Size $r.Bytes
        return [pscustomobject]$r
    }
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object IO.DirectoryInfo $Path))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $entries = $d.GetFileSystemInfos() } catch { $r.Errors++; continue }
        foreach ($e in $entries) {
            if ($e -is [IO.DirectoryInfo]) {
                if (-not (Test-SkipDir $e)) { $stack.Push($e) }
            } elseif (([int]$e.Attributes -band $script:CloudMask) -eq 0) {
                $r.Bytes += $e.Length; $r.Files++
            }
        }
    }
    $r.Size = Format-Size $r.Bytes
    [pscustomobject]$r
}

function Add-ToDict($Dict, [string]$Key, [long]$Value) {
    if ($Dict.ContainsKey($Key)) { $Dict[$Key] += $Value } else { $Dict[$Key] = $Value }
}

function Get-TopFromDict($Dict, [int]$Top, [string]$KeyName = 'Path') {
    $Dict.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
        [pscustomobject][ordered]@{ $KeyName = $_.Key; Bytes = $_.Value; GB = To-GB $_.Value; Size = Format-Size $_.Value }
    }
}

# Полный обход диска за один проход
function Invoke-DriveScan {
    param([string]$Root, [int]$TopFiles, [long]$BigBytes, [long]$DupBytes, [datetime]$OldCutoff)

    if (-not $Root.EndsWith([string]$Sep)) { $Root += $Sep }
    $rootLen = $Root.Length
    $lvl1 = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    $lvl2 = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    $lvl3 = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    $ext = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    $extCount = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
    $big = New-Object System.Collections.Generic.List[object]
    $dupCand = New-Object System.Collections.Generic.List[object]
    [long]$total = 0; [long]$files = 0; [long]$dirs = 0; [long]$errors = 0
    [long]$oldBytes = 0; [long]$cloudBytes = 0; [long]$cloudFiles = 0; [long]$emptyFiles = 0
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastProgress = 0

    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object IO.DirectoryInfo $Root))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop(); $dirs++
        try { $entries = $d.GetFileSystemInfos() } catch { $errors++; continue }
        [long]$dirBytes = 0
        foreach ($e in $entries) {
            if ($e -is [IO.DirectoryInfo]) {
                if (-not (Test-SkipDir $e)) { $stack.Push($e) }
                continue
            }
            $attr = [int]$e.Attributes
            $len = [long]$e.Length
            if (($attr -band $script:CloudMask) -ne 0) { $cloudBytes += $len; $cloudFiles++; continue }
            if (($attr -band $script:ReparseFlag) -ne 0 -and $len -eq 0) { continue }
            $files++; $dirBytes += $len
            if ($len -eq 0) { $emptyFiles++ }
            $x = $e.Extension; if (-not $x) { $x = '(без расширения)' }
            if ($ext.ContainsKey($x)) { $ext[$x] += $len; $extCount[$x] += 1 } else { $ext[$x] = $len; $extCount[$x] = 1 }
            if ($e.LastWriteTime -lt $OldCutoff) { $oldBytes += $len }
            if ($len -ge $BigBytes) {
                $big.Add([pscustomobject][ordered]@{ Path = $e.FullName; Bytes = $len; Size = Format-Size $len; Modified = $e.LastWriteTime.ToString('yyyy-MM-dd') })
            }
            if ($len -ge $DupBytes) { $dupCand.Add([pscustomobject]@{ Path = $e.FullName; Bytes = $len }) }
        }
        $total += $dirBytes
        if ($dirBytes -gt 0) {
            $rel = if ($d.FullName.Length -gt $rootLen) { $d.FullName.Substring($rootLen) } else { '' }
            if ($rel -eq '') {
                Add-ToDict $lvl1 '(файлы в корне)' $dirBytes
            } else {
                $seg = $rel.Split([char[]]@($Sep), [StringSplitOptions]::RemoveEmptyEntries)
                Add-ToDict $lvl1 ($Root + $seg[0]) $dirBytes
                if ($seg.Count -ge 2) { Add-ToDict $lvl2 ($Root + $seg[0] + $Sep + $seg[1]) $dirBytes }
                if ($seg.Count -ge 3) { Add-ToDict $lvl3 ($Root + $seg[0] + $Sep + $seg[1] + $Sep + $seg[2]) $dirBytes }
            }
        }
        if ($sw.ElapsedMilliseconds - $lastProgress -gt 1500) {
            $lastProgress = $sw.ElapsedMilliseconds
            Write-Progress -Activity "Сканирование $Root" -Status ("{0:N0} файлов, {1}" -f $files, (Format-Size $total)) -CurrentOperation $d.FullName
        }
    }
    Write-Progress -Activity "Сканирование $Root" -Completed

    $extTop = $ext.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject][ordered]@{ Extension = $_.Key; Files = $extCount[$_.Key]; Bytes = $_.Value; GB = To-GB $_.Value; Size = Format-Size $_.Value }
    }
    [pscustomobject][ordered]@{
        Root            = $Root
        ScannedBytes    = $total
        ScannedSize     = Format-Size $total
        Files           = $files
        Directories     = $dirs
        EmptyFiles      = $emptyFiles
        AccessDenied    = $errors
        OldBytes        = $oldBytes
        OldSize         = Format-Size $oldBytes
        CloudOnlyFiles  = $cloudFiles
        CloudOnlySize   = Format-Size $cloudBytes
        Seconds         = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TopLevel        = @(Get-TopFromDict $lvl1 30)
        TopLevel2       = @(Get-TopFromDict $lvl2 30)
        TopLevel3       = @(Get-TopFromDict $lvl3 40)
        Extensions      = @($extTop)
        BigFiles        = @($big | Sort-Object Bytes -Descending | Select-Object -First $TopFiles)
        BigFilesTotal   = [long](($big | Measure-Object Bytes -Sum).Sum)
        DupCandidates   = $dupCand
    }
}

function Get-PartialHash([string]$Path, [long]$Length) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $chunk = 1MB
        $buf = New-Object byte[] $chunk
        $offsets = @(0)
        if ($Length -gt 3 * $chunk) { $offsets += [long]($Length / 2); $offsets += ($Length - $chunk) }
        foreach ($o in $offsets) {
            [void]$fs.Seek($o, [IO.SeekOrigin]::Begin)
            $n = $fs.Read($buf, 0, $chunk)
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '') + ':' + $Length
    } catch {
        return $null
    } finally {
        if ($fs) { $fs.Dispose() }
        $sha.Dispose()
    }
}

function Find-Duplicates($Candidates, [int]$MaxGroups = 400) {
    $groups = @($Candidates | Group-Object Bytes | Where-Object Count -gt 1 | Sort-Object { [long]$_.Name } -Descending | Select-Object -First $MaxGroups)
    $result = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($g in $groups) {
        $i++
        Write-Progress -Activity 'Поиск дубликатов' -Status "$i / $($groups.Count)" -PercentComplete ([int](100 * $i / [math]::Max(1, $groups.Count)))
        $byHash = $g.Group | ForEach-Object {
            [pscustomobject]@{ Path = $_.Path; Bytes = $_.Bytes; Hash = (Get-PartialHash $_.Path $_.Bytes) }
        } | Where-Object Hash | Group-Object Hash | Where-Object Count -gt 1
        foreach ($h in $byHash) {
            $size = [long]$h.Group[0].Bytes
            $result.Add([pscustomobject][ordered]@{
                Copies      = $h.Count
                FileSize    = Format-Size $size
                WastedBytes = $size * ($h.Count - 1)
                Wasted      = Format-Size ($size * ($h.Count - 1))
                Paths       = @($h.Group | ForEach-Object Path)
            })
        }
    }
    Write-Progress -Activity 'Поиск дубликатов' -Completed
    @($result | Sort-Object WastedBytes -Descending)
}

function ConvertTo-HtmlTableSafe {
    param($Rows, [string[]]$Columns, [string[]]$Headers, [string]$RowClassProperty)
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return '<p class="muted">Нет данных</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tw"><table><thead><tr>')
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $h = if ($Headers -and $Headers.Count -gt $i) { $Headers[$i] } else { $Columns[$i] }
        [void]$sb.Append('<th>' + (HtmlEnc $h) + '</th>')
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        $cls = if ($RowClassProperty) { ' class="' + (HtmlEnc $r.$RowClassProperty).ToLower() + '"' } else { '' }
        [void]$sb.Append("<tr$cls>")
        foreach ($c in $Columns) {
            $v = $r.$c
            if ($v -is [array] -or $v -is [System.Collections.IList]) { $v = ($v | ForEach-Object { HtmlEnc $_ }) -join '<br>' } else { $v = HtmlEnc $v }
            [void]$sb.Append("<td>$v</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    $sb.ToString()
}

# ---------------------------------------------------------------- main

function Invoke-DiskAudit {
    $started = Get-Date
    if (-not $OutputDir) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { $desktop = $PWD.Path }
        $OutputDir = Join-Path $desktop ('DiskAudit_' + $started.ToString('yyyy-MM-dd_HHmm'))
    }
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
    if (-not $isWin) { Write-Warning 'Скрипт рассчитан на Windows.'; return }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning 'Запущено БЕЗ прав администратора: SMART/температура/износ/BitLocker/winsat будут недоступны.'
        Write-Warning 'Для полного отчёта: ПКМ по PowerShell -> "Запуск от имени администратора".'
    }

    $report = [ordered]@{}
    $sysDrive = $env:SystemDrive.TrimEnd(':')

    # --- Система
    Write-Step 'Сведения о системе'
    $os = Invoke-Safe { Get-CimInstance Win32_OperatingSystem }
    $cs = Invoke-Safe { Get-CimInstance Win32_ComputerSystem }
    $report.System = [ordered]@{
        Computer     = $env:COMPUTERNAME
        OS           = if ($os) { "$($os.Caption) $($os.Version) (build $($os.BuildNumber))" } else { '' }
        InstallDate  = if ($os) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' }
        LastBoot     = if ($os) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        RAM_GB       = if ($cs) { To-GB $cs.TotalPhysicalMemory } else { $null }
        Model        = if ($cs) { "$($cs.Manufacturer) $($cs.Model)" } else { '' }
        IsAdmin      = $isAdmin
        ReportDate   = $started.ToString('yyyy-MM-dd HH:mm')
        ScriptParams = "Quick=$Quick Benchmark=$Benchmark Drives=$($Drives -join ',')"
    }

    # --- Физические диски
    Write-Step 'Физические диски и SMART'
    $partitions = @(Invoke-Safe { Get-Partition -ErrorAction Stop } @())
    $disks = @(Invoke-Safe { Get-Disk -ErrorAction Stop } @())
    $physical = New-Object System.Collections.Generic.List[object]
    foreach ($pd in @(Invoke-Safe { Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId } } @())) {
        $num = [int]$pd.DeviceId
        $disk = $disks | Where-Object Number -eq $num | Select-Object -First 1
        $rel = Invoke-Safe { $pd | Get-StorageReliabilityCounter -ErrorAction Stop }
        $letters = @($partitions | Where-Object { $_.DiskNumber -eq $num -and $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter }) -join ','
        $obj = [pscustomobject][ordered]@{
            Number            = $num
            Model             = ($pd.FriendlyName -replace '\s+', ' ').Trim()
            MediaType         = [string]$pd.MediaType
            BusType           = [string]$pd.BusType
            Size              = Format-Size $pd.Size
            SizeBytes         = [long]$pd.Size
            Health            = [string]$pd.HealthStatus
            Status            = ($pd.OperationalStatus -join ',')
            PartitionStyle    = if ($disk) { [string]$disk.PartitionStyle } else { '' }
            IsBoot            = if ($disk) { [bool]$disk.IsBoot } else { $null }
            Letters           = $letters
            Firmware          = $pd.FirmwareVersion
            TemperatureC      = if ($rel) { $rel.Temperature } else { $null }
            TemperatureMaxC   = if ($rel) { $rel.TemperatureMax } else { $null }
            WearPercent       = if ($rel) { $rel.Wear } else { $null }
            PowerOnHours      = if ($rel) { $rel.PowerOnHours } else { $null }
            StartStopCycles   = if ($rel) { $rel.StartStopCycleCount } else { $null }
            ReadErrorsTotal   = if ($rel) { $rel.ReadErrorsTotal } else { $null }
            ReadErrorsUncorr  = if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
            WriteErrorsUncorr = if ($rel) { $rel.WriteErrorsUncorrected } else { $null }
            ReadLatencyMaxMs  = if ($rel) { $rel.ReadLatencyMax } else { $null }
            WriteLatencyMaxMs = if ($rel) { $rel.WriteLatencyMax } else { $null }
        }
        $physical.Add($obj)

        $name = "Диск $num ($($obj.Model), $($obj.MediaType), буквы: $letters)"
        if ($obj.Health -and $obj.Health -ne 'Healthy') {
            Add-Finding CRITICAL $name "Состояние диска: $($obj.Health) / $($obj.Status)" 'Срочно сделайте резервную копию данных с этого диска и планируйте замену.'
        }
        if (($obj.ReadErrorsUncorr -gt 0) -or ($obj.WriteErrorsUncorr -gt 0)) {
            Add-Finding CRITICAL $name "Неисправимые ошибки чтения/записи: $($obj.ReadErrorsUncorr)/$($obj.WriteErrorsUncorr)" 'Резервная копия немедленно; проверить CrystalDiskInfo; готовить замену диска.'
        }
        if ($obj.WearPercent -ge 90) {
            Add-Finding CRITICAL $name "Износ SSD $($obj.WearPercent)%" 'Ресурс почти исчерпан — замена диска.'
        } elseif ($obj.WearPercent -ge 70) {
            Add-Finding WARNING $name "Износ SSD $($obj.WearPercent)%" 'Планируйте замену в ближайший год, держите актуальный бэкап.'
        }
        if ($obj.TemperatureC -ge 60) {
            Add-Finding WARNING $name "Температура $($obj.TemperatureC)°C (макс. $($obj.TemperatureMaxC)°C)" 'Проверьте охлаждение корпуса; для NVMe — радиатор.'
        }
        if ($obj.MediaType -eq 'HDD' -and $obj.PowerOnHours -ge 35000) {
            Add-Finding WARNING $name ("Наработка {0:N0} ч (~{1:N1} лет непрерывно)" -f $obj.PowerOnHours, ($obj.PowerOnHours / 8760)) 'HDD в зоне повышенного риска отказа — бэкап и план замены.'
        }
        if ($obj.IsBoot -and $obj.MediaType -eq 'HDD') {
            Add-Finding WARNING $name 'Windows установлена на HDD' 'Перенос системы на SSD (NVMe/SATA) ускорит работу в 5-10 раз.'
        }
        if ($obj.PartitionStyle -eq 'MBR' -and $obj.SizeBytes -gt 2.2TB) {
            Add-Finding WARNING $name 'Разметка MBR на диске > 2 ТБ — часть объёма недоступна' 'Конвертация в GPT (mbr2gpt для системного диска, бэкап обязателен).'
        }
    }
    $report.PhysicalDisks = $physical

    $predict = @(Invoke-Safe { Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop } @())
    $report.SmartPredictFailure = @($predict | ForEach-Object { [pscustomobject]@{ Instance = $_.InstanceName; PredictFailure = $_.PredictFailure; Reason = $_.Reason } })
    foreach ($p in $predict | Where-Object PredictFailure) {
        Add-Finding CRITICAL 'SMART' "SMART прогнозирует отказ: $($p.InstanceName)" 'Немедленная резервная копия и замена диска.'
    }

    # --- Тома
    Write-Step 'Тома и свободное место'
    $volumes = New-Object System.Collections.Generic.List[object]
    $bitlocker = @(Invoke-Safe { Get-BitLockerVolume -ErrorAction Stop } @())
    foreach ($v in @(Invoke-Safe { Get-Volume -ErrorAction Stop | Where-Object DriveLetter | Sort-Object DriveLetter } @())) {
        $letter = [string]$v.DriveLetter
        $part = $partitions | Where-Object DriveLetter -eq $v.DriveLetter | Select-Object -First 1
        $pd = if ($part) { $physical | Where-Object Number -eq $part.DiskNumber | Select-Object -First 1 } else { $null }
        $bl = $bitlocker | Where-Object { $_.MountPoint -eq "${letter}:" } | Select-Object -First 1
        $freePct = if ($v.Size -gt 0) { [math]::Round(100 * $v.SizeRemaining / $v.Size, 1) } else { $null }
        $obj = [pscustomobject][ordered]@{
            Letter       = $letter
            Label        = $v.FileSystemLabel
            FileSystem   = $v.FileSystem
            DriveType    = [string]$v.DriveType
            Disk         = if ($part) { $part.DiskNumber } else { $null }
            MediaType    = if ($pd) { $pd.MediaType } else { '' }
            Size         = Format-Size $v.Size
            Used         = Format-Size ($v.Size - $v.SizeRemaining)
            Free         = Format-Size $v.SizeRemaining
            FreePercent  = $freePct
            SizeBytes    = [long]$v.Size
            FreeBytes    = [long]$v.SizeRemaining
            Health       = [string]$v.HealthStatus
            BitLocker    = if ($bl) { "$($bl.ProtectionStatus) ($($bl.VolumeStatus))" } else { if ($isAdmin) { 'нет данных' } else { 'нужен админ' } }
        }
        $volumes.Add($obj)

        if ($v.DriveType -ne 'Fixed' -or $v.Size -le 0) { continue }
        $vn = "Том ${letter}: ($($v.FileSystemLabel))"
        if ($obj.Health -and $obj.Health -ne 'Healthy') {
            Add-Finding CRITICAL $vn "Состояние файловой системы: $($obj.Health)" "Запустите от админа: chkdsk ${letter}: /scan"
        }
        $minFreeGB = if ($letter -eq $sysDrive) { 25 } else { 0 }
        if ($freePct -lt 10 -or ($minFreeGB -and $v.SizeRemaining -lt $minFreeGB * 1GB)) {
            Add-Finding CRITICAL $vn "Свободно всего $($obj.Free) ($freePct%)" 'Освободите место (см. разделы «Системные папки», «Крупные файлы», «Дубликаты»). Минимум 15-20% свободно.'
        } elseif ($freePct -lt 20) {
            Add-Finding WARNING $vn "Свободно $($obj.Free) ($freePct%)" 'Для SSD и HDD желательно держать 20%+ свободного места.'
        }
        if ($v.FileSystem -in @('FAT32', 'exFAT')) {
            Add-Finding INFO $vn "Файловая система $($v.FileSystem) на внутреннем диске" 'NTFS надёжнее (журналирование, права, файлы > 4 ГБ).'
        }
        if ($letter -eq $sysDrive -and $isAdmin -and $bl -and [string]$bl.ProtectionStatus -ne 'On') {
            Add-Finding INFO $vn 'Системный диск не зашифрован BitLocker' 'На компьютере с медицинскими/персональными данными пациентов рекомендовано шифрование (BitLocker / Device Encryption). Ключ восстановления — сохранить отдельно!'
        }
    }
    $report.Volumes = $volumes

    # --- TRIM и оптимизация
    Write-Step 'TRIM и плановая оптимизация'
    $trimRaw = Invoke-Safe { (fsutil behavior query DisableDeleteNotify 2>&1) -join ' ' } ''
    $trimNtfs = if ($trimRaw -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)') { [int]$Matches[1] } else { $null }
    $defragTask = Invoke-Safe { Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop }
    $defragInfo = if ($defragTask) { Invoke-Safe { $defragTask | Get-ScheduledTaskInfo -ErrorAction Stop } } else { $null }
    $report.Optimization = [ordered]@{
        TrimRaw            = $trimRaw
        TrimEnabled        = if ($null -eq $trimNtfs) { $null } else { $trimNtfs -eq 0 }
        ScheduledDefrag    = if ($defragTask) { [string]$defragTask.State } else { 'нет данных' }
        DefragLastRun      = if ($defragInfo) { $defragInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        Fragmentation      = @()
    }
    $hasSsd = @($physical | Where-Object MediaType -eq 'SSD').Count -gt 0
    if ($hasSsd -and $trimNtfs -eq 1) {
        Add-Finding WARNING 'TRIM' 'TRIM отключён, а в системе есть SSD' 'От админа: fsutil behavior set DisableDeleteNotify 0'
    }
    if ($defragTask -and [string]$defragTask.State -eq 'Disabled') {
        Add-Finding WARNING 'Оптимизация дисков' 'Плановая оптимизация (defrag/TRIM) отключена' 'Пуск → «Дефрагментация и оптимизация дисков» → Изменить параметры → включить еженедельно.'
    }
    if ($AnalyzeFragmentation -and $isAdmin) {
        foreach ($vol in $volumes | Where-Object { $_.MediaType -eq 'HDD' -and $_.DriveType -eq 'Fixed' }) {
            Write-Step "Анализ фрагментации $($vol.Letter):"
            $out = Invoke-Safe { (Optimize-Volume -DriveLetter $vol.Letter -Analyze -Verbose 4>&1 | ForEach-Object { [string]$_ }) -join "`n" } ''
            $report.Optimization.Fragmentation += [pscustomobject]@{ Letter = $vol.Letter; Output = $out }
        }
    }

    # --- Производительность
    Write-Step 'Счётчики производительности (6 сек)'
    $samples = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 6; $i++) {
        $s = Invoke-Safe { Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop }
        if ($i -gt 0 -and $s) { foreach ($x in $s) { $samples.Add($x) } }
        Start-Sleep -Milliseconds 1000
    }
    $perf = @($samples | Group-Object Name | Where-Object Name -ne '_Total' | ForEach-Object {
        $g = $_.Group
        [pscustomobject][ordered]@{
            Disk             = $_.Name
            BusyPercent      = [math]::Round((($g | Measure-Object PercentDiskTime -Average).Average), 1)
            IdlePercent      = [math]::Round((($g | Measure-Object PercentIdleTime -Average).Average), 1)
            QueueLength      = [math]::Round((($g | Measure-Object CurrentDiskQueueLength -Average).Average), 2)
            AvgReadMs        = [math]::Round(1000 * (($g | Measure-Object AvgDisksecPerRead -Average).Average), 1)
            AvgWriteMs       = [math]::Round(1000 * (($g | Measure-Object AvgDisksecPerWrite -Average).Average), 1)
            ReadMBs          = [math]::Round((($g | Measure-Object DiskReadBytesPersec -Average).Average) / 1MB, 2)
            WriteMBs         = [math]::Round((($g | Measure-Object DiskWriteBytesPersec -Average).Average) / 1MB, 2)
        }
    })
    $report.PerformanceCounters = $perf
    foreach ($p in $perf) {
        if ($p.IdlePercent -lt 20 -and $p.QueueLength -gt 2) {
            Add-Finding WARNING "Диск $($p.Disk)" "Диск перегружен в простое: занят $([math]::Round(100 - $p.IdlePercent))%, очередь $($p.QueueLength)" 'Диспетчер задач → Производительность/Процессы → столбец «Диск»: найти процесс (индексация, антивирус, облачная синхронизация, обновления).'
        }
        if ($p.AvgReadMs -gt 50 -or $p.AvgWriteMs -gt 50) {
            Add-Finding WARNING "Диск $($p.Disk)" "Высокая задержка: чтение $($p.AvgReadMs) мс, запись $($p.AvgWriteMs) мс" 'Норма SSD < 5 мс, HDD < 20 мс. Проверьте SMART (CrystalDiskInfo) и нагрузку.'
        }
    }

    $report.Benchmark = @()
    if ($Benchmark) {
        if (-not $isAdmin) {
            Write-Warning 'Бенчмарк winsat требует прав администратора — пропущен.'
        } else {
            foreach ($vol in $volumes | Where-Object { $_.DriveType -eq 'Fixed' -and (-not $Drives -or $Drives -contains $_.Letter) }) {
                Write-Step "Бенчмарк диска $($vol.Letter): (winsat)"
                $out = Invoke-Safe { & winsat.exe disk -drive $vol.Letter 2>&1 | ForEach-Object { [string]$_ } } @()
                $rows = foreach ($line in $out) {
                    if ($line -match '>\s*Disk\s+(.+?)\s{2,}([\d\.,]+)\s+(MB/s|ms)') {
                        [pscustomobject]@{ Letter = $vol.Letter; Test = $Matches[1].Trim(); Value = $Matches[2]; Unit = $Matches[3] }
                    }
                }
                $report.Benchmark += @($rows)
            }
        }
    }

    # --- Системные папки, кэши, служебные файлы
    Write-Step 'Системные папки и кэши'
    $la = $env:LOCALAPPDATA; $ra = $env:APPDATA; $up = $env:USERPROFILE; $win = $env:windir; $pdata = $env:ProgramData
    $downloadsDir = Invoke-Safe { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}' }
    if (-not $downloadsDir) { $downloadsDir = "$up\Downloads" }
    $known = [ordered]@{
        'Временные файлы пользователя (TEMP)'  = @($env:TEMP)
        'Временные файлы Windows'               = @("$win\Temp")
        'Кэш обновлений Windows'                = @("$win\SoftwareDistribution\Download")
        'Delivery Optimization'                 = @("$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
        'Старая Windows (Windows.old)'          = @("$env:SystemDrive\Windows.old", "$env:SystemDrive\`$Windows.~BT", "$env:SystemDrive\`$Windows.~WS")
        'Отчёты об ошибках (WER)'               = @("$pdata\Microsoft\Windows\WER", "$la\Microsoft\Windows\WER")
        'Дампы памяти'                          = @("$win\MEMORY.DMP", "$win\Minidump", "$la\CrashDumps")
        'Логи Windows'                          = @("$win\Logs")
        'Установщики (Windows\Installer) — НЕ удалять вручную' = @("$win\Installer")
        'Индекс поиска Windows'                 = @("$pdata\Microsoft\Search\Data")
        'Кэш Chrome'                            = @(Invoke-Safe { (Resolve-Path "$la\Google\Chrome\User Data\*\Cache", "$la\Google\Chrome\User Data\*\Code Cache" -ErrorAction SilentlyContinue).Path } @())
        'Кэш Edge'                              = @(Invoke-Safe { (Resolve-Path "$la\Microsoft\Edge\User Data\*\Cache", "$la\Microsoft\Edge\User Data\*\Code Cache" -ErrorAction SilentlyContinue).Path } @())
        'Кэш Firefox'                           = @(Invoke-Safe { (Resolve-Path "$la\Mozilla\Firefox\Profiles\*\cache2" -ErrorAction SilentlyContinue).Path } @())
        'Кэш Telegram Desktop'                  = @("$ra\Telegram Desktop\tdata\user_data", "$ra\Telegram Desktop\tdata\emoji")
        'Кэш npm / yarn'                        = @("$la\npm-cache", "$ra\npm-cache", "$la\Yarn\Cache")
        'Кэш pip / Python'                      = @("$la\pip\Cache", "$up\.cache")
        'Пакеты NuGet'                          = @("$up\.nuget\packages")
        'Docker Desktop (данные)'               = @("$la\Docker", "$pdata\DockerDesktop", "$pdata\Docker")
        'WSL дистрибутивы'                      = @("$la\wsl")
        'Файл гибернации'                       = @("$env:SystemDrive\hiberfil.sys")
        'Файл подкачки'                         = @("$env:SystemDrive\pagefile.sys", "$env:SystemDrive\swapfile.sys")
        'Загрузки (Downloads)'                  = @($downloadsDir)
        'Рабочий стол'                          = @([Environment]::GetFolderPath('Desktop'))
        'Документы'                             = @([Environment]::GetFolderPath('MyDocuments'))
        'Видео'                                 = @([Environment]::GetFolderPath('MyVideos'))
        'Изображения'                           = @([Environment]::GetFolderPath('MyPictures'))
        'OneDrive (локально)'                   = @($env:OneDrive)
    }
    $knownRows = New-Object System.Collections.Generic.List[object]
    $knownMap = @{}
    foreach ($k in $known.Keys) {
        [long]$b = 0; $f = 0; $exists = @()
        foreach ($p in @($known[$k] | Where-Object { $_ })) {
            $m = Measure-Tree $p
            if ($m.Exists) { $b += $m.Bytes; $f += $m.Files; $exists += $p }
        }
        $knownMap[$k] = $b
        $knownRows.Add([pscustomobject][ordered]@{ Name = $k; Size = Format-Size $b; Bytes = $b; Files = $f; Paths = $exists })
    }
    # Корзины на всех дисках
    [long]$recycle = 0
    foreach ($vol in $volumes | Where-Object { $_.DriveType -eq 'Fixed' }) {
        $m = Measure-Tree "$($vol.Letter):\`$Recycle.Bin"
        $recycle += $m.Bytes
    }
    $knownMap['Корзина'] = $recycle
    $knownRows.Add([pscustomobject][ordered]@{ Name = 'Корзина (все диски)'; Size = Format-Size $recycle; Bytes = $recycle; Files = $null; Paths = @('*:\$Recycle.Bin') })
    $report.KnownLocations = @($knownRows | Sort-Object Bytes -Descending)

    # Теневые копии / точки восстановления
    $shadow = @(Invoke-Safe { Get-CimInstance Win32_ShadowStorage -ErrorAction Stop } @())
    $report.ShadowStorage = @($shadow | ForEach-Object {
        [pscustomobject]@{ Volume = [string]$_.Volume.DeviceID; Used = Format-Size $_.UsedSpace; Allocated = Format-Size $_.AllocatedSpace; Max = Format-Size $_.MaxSpace; UsedBytes = [long]$_.UsedSpace }
    })

    function GB($name) { [double]$knownMap[$name] / 1GB }
    if ((GB 'Временные файлы пользователя (TEMP)') + (GB 'Временные файлы Windows') -gt 1) {
        Add-Finding INFO 'Временные файлы' ("TEMP: {0:N1} GB" -f ((GB 'Временные файлы пользователя (TEMP)') + (GB 'Временные файлы Windows'))) 'Параметры → Система → Память → Временные файлы → Удалить (безопасно).'
    }
    if ((GB 'Кэш обновлений Windows') + (GB 'Delivery Optimization') -gt 2) {
        Add-Finding INFO 'Обновления Windows' ("Кэш обновлений: {0:N1} GB" -f ((GB 'Кэш обновлений Windows') + (GB 'Delivery Optimization'))) 'cleanmgr → «Очистить системные файлы» → «Очистка обновлений Windows», «Файлы оптимизации доставки».'
    }
    if ((GB 'Старая Windows (Windows.old)') -gt 0.5) {
        Add-Finding INFO 'Windows.old' ("Предыдущая версия Windows: {0:N1} GB" -f (GB 'Старая Windows (Windows.old)')) 'Если откат не нужен: Параметры → Память → Временные файлы → «Предыдущие установки Windows».'
    }
    if ((GB 'Корзина') -gt 2) { Add-Finding INFO 'Корзина' ("В корзине {0:N1} GB" -f (GB 'Корзина')) 'Проверить и очистить корзину.' }
    if ((GB 'Дампы памяти') + (GB 'Отчёты об ошибках (WER)') -gt 0.5) {
        Add-Finding INFO 'Дампы/отчёты ошибок' ("{0:N1} GB" -f ((GB 'Дампы памяти') + (GB 'Отчёты об ошибках (WER)'))) 'cleanmgr → «Очистить системные файлы» → дампы и отчёты об ошибках.'
    }
    $browser = (GB 'Кэш Chrome') + (GB 'Кэш Edge') + (GB 'Кэш Firefox')
    if ($browser -gt 3) { Add-Finding INFO 'Кэш браузеров' ("{0:N1} GB" -f $browser) 'Ctrl+Shift+Del в браузере → «Изображения и файлы в кэше».' }
    if ((GB 'Кэш Telegram Desktop') -gt 3) {
        Add-Finding INFO 'Telegram' ("Кэш Telegram Desktop: {0:N1} GB" -f (GB 'Кэш Telegram Desktop')) 'Telegram → Настройки → Продвинутые → Управление памятью → Очистить; ограничить размер кэша.'
    }
    $dev = (GB 'Кэш npm / yarn') + (GB 'Кэш pip / Python') + (GB 'Пакеты NuGet')
    if ($dev -gt 3) { Add-Finding INFO 'Кэши разработчика' ("npm/pip/NuGet: {0:N1} GB" -f $dev) 'npm cache clean --force ; pip cache purge ; dotnet nuget locals all --clear' }
    if ((GB 'Файл гибернации') -gt 4) {
        Add-Finding INFO 'Гибернация' ("hiberfil.sys: {0:N1} GB" -f (GB 'Файл гибернации')) 'Если гибернация не нужна (ПК): от админа powercfg /h /type reduced (оставит быстрый запуск) или powercfg /h off.'
    }
    if ((GB 'Индекс поиска Windows') -gt 5) {
        Add-Finding INFO 'Индекс поиска' ("Индекс поиска: {0:N1} GB" -f (GB 'Индекс поиска Windows')) 'Параметры → Поиск в Windows → Дополнительные параметры индексатора → Перестроить / сократить папки.'
    }
    foreach ($s in $report.ShadowStorage | Where-Object { $_.UsedBytes -gt 20GB }) {
        Add-Finding INFO 'Точки восстановления' "Теневые копии на $($s.Volume): $($s.Used)" 'Защита системы → Настроить → ограничить до 5-10% (не отключать полностью).'
    }

    # --- Docker / WSL
    Write-Step 'Docker и WSL'
    $vhdx = @(foreach ($p in @("$la\Docker", "$la\wsl", "$la\Packages", "$pdata\DockerDesktop")) {
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Recurse -Depth 4 -Force -Filter '*.vhd*' -ErrorAction SilentlyContinue |
                Select-Object @{ n = 'Path'; e = { $_.FullName } }, @{ n = 'Bytes'; e = { $_.Length } }, @{ n = 'Size'; e = { Format-Size $_.Length } }, @{ n = 'Modified'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd') } }
        }
    })
    $dockerDf = ''
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $job = Start-Job { docker system df 2>&1 | Out-String }
        if (Wait-Job $job -Timeout 25) { $dockerDf = Receive-Job $job } else { $dockerDf = 'docker не ответил за 25 сек (Docker Desktop не запущен?)' }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    $wslList = ''
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $env:WSL_UTF8 = '1'
        $wslList = Invoke-Safe { ((wsl.exe --list --verbose 2>&1) -join "`n") -replace "`0", '' } ''
    }
    $report.DockerWsl = [ordered]@{ VirtualDisks = $vhdx; DockerSystemDf = $dockerDf; WslList = $wslList }
    foreach ($v in $vhdx | Where-Object { $_.Bytes -gt 20GB }) {
        Add-Finding INFO 'Docker/WSL' "Виртуальный диск $($v.Size): $($v.Path)" 'Образ не сжимается сам. 1) docker system prune -a (осторожно: удалит неиспользуемые образы) 2) wsl --shutdown 3) сжать vhdx (Optimize-VHD или diskpart compact vdisk). Либо перенести данные Docker на другой диск (Settings → Resources → Disk image location).'
    }

    # --- Порядок: Рабочий стол и Загрузки
    Write-Step 'Рабочий стол и Загрузки'
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $downloadsPath = $downloadsDir
    $deskItems = @(Get-ChildItem -LiteralPath $desktopPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('desktop.ini') -and $_.Name -notlike 'DiskAudit_*' })
    $order = [ordered]@{
        DesktopItems     = $deskItems.Count
        DesktopShortcuts = @($deskItems | Where-Object Extension -eq '.lnk').Count
        Downloads        = $null
    }
    if ($downloadsPath -and (Test-Path -LiteralPath $downloadsPath)) {
        $dl = @(Get-ChildItem -LiteralPath $downloadsPath -Recurse -File -Force -ErrorAction SilentlyContinue)
        $cut = (Get-Date).AddDays(-180)
        $installers = $dl | Where-Object { $_.Extension -in @('.exe', '.msi', '.iso', '.zip', '.rar', '.7z', '.msix', '.appx') }
        $order.Downloads = [ordered]@{
            Path             = $downloadsPath
            Files            = $dl.Count
            Size             = Format-Size (($dl | Measure-Object Length -Sum).Sum)
            Bytes            = [long](($dl | Measure-Object Length -Sum).Sum)
            OlderThan180d    = Format-Size (($dl | Where-Object LastWriteTime -lt $cut | Measure-Object Length -Sum).Sum)
            InstallersArchives = Format-Size (($installers | Measure-Object Length -Sum).Sum)
            InstallersBytes  = [long](($installers | Measure-Object Length -Sum).Sum)
        }
        if ($order.Downloads.Bytes -gt 5GB) {
            Add-Finding ORDER 'Загрузки' "В «Загрузках» $($order.Downloads.Size), из них старше 6 мес.: $($order.Downloads.OlderThan180d), установщики/архивы: $($order.Downloads.InstallersArchives)" 'Разобрать: нужное → в структуру папок, установщики и архивы — удалить.'
        }
    }
    if ($deskItems.Count -gt 25) {
        Add-Finding ORDER 'Рабочий стол' "На рабочем столе $($deskItems.Count) объектов" 'Оставить только ярлыки ежедневных программ; файлы — в рабочие папки (см. README: схема структуры).'
    }
    $report.Order = $order

    # --- Полное сканирование
    $report.DriveScans = @()
    $allDup = New-Object System.Collections.Generic.List[object]
    if (-not $Quick) {
        $toScan = @($volumes | Where-Object { $_.DriveType -eq 'Fixed' -and $_.SizeBytes -gt 0 } | ForEach-Object Letter)
        if ($Drives) { $toScan = @($toScan | Where-Object { $Drives -contains $_ }) }
        foreach ($l in $toScan) {
            Write-Step "Полное сканирование диска ${l}: (может занять несколько минут)"
            $scan = Invoke-DriveScan -Root "${l}:\" -TopFiles $TopFiles -BigBytes ([long]$BigFileMB * 1MB) -DupBytes ([long]$DupMinMB * 1MB) -OldCutoff (Get-Date).AddYears(-$OldYears)
            foreach ($c in $scan.DupCandidates) { $allDup.Add($c) }
            $scan.PSObject.Properties.Remove('DupCandidates')
            $report.DriveScans += $scan

            $vol = $volumes | Where-Object Letter -eq $l | Select-Object -First 1
            $video = @($scan.Extensions | Where-Object { $_.Extension -in @('.mp4', '.mov', '.mkv', '.avi', '.mts', '.m2ts', '.wmv') } | Measure-Object Bytes -Sum).Sum
            if ($vol.MediaType -eq 'SSD' -and $video -gt 50GB -and @($volumes | Where-Object { $_.DriveType -eq 'Fixed' -and $_.Letter -ne $l }).Count -gt 0) {
                Add-Finding ORDER "Диск ${l}:" ("Видео на SSD: {0:N0} GB" -f ($video / 1GB)) 'Исходники и готовые ролики (YouTube) — в архив на HDD/внешний диск; на SSD оставить только текущие проекты.'
            }
            if ($scan.OldBytes -gt 0.3 * $scan.ScannedBytes -and $scan.OldBytes -gt 50GB) {
                Add-Finding ORDER "Диск ${l}:" "Файлы, не изменявшиеся более $OldYears лет: $($scan.OldSize) из $($scan.ScannedSize)" 'Кандидаты в архив (внешний диск/облако), освободит рабочий диск.'
            }
            foreach ($bf in $scan.BigFiles | Where-Object { $_.Path -match '\.(iso|img|vmdk|vhdx?|bak|zip|rar|7z)$' } | Select-Object -First 5) {
                Add-Finding ORDER "Диск ${l}:" "Крупный образ/архив $($bf.Size): $($bf.Path)" 'Проверить актуальность: удалить или перенести в архив.'
            }
        }
        if ($allDup.Count -gt 1) {
            Write-Step 'Поиск дубликатов крупных файлов'
            $dups = Find-Duplicates $allDup
            $report.Duplicates = @($dups | Select-Object -First 100)
            $wasted = [long](($dups | Measure-Object WastedBytes -Sum).Sum)
            $report.DuplicatesWastedBytes = $wasted
            $report.DuplicatesWasted = Format-Size $wasted
            if ($wasted -gt 1GB) {
                Add-Finding ORDER 'Дубликаты' "Вероятные дубликаты файлов > $DupMinMB MB занимают лишние $(Format-Size $wasted)" 'Проверить список в отчёте (раздел «Дубликаты»); удалять вручную, оставив одну копию в правильной папке.'
            }
        }
    }

    # --- Итоги
    $levelOrder = @{ CRITICAL = 0; WARNING = 1; INFO = 2; ORDER = 3 }
    $report.Findings = @($script:Findings | Sort-Object { $levelOrder[$_.Level] })
    $report.DurationSec = [math]::Round(((Get-Date) - $started).TotalSeconds)

    Write-Step 'Сохранение отчёта'
    $jsonPath = Join-Path $OutputDir 'report.json'
    [IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $true))

    # summary.txt
    $txt = New-Object System.Text.StringBuilder
    [void]$txt.AppendLine("АУДИТ ДИСКОВ — $($report.System.Computer) — $($report.System.ReportDate)")
    [void]$txt.AppendLine("$($report.System.OS); RAM $($report.System.RAM_GB) GB; админ: $isAdmin; время: $($report.DurationSec) c")
    [void]$txt.AppendLine('')
    [void]$txt.AppendLine('ФИЗИЧЕСКИЕ ДИСКИ')
    foreach ($d in $physical) {
        [void]$txt.AppendLine(("  #{0} {1} | {2} {3} | {4} | {5} | t={6}°C износ={7}% часы={8} | {9}" -f $d.Number, $d.Model, $d.MediaType, $d.BusType, $d.Size, $d.Health, $d.TemperatureC, $d.WearPercent, $d.PowerOnHours, $d.Letters))
    }
    [void]$txt.AppendLine('')
    [void]$txt.AppendLine('ТОМА')
    foreach ($v in $volumes) {
        [void]$txt.AppendLine(("  {0}: {1,-18} {2,-6} {3,-10} всего {4,10}  свободно {5,10} ({6}%)  {7}" -f $v.Letter, $v.Label, $v.FileSystem, $v.MediaType, $v.Size, $v.Free, $v.FreePercent, $v.Health))
    }
    [void]$txt.AppendLine('')
    [void]$txt.AppendLine('НАХОДКИ И РЕКОМЕНДАЦИИ')
    if ($report.Findings.Count -eq 0) { [void]$txt.AppendLine('  Проблем не обнаружено.') }
    foreach ($f in $report.Findings) {
        [void]$txt.AppendLine("  [$($f.Level)] $($f.Area): $($f.Text)")
        [void]$txt.AppendLine("      -> $($f.Action)")
    }
    [void]$txt.AppendLine('')
    [void]$txt.AppendLine('КРУПНЕЙШИЕ СИСТЕМНЫЕ ПАПКИ/КЭШИ')
    foreach ($k in $report.KnownLocations | Select-Object -First 15) { [void]$txt.AppendLine(("  {0,12}  {1}" -f $k.Size, $k.Name)) }
    foreach ($s in $report.DriveScans) {
        [void]$txt.AppendLine('')
        [void]$txt.AppendLine("ДИСК $($s.Root) — просканировано $($s.ScannedSize), файлов $('{0:N0}' -f $s.Files), за $($s.Seconds) c")
        foreach ($t in $s.TopLevel | Select-Object -First 12) { [void]$txt.AppendLine(("  {0,12}  {1}" -f $t.Size, $t.Path)) }
    }
    $txtPath = Join-Path $OutputDir 'summary.txt'
    [IO.File]::WriteAllText($txtPath, $txt.ToString(), (New-Object Text.UTF8Encoding $true))

    # report.html
    $h = New-Object System.Text.StringBuilder
    $css = @'
:root{--bg:#f7f7f5;--fg:#1d1d1f;--muted:#6b6b70;--card:#fff;--line:#e3e3e0;--crit:#c62828;--warn:#b26a00;--info:#1565c0;--order:#2e7d32}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#ececec;--muted:#9a9aa0;--card:#1e1e22;--line:#2e2e33;--crit:#ef5350;--warn:#ffb74d;--info:#64b5f6;--order:#81c784}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1200px;margin:0 auto;padding:16px}
h1{font-size:22px;margin:8px 0}h2{font-size:17px;margin:28px 0 8px;border-bottom:1px solid var(--line);padding-bottom:4px}h3{font-size:15px;margin:18px 0 6px}
.muted{color:var(--muted)}.tw{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%}th,td{padding:6px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase}tr:last-child td{border-bottom:0}
td{word-break:break-word}tr.critical td:first-child{color:var(--crit);font-weight:700}tr.warning td:first-child{color:var(--warn);font-weight:700}
tr.info td:first-child{color:var(--info);font-weight:700}tr.order td:first-child{color:var(--order);font-weight:700}
pre{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px;overflow-x:auto}
'@
    [void]$h.Append("<!doctype html><html lang='ru'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Аудит дисков</title><style>$css</style></head><body><main>")
    [void]$h.Append("<h1>Аудит дисков — $(HtmlEnc $report.System.Computer)</h1><p class='muted'>$(HtmlEnc $report.System.OS) · RAM $($report.System.RAM_GB) GB · $(HtmlEnc $report.System.ReportDate) · админ: $isAdmin · $($report.DurationSec) c</p>")
    [void]$h.Append('<h2>Находки и рекомендации</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $report.Findings @('Level', 'Area', 'Text', 'Action') @('Уровень', 'Объект', 'Проблема', 'Что сделать') -RowClassProperty 'Level'))
    [void]$h.Append('<h2>Физические диски</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $physical @('Number', 'Model', 'MediaType', 'BusType', 'Size', 'Health', 'PartitionStyle', 'Letters', 'TemperatureC', 'WearPercent', 'PowerOnHours', 'ReadErrorsUncorr') @('#', 'Модель', 'Тип', 'Шина', 'Объём', 'Здоровье', 'Разметка', 'Буквы', 't°C', 'Износ %', 'Часы', 'Ошибки чтения')))
    [void]$h.Append('<h2>Тома</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $volumes @('Letter', 'Label', 'FileSystem', 'DriveType', 'MediaType', 'Size', 'Used', 'Free', 'FreePercent', 'Health', 'BitLocker') @('Диск', 'Метка', 'ФС', 'Тип', 'Носитель', 'Объём', 'Занято', 'Свободно', 'Своб. %', 'Состояние', 'BitLocker')))
    [void]$h.Append("<p class='muted'>TRIM: $(HtmlEnc $report.Optimization.TrimRaw) · Плановая оптимизация: $(HtmlEnc $report.Optimization.ScheduledDefrag), последний запуск $(HtmlEnc $report.Optimization.DefragLastRun)</p>")
    [void]$h.Append('<h2>Производительность (среднее за 5 сек)</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $perf @('Disk', 'BusyPercent', 'IdlePercent', 'QueueLength', 'AvgReadMs', 'AvgWriteMs', 'ReadMBs', 'WriteMBs') @('Диск', 'Занят %', 'Простой %', 'Очередь', 'Чтение, мс', 'Запись, мс', 'Чтение MB/s', 'Запись MB/s')))
    if ($report.Benchmark.Count) { [void]$h.Append('<h3>Бенчмарк winsat</h3>' + (ConvertTo-HtmlTableSafe $report.Benchmark @('Letter', 'Test', 'Value', 'Unit') @('Диск', 'Тест', 'Значение', 'Ед.'))) }
    [void]$h.Append('<h2>Системные папки, кэши, пользовательские папки</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $report.KnownLocations @('Size', 'Name', 'Files', 'Paths') @('Размер', 'Что', 'Файлов', 'Путь')))
    if ($report.ShadowStorage.Count) { [void]$h.Append('<h3>Точки восстановления (теневые копии)</h3>' + (ConvertTo-HtmlTableSafe $report.ShadowStorage @('Volume', 'Used', 'Allocated', 'Max') @('Том', 'Занято', 'Выделено', 'Лимит'))) }
    [void]$h.Append('<h2>Docker и WSL</h2>')
    [void]$h.Append((ConvertTo-HtmlTableSafe $vhdx @('Size', 'Path', 'Modified') @('Размер', 'Файл', 'Изменён')))
    if ($dockerDf) { [void]$h.Append('<pre>' + (HtmlEnc $dockerDf) + '</pre>') }
    if ($wslList) { [void]$h.Append('<pre>' + (HtmlEnc $wslList) + '</pre>') }
    [void]$h.Append('<h2>Порядок: Рабочий стол и Загрузки</h2>')
    $dlp = $order.Downloads
    [void]$h.Append("<p>Рабочий стол: <b>$($order.DesktopItems)</b> объектов (ярлыков: $($order.DesktopShortcuts)).")
    if ($dlp) { [void]$h.Append(" Загрузки: <b>$(HtmlEnc $dlp.Size)</b> в $($dlp.Files) файлах; старше 6 мес.: $(HtmlEnc $dlp.OlderThan180d); установщики/архивы: $(HtmlEnc $dlp.InstallersArchives).") }
    [void]$h.Append('</p>')
    foreach ($s in $report.DriveScans) {
        [void]$h.Append("<h2>Диск $(HtmlEnc $s.Root) — структура</h2><p class='muted'>Просканировано $(HtmlEnc $s.ScannedSize) · файлов $('{0:N0}' -f $s.Files) · папок $('{0:N0}' -f $s.Directories) · нет доступа: $($s.AccessDenied) · не менялись $OldYears+ лет: $(HtmlEnc $s.OldSize) · облачные (не на диске): $($s.CloudOnlyFiles) файлов / $(HtmlEnc $s.CloudOnlySize) · $($s.Seconds) c</p>")
        [void]$h.Append('<h3>Папки верхнего уровня</h3>' + (ConvertTo-HtmlTableSafe $s.TopLevel @('Size', 'Path') @('Размер', 'Папка')))
        [void]$h.Append('<h3>Папки 2-го уровня</h3>' + (ConvertTo-HtmlTableSafe $s.TopLevel2 @('Size', 'Path') @('Размер', 'Папка')))
        [void]$h.Append('<h3>Папки 3-го уровня</h3>' + (ConvertTo-HtmlTableSafe $s.TopLevel3 @('Size', 'Path') @('Размер', 'Папка')))
        [void]$h.Append('<h3>Типы файлов</h3>' + (ConvertTo-HtmlTableSafe $s.Extensions @('Extension', 'Size', 'Files') @('Расширение', 'Размер', 'Файлов')))
        [void]$h.Append("<h3>Крупнейшие файлы (&ge; $BigFileMB MB)</h3>" + (ConvertTo-HtmlTableSafe $s.BigFiles @('Size', 'Path', 'Modified') @('Размер', 'Файл', 'Изменён')))
    }
    if ($report.Contains('Duplicates')) {
        [void]$h.Append("<h2>Вероятные дубликаты (файлы &ge; $DupMinMB MB) — лишнее место: $(HtmlEnc $report.DuplicatesWasted)</h2><p class='muted'>Сравнение по размеру и частичному хешу (начало/середина/конец). Перед удалением убедитесь вручную.</p>")
        [void]$h.Append((ConvertTo-HtmlTableSafe $report.Duplicates @('Wasted', 'Copies', 'FileSize', 'Paths') @('Лишнее', 'Копий', 'Размер файла', 'Пути')))
    }
    [void]$h.Append('<p class="muted">Скрипт только читает данные и ничего не изменяет. Папки C:\Windows содержат жёсткие ссылки (WinSxS) — их размер завышен.</p></main></body></html>')
    $htmlPath = Join-Path $OutputDir 'report.html'
    [IO.File]::WriteAllText($htmlPath, $h.ToString(), (New-Object Text.UTF8Encoding $true))

    Write-Host ''
    Write-Host "Готово за $($report.DurationSec) c. Отчёт: $OutputDir" -ForegroundColor Green
    Write-Host ("Находки: критичных {0}, предупреждений {1}, советов {2}, порядок {3}" -f `
        @($report.Findings | Where-Object Level -eq 'CRITICAL').Count, @($report.Findings | Where-Object Level -eq 'WARNING').Count,
        @($report.Findings | Where-Object Level -eq 'INFO').Count, @($report.Findings | Where-Object Level -eq 'ORDER').Count)
    Invoke-Safe { Start-Process $htmlPath } | Out-Null
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-DiskAudit }
