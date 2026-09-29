<#
.SYNOPSIS
    Восстановление файлов из «Архивации и восстановления (Windows 7)» без sdclt.

.DESCRIPTION
    Папки "Backup Set ..." содержат обычные ZIP-архивы. Скрипт:
      1) находит все копии ("Backup Files ...") во всех наборах и сортирует их по дате;
      2) выбирает для каждого файла САМУЮ СВЕЖУЮ версию;
      3) распаковывает её в отдельную папку, сохраняя структуру подпапок и дату изменения.
    Исходные архивы только читаются и не изменяются.
    В конце создаётся журнал _restore_log.csv в папке назначения.

.PARAMETER UserFolder
    Имя папки пользователя внутри C:\Users в архиве (например, старый профиль).

.PARAMETER Folders
    Какие папки профиля восстанавливать. По умолчанию: документы, загрузки, рабочий стол,
    изображения, видео, музыка, избранное. AppData не восстанавливается.

.PARAMETER ListOnly
    Только показать, что будет восстановлено (ничего не распаковывать).

.PARAMETER CodePage
    Кодировка имён файлов в ZIP. По умолчанию — OEM-кодировка системы (866 для русской Windows).

.EXAMPLE
    .\Restore-FromWindowsBackup.ps1 -UserFolder Suxow -ListOnly
.EXAMPLE
    .\Restore-FromWindowsBackup.ps1 -UserFolder Suxow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$UserFolder,
    [string]$BackupRoot = 'D:\SSV',
    [string]$Destination,
    [string[]]$Folders = @('Documents', 'Downloads', 'Desktop', 'Pictures', 'Videos', 'Music', 'Favorites'),
    [string]$Drive = 'C',
    [switch]$ListOnly,
    [int]$CodePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Sep = [IO.Path]::DirectorySeparatorChar

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

if (-not $Destination) { $Destination = "D:\Восстановлено_$UserFolder" }
$enc = [Text.Encoding]::GetEncoding($CodePage)
$root = "$Drive/Users/$UserFolder/"
$prefixes = @($Folders | ForEach-Object { ($root + $_ + '/').ToLowerInvariant() })

# --- 1. Все копии по порядку дат (имя "Backup Files yyyy-MM-dd HHmmss" сортируется как дата)
$copies = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'Backup Set *' |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Filter 'Backup Files *' } |
    Sort-Object Name)
if ($copies.Count -eq 0) { throw "В $BackupRoot не найдено папок 'Backup Set *\Backup Files *'." }
Write-Host "Найдено копий: $($copies.Count)" -ForegroundColor Cyan
$copies | ForEach-Object { Write-Host "  $($_.Parent.Name)  \  $($_.Name)" }

# --- 2. Составляем план: последняя версия каждого файла
$plan = @{}
$split = @{}
[long]$longPathEntries = 0
$i = 0
foreach ($copy in $copies) {
    $i++
    $zips = @(Get-ChildItem -LiteralPath $copy.FullName -Filter '*.zip' |
        Sort-Object { $n = $_.BaseName -replace '\D', ''; if ($n) { [int]$n } else { 0 } })
    $seenHere = @{}
    $j = 0
    foreach ($zf in $zips) {
        $j++
        Write-Progress -Activity "Анализ копии $i из $($copies.Count): $($copy.Name)" -Status "Архив $j из $($zips.Count)" -PercentComplete ([int](100 * $j / [math]::Max(1, $zips.Count)))
        $z = [IO.Compression.ZipFile]::Open($zf.FullName, [IO.Compression.ZipArchiveMode]::Read, $enc)
        try {
            foreach ($e in $z.Entries) {
                if (-not $e.Name) { continue }                      # запись-папка
                $full = $e.FullName -replace '\\', '/'
                if ($full -match '^[A-Za-z]/\d+/') { $longPathEntries++; continue }   # файлы с длинными путями
                $low = $full.ToLowerInvariant()
                $hit = $false
                foreach ($p in $prefixes) { if ($low.StartsWith($p)) { $hit = $true; break } }
                if (-not $hit) { continue }
                $rel = $full.Substring($root.Length)
                $key = $rel.ToLowerInvariant()
                if ($seenHere.ContainsKey($key)) { $split[$rel] = $copy.Name }
                $seenHere[$key] = $true
                $plan[$key] = [pscustomobject]@{
                    Rel = $rel; Zip = $zf.FullName; Entry = $e.FullName
                    Length = $e.Length; Time = $e.LastWriteTime; Copy = $copy.Name
                }
            }
        } finally { $z.Dispose() }
    }
}
Write-Progress -Activity 'Анализ' -Completed

$items = @($plan.Values)
if ($items.Count -eq 0) {
    Write-Warning "В архивах нет файлов в $($root)[$($Folders -join ', ')]. Проверьте -UserFolder и -Drive."
    return
}
[long]$totalBytes = ($items | Measure-Object Length -Sum).Sum

# --- 3. Сводка
Write-Host ''
Write-Host "Будет восстановлено: $($items.Count) файлов, $(Format-Size $totalBytes)" -ForegroundColor Green
Write-Host "Папка назначения:   $Destination"
Write-Host ''
Write-Host 'По папкам профиля:' -ForegroundColor Cyan
$items | Group-Object { ($_.Rel -split '/')[0] } | Sort-Object Name | ForEach-Object {
    '  {0,-12} {1,7} файлов  {2,10}' -f $_.Name, $_.Count, (Format-Size (($_.Group | Measure-Object Length -Sum).Sum))
}
Write-Host 'Из каких копий берутся последние версии:' -ForegroundColor Cyan
$items | Group-Object Copy | Sort-Object Name | ForEach-Object { '  {0}  — {1} файлов' -f $_.Name, $_.Count }
Write-Host 'Вложенные папки (2-й уровень):' -ForegroundColor Cyan
$items | Group-Object { $s = $_.Rel -split '/'; if ($s.Count -gt 2) { $s[0] + '\' + $s[1] } else { $s[0] + '\(файлы)' } } |
    Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending | Select-Object -First 25 | ForEach-Object {
        '  {0,10}  {1}' -f (Format-Size (($_.Group | Measure-Object Length -Sum).Sum)), $_.Name
    }
if ($longPathEntries) {
    Write-Host "Примечание: $longPathEntries файлов с очень длинными путями хранятся под кодовыми именами — их восстанавливает только sdclt." -ForegroundColor Yellow
}

if ($ListOnly) {
    Write-Host ''
    Write-Host 'Режим -ListOnly: ничего не распаковано. Для восстановления запустите без -ListOnly.' -ForegroundColor Yellow
    return
}

# --- 4. Распаковка (каждый архив открывается один раз)
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$log = New-Object System.Collections.Generic.List[object]
[long]$done = 0; $ok = 0; $fail = 0; $n = 0
foreach ($g in ($items | Group-Object Zip)) {
    $z = [IO.Compression.ZipFile]::Open($g.Name, [IO.Compression.ZipArchiveMode]::Read, $enc)
    try {
        foreach ($it in $g.Group) {
            $n++
            if ($n % 50 -eq 0) {
                Write-Progress -Activity 'Восстановление' -Status "$n из $($items.Count), $(Format-Size $done)" -PercentComplete ([int](100 * $done / [math]::Max(1, $totalBytes)))
            }
            $dest = Join-Path $Destination ($it.Rel -replace '/', [string]$Sep)
            try {
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                $entry = $z.GetEntry($it.Entry)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                (Get-Item -LiteralPath $dest -Force).LastWriteTime = $it.Time.DateTime
                $ok++; $done += $it.Length
                $log.Add([pscustomobject]@{ Status = 'OK'; File = $it.Rel; Bytes = $it.Length; Copy = $it.Copy; Error = '' })
            } catch {
                $fail++
                $log.Add([pscustomobject]@{ Status = 'ERROR'; File = $it.Rel; Bytes = $it.Length; Copy = $it.Copy; Error = $_.Exception.Message })
            }
        }
    } finally { $z.Dispose() }
}
Write-Progress -Activity 'Восстановление' -Completed

$logPath = Join-Path $Destination '_restore_log.csv'
$log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Готово: восстановлено $ok файлов ($(Format-Size $done)), ошибок: $fail" -ForegroundColor Green
Write-Host "Журнал: $logPath"
if ($fail) {
    Write-Host 'Первые ошибки:' -ForegroundColor Yellow
    $log | Where-Object Status -eq 'ERROR' | Select-Object -First 10 | ForEach-Object { "  $($_.File): $($_.Error)" }
}
if ($split.Count) {
    Write-Host "Внимание: $($split.Count) файлов записаны в одной копии несколькими частями — проверьте их (при повреждении восстановите через sdclt):" -ForegroundColor Yellow
    $split.Keys | Select-Object -First 10 | ForEach-Object { "  $_" }
}
