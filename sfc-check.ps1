# Скрипт проверки и восстановления системных файлов (SFC / DISM)
# Версия: 0.1
# Автор: SafeZone.cc
# Совместимость: Windows 7 SP1 + PowerShell 2.0+

param()

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$cbsLog     = Join-Path $env:SystemRoot "Logs\CBS\CBS.log"
$sessionTS  = Get-Date -Format 'yyyyMMdd_HHmmss'
$sessionLog = Join-Path $scriptDir "sfc_summary_$sessionTS.log"
$rawLog     = Join-Path $scriptDir "sfc_raw_$sessionTS.log"

# =============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =============================================================================

function Check-Elevated {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr  = New-Object Security.Principal.WindowsPrincipal($id)
    $adm = [Security.Principal.WindowsBuiltInRole]::Administrator
    if (-not $pr.IsInRole($adm)) {
        Write-Host "Ошибка: необходимы права Администратора." -ForegroundColor Red
        Write-Host "Правая кнопка на скрипте -> Запустить от имени Администратора" -ForegroundColor Yellow
        Write-Host ""
        if ($Host.Name -eq 'ConsoleHost') { Read-Host "Нажмите Enter для выхода..." | Out-Null }
        exit 1
    }
}

function Get-OSInfo {
    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return @{ Caption="Unknown"; Build="?"; Arch="?" } }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64" -or $env:PROCESSOR_ARCHITEW6432) { "64-bit" } else { "32-bit" }
    return @{
        Caption = $os.Caption
        Build   = "Build $($os.BuildNumber)"
        Arch    = $arch
    }
}

function Write-Summary {
    param([string]$Line)
    try {
        [System.IO.File]::AppendAllText($sessionLog,
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Line`r`n",
            [System.Text.Encoding]::UTF8)
    } catch {}
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  =====================================" -ForegroundColor Cyan
    Write-Host "   $Title" -ForegroundColor Cyan
    Write-Host "  =====================================" -ForegroundColor Cyan
    Write-Host ""
}

function Get-LastLines {
    param(
        [string[]]$Lines,
        [int]$Count
    )
    if ($Lines.Count -le $Count) { return $Lines }
    $result = @()
    $start  = $Lines.Count - $Count
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        $result += $Lines[$i]
    }
    return $result
}

function Kill-TiWorker {
    $procs = Get-Process -Name "TiWorker" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($proc in $procs) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] TiWorker.exe остановлен (PID $($proc.Id))" -ForegroundColor Green
        }
    } else {
        Write-Host "  [-] TiWorker.exe не запущен" -ForegroundColor DarkGray
    }
}

# =============================================================================
# АНАЛИЗ CBS.LOG — правила трактовки по статье SafeZone.cc:
# =============================================================================

function Get-SFCStatus {
    # Возвращает: 'clean' | 'repaired' | 'cannot_repair' | 'unknown'
    if (-not (Test-Path $cbsLog)) { return 'unknown' }
    try {
        $tail = Get-LastLines -Lines (Get-Content $cbsLog -ErrorAction Stop) -Count 3000

        $cannotRepair = $false
        $repairingN   = 0
        $repairDone   = $false
        $verifyDone   = $false

        foreach ($line in $tail) {
            if ($line -match '\[SR\] Cannot repair|\[SR\] Could not reproject') {
                $cannotRepair = $true
            }
            if ($line -match '\[SR\] Repairing (\d+) components?') {
                $repairingN = [int]$Matches[1]
            }
            if ($line -match '\[SR\] Repair complete') {
                $repairDone = $true
            }
            if ($line -match '\[SR\] Verify complete') {
                $verifyDone = $true
            }
        }

        if ($cannotRepair)                        { return 'cannot_repair' }
        if ($repairDone -and $repairingN -gt 0)   { return 'repaired' }
        if ($repairDone -and $repairingN -eq 0)   { return 'clean' }
        if ($verifyDone)                          { return 'clean' }
        return 'unknown'
    } catch { return 'unknown' }
}

function Export-RawSFCLog {
    if (-not (Test-Path $cbsLog)) { return }
    try {
        $lines = Get-Content $cbsLog -ErrorAction Stop |
                 Where-Object { $_ -match '\[SR\]' -and $_ -notmatch 'Verifying \d+ of \d+' }

        $header  = "=" * 60
        $header += "`r`nSFC Raw Log — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $header += "`r`nИсходный лог: $cbsLog"
        $header += "`r`nФильтр: [SR] без строк прогресса (Verifying NNN of MMMMM)"
        $header += "`r`n" + "=" * 60 + "`r`n"

        [System.IO.File]::WriteAllText($rawLog,
            $header + ($lines -join "`r`n") + "`r`n",
            [System.Text.Encoding]::UTF8)
    } catch {}
}

function Show-SFCResults {
    param([string]$Label = "Сводка SFC")

    Export-RawSFCLog

    if (-not (Test-Path $cbsLog)) {
        Write-Host "  CBS.log не найден: $cbsLog" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  --- $Label ---" -ForegroundColor Cyan

    try {
        $significant = Get-LastLines -Lines (Get-Content $cbsLog -ErrorAction Stop) -Count 3000 |
            Where-Object {
                $_ -match '\[SR\] Cannot repair'           -or
                $_ -match '\[SR\] Could not reproject'     -or
                $_ -match '\[SR\] Repairing \d+ components?' -or
                $_ -match '\[SR\] Repair complete'         -or
                $_ -match '\[SR\] Verify complete'         -or
                $_ -match '\[SR\] Beginning Verify and Repair' -or
                $_ -match '\(f\) CBS'                      -or
                $_ -match 'CBS MUM Corrupt'
            }

        if ($significant) {
            foreach ($l in $significant) {
                if ($l -match 'Cannot repair|Could not reproject|\(f\) CBS|MUM Corrupt') {
                    $color = 'Red'
                } elseif ($l -match 'Repair complete') {
                    $color = 'Green'
                } elseif ($l -match 'Repairing (\d+)' -and [int]$Matches[1] -gt 0) {
                    $color = 'Yellow'
                } else {
                    $color = 'Gray'
                }
                Write-Host "    $($l.Trim())" -ForegroundColor $color
            }
        } else {
            Write-Host "  Значимых записей не найдено." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  Ошибка чтения CBS.log: $_" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  Сырой лог [SR] для ручного анализа: $rawLog" -ForegroundColor DarkGray
}

function Write-SFCVerdict {
    param([string]$Status, [int]$ExitCode)

    Write-Host ""
    switch ($Status) {
        'clean' {
            Write-Host "  [✓] Нарушений целостности системных файлов не обнаружено." -ForegroundColor Green
            Write-Host "      (Repairing 0 components + Repair complete — норма)" -ForegroundColor DarkGray
            Write-Summary "[SFC] Статус: ЧИСТО (ExitCode=$ExitCode)"
        }
        'repaired' {
            Write-Host "  [✓] Повреждённые файлы найдены и успешно восстановлены." -ForegroundColor Green
            Write-Host "      Рекомендуется перезагрузка для применения изменений." -ForegroundColor Yellow
            Write-Summary "[SFC] Статус: ВОССТАНОВЛЕНО (ExitCode=$ExitCode)"
        }
        'cannot_repair' {
            Write-Host "  [!] Обнаружены файлы, которые SFC не смог восстановить." -ForegroundColor Red
            Write-Host "      Требуется восстановление хранилища: пункт [4] DISM /RestoreHealth" -ForegroundColor Yellow
            Write-Summary "[SFC] Статус: НЕ ИСПРАВЛЕНО (нужен DISM) (ExitCode=$ExitCode)"
        }
        default {
            Write-Host "  [?] Статус SFC не определён (ExitCode=$ExitCode)." -ForegroundColor DarkYellow
            Write-Host "      Проверьте сырой лог вручную: $rawLog" -ForegroundColor DarkYellow
            Write-Summary "[SFC] Статус: НЕИЗВЕСТЕН (ExitCode=$ExitCode)"
        }
    }
}

# =============================================================================
# SFC
# =============================================================================

function Run-SFCScan {
    Write-Section "SFC /scannow — Проверка и восстановление системных файлов"
    Write-Host "  Не закрывайте консоль до завершения." -ForegroundColor Yellow
    Write-Host ""

    Kill-TiWorker
    Write-Host ""
    Write-Summary "[SFC] Запуск sfc /scannow"

    & sfc /scannow | Out-Host
    $ec = $LASTEXITCODE

    Write-Summary "[SFC] Завершён, ExitCode=$ec"
    return $ec
}

# =============================================================================
# ПУНКТ [3] — Быстрая проверка хранилища (DISM /CheckHealth)
# =============================================================================

function Run-DISM-Check {
    param([string]$Operation)

    $valid = @('Check','Analyze','Cleanup','Restore')
    if ($valid -notcontains $Operation) {
        Write-Host "  Ошибка: неверная операция '$Operation'" -ForegroundColor Red
        return 1
    }

    $titles = @{
        Check   = "DISM /CheckHealth — Быстрая проверка хранилища компонентов"
        Analyze = "DISM /AnalyzeComponentStore — Анализ размера хранилища WinSxS"
        Cleanup = "DISM /StartComponentCleanup — Очистка хранилища WinSxS"
        Restore = "DISM /RestoreHealth — Восстановление хранилища компонентов"
    }
    $argStr = @{
        Check   = '/online /cleanup-image /checkhealth'
        Analyze = '/online /cleanup-image /analyzecomponentstore'
        Cleanup = '/online /cleanup-image /startcomponentcleanup'
        Restore = '/online /cleanup-image /restorehealth'
    }

    Write-Section $titles[$Operation]

    if ($Operation -eq 'Restore') {
        Write-Host "  Требуется подключение к интернету (или установочный ISO)." -ForegroundColor Yellow
        Write-Host "  Может занять 15–30 минут." -ForegroundColor Yellow
        Write-Host ""
    }
    Kill-TiWorker
    Write-Host ""
    $argList = $argStr[$Operation] -split ' '
    & dism $argList | Out-Host
    $ec = $LASTEXITCODE

    Write-Summary "[DISM] ExitCode=$ec"
    return $ec
}

# =============================================================================
# ПУНКТ [4] — Восстановление хранилища (DISM /RestoreHealth)
# =============================================================================

function Run-DISM-Restore {
    Write-Section "DISM /RestoreHealth — Восстановление хранилища компонентов"
    Write-Host "  Требуется подключение к интернету (или установочный ISO)." -ForegroundColor Yellow
    Write-Host "  Может занять 15–30 минут." -ForegroundColor Yellow
    Write-Host ""

    Kill-TiWorker
    Write-Host ""
    Write-Summary "[DISM Restore] Запуск"

    $argList = @('/online', '/cleanup-image', '/restorehealth')
    & dism $argList | Out-Host
    $ec = $LASTEXITCODE

    Write-Host ""
    if ($ec -eq 0) {
        Write-Host "  [✓] Хранилище восстановлено." -ForegroundColor Green
        Write-Summary "[DISM Restore] УСПЕШНО (ExitCode=$ec)"
    } else {
        Write-Host "  [✗] Восстановление не удалось (ExitCode=$ec)." -ForegroundColor Red
        Write-Summary "[DISM Restore] ОШИБКА (ExitCode=$ec)"
    }

    return $ec
}

# =============================================================================
# ПУНКТЫ [5-6] — Очистка и анализ WinSxS (DISM)
# =============================================================================

function Run-DISM-Cleanup {
    Write-Section "DISM /StartComponentCleanup — Очистка хранилища WinSxS"
    Kill-TiWorker
    $argList = @('/online', '/cleanup-image', '/startcomponentcleanup')
    & dism $argList | Out-Host
    $ec = $LASTEXITCODE
    Write-Host ""
    if ($ec -eq 0) {
        Write-Host "  [✓] Очистка завершена." -ForegroundColor Green
        Write-Summary "[DISM Cleanup] УСПЕШНО"
    } else {
        Write-Host "  [✗] Ошибка (ExitCode=$ec)." -ForegroundColor Red
        Write-Summary "[DISM Cleanup] ОШИБКА"
    }
    return $ec
}

function Run-DISM-Analyze {
    Write-Section "DISM /AnalyzeComponentStore — Анализ размера хранилища WinSxS"
    Kill-TiWorker
    $argList = @('/online', '/cleanup-image', '/analyzecomponentstore')
    & dism $argList | Out-Host
    $ec = $LASTEXITCODE
    Write-Host ""
    if ($ec -eq 0) {
        Write-Host "  [✓] Анализ завершён." -ForegroundColor Green
        Write-Summary "[DISM Analyze] УСПЕШНО"
    } else {
        Write-Host "  [✗] Ошибка (ExitCode=$ec)." -ForegroundColor Red
        Write-Summary "[DISM Analyze] ОШИБКА"
    }
    return $ec
}

# =============================================================================
# ПУНКТ [8] — Сведения о системе с отдельным логом
# =============================================================================

function Export-PCInfoLog {
    param([string]$Content, [string]$Filename)
    try {
        $logPath = Join-Path $scriptDir $Filename
        $header = "=" * 60 + "`r`n"
        $header += "PC Info Log — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" + "`r`n"
        $header += "Source: systeminfo /fo list" + "`r`n" + "=" * 60 + "`r`n" + "`r`n"
        [System.IO.File]::WriteAllText($logPath, $header + $Content + "`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

function Show-PCInfo {
    Write-Section "Сведения о системе"
    
    $pcInfoContent = "=== System Information ===`r`n`r`n"
    
    try {
        $systemInfoRaw = & systeminfo /fo list 2>&1
        if (-not ($systemInfoRaw -match 'Недоступно')) {
            $pcInfoContent += $systemInfoRaw + "`r`n"
        }
    } catch {}
    
    Export-PCInfoLog -Content $pcInfoContent -Filename "sfc_pcinfo_$sessionTS.txt"
    
    Write-Host ""
    Write-Host "  Точки восстановления:" -ForegroundColor Yellow
    try {
        $pts = Get-ComputerRestorePoint -ErrorAction Stop
        if ($pts) {
            $pts | ForEach-Object {
                Write-Host "  [$($_.SequenceNumber)] $($_.Description)  ($($_.CreationTime))" -ForegroundColor Gray
            }
        } else {
            Write-Host "  Точек восстановления не найдено." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  Недоступно: $_" -ForegroundColor DarkYellow
    }

    Write-Summary "[PCInfo] Лог сохранён в sfc_pcinfo_$sessionTS.txt"
}

# =============================================================================
# ПУНКТЫ [1,2] — Основные функции
# =============================================================================

function Run-FullRepairCycle {
    Write-Section "Расширенная проверка и восстановление: SFC → DISM → SFC"
    Write-Host "  Шаги:" -ForegroundColor Yellow
    Write-Host "   Шаг 1: SFC /scannow — первичная проверка и восстановление" -ForegroundColor Gray
    Write-Host "   Шаг 2: Если SFC не смог исправить — DISM /RestoreHealth" -ForegroundColor Gray
    Write-Host "   Шаг 3: SFC /scannow повторно — проверка после DISM" -ForegroundColor Gray
    Write-Host ""

    # --- Шаг 1 ---
    Write-Host "  [Шаг 1/3] Первичная проверка и восстановление..." -ForegroundColor Cyan
    $ec1 = Run-SFCScan
    Show-SFCResults -Label "Результаты первого SFC"
    $st1 = Get-SFCStatus
    Write-SFCVerdict -Status $st1 -ExitCode $ec1

    if ($st1 -eq 'clean' -or $st1 -eq 'repaired') {
        Write-Host ""
        Write-Host "  Хранилище компонентов в порядке. Цикл завершён." -ForegroundColor Green
        Write-Summary "[Цикл] Завершён после шага 1 (статус: $st1)"
        return
    }

    # --- Шаг 2: DISM ---
    Write-Host ""
    Write-Host "  [Шаг 2/3] Восстановление хранилища компонентов..." -ForegroundColor Cyan
    $ec2 = Run-DISM-Restore

    if ($ec2 -ne 0) {
        Write-Host ""
        Write-Host "  [✗] DISM /RestoreHealth завершился с ошибкой (ExitCode=$ec2)." -ForegroundColor Red
        Write-Host "      Проверьте интернет-соединение или подключите установочный ISO." -ForegroundColor Red
        Write-Summary "[Цикл] DISM ошибка ExitCode=$ec2 — цикл прерван"
        return
    }

    Write-Host ""
    Write-Host "  [✓] Хранилище восстановлено." -ForegroundColor Green

    # --- Шаг 3: повторный SFC ---
    Write-Host ""
    Write-Host "  [Шаг 3/3] Повторная проверка и восстановление..." -ForegroundColor Cyan
    $ec3 = Run-SFCScan
    Show-SFCResults -Label "Результаты повторного SFC"
    $st3 = Get-SFCStatus
    Write-SFCVerdict -Status $st3 -ExitCode $ec3

    if ($st3 -eq 'cannot_repair') {
        Write-Host ""
        Write-Host "  [✗] Часть файлов по-прежнему не восстановлена." -ForegroundColor Red
        Write-Host "      Возможно, требуется обновление или переустановка системы." -ForegroundColor Red
        Write-Summary "[Цикл] Итог: шаг1=$st1(ec=$ec1) / DISM ec=$ec2 / шаг3=$st3(ec=$ec3)"
    } else {
        Write-Host ""
        Write-Host "  Все файлы восстановлены. Рекомендуется перезагрузка." -ForegroundColor Green
        Write-Summary "[Цикл] Итог: ВСЕ ВОССТАНОВЛЕНО"
    }
}

# =============================================================================
# ПРОЧИЕ ПУНКТЫ
# =============================================================================

function Open-Folders {
    Write-Host ""
    Write-Host "  Открываю папки с логами..." -ForegroundColor Cyan
    @("$env:SystemRoot\Logs\CBS", "$env:SystemRoot\Logs\DISM", $scriptDir) | ForEach-Object {
        if (Test-Path $_) { try { Start-Process explorer.exe $_ } catch {} }
    }
    foreach ($f in @($sessionLog, $rawLog)) {
        if (Test-Path $f) { try { Start-Process notepad.exe $f } catch {} }
    }
    Write-Host ""
    Write-Host "  Сводный лог  : $sessionLog" -ForegroundColor Gray
    Write-Host "  Сырой лог    : $rawLog" -ForegroundColor Gray
    Write-Host "  Скопируйте логи на SafeZone.cc для анализа." -ForegroundColor Gray
}

function Show-Help {
    Write-Section "СПРАВКА"
    Write-Host "  Что означают результаты SFC:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Защита ресурсов Windows не обнаружила нарушений целостности" -ForegroundColor Green
    Write-Host "     → Система чиста. Никаких действий не требуется." -ForegroundColor Green
    Write-Host ""
    Write-Host "   Repairing 0 components + Repair complete (в CBS.log)" -ForegroundColor Green
    Write-Host "     → Тоже НОРМА. SFC запустился, ничего не нашёл." -ForegroundColor Green
    Write-Host "     → Это НЕ ошибка, несмотря на слово 'Repairing'." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   Программа защиты нашла повреждённые файлы и восстановила их" -ForegroundColor Yellow
    Write-Host "     → Ошибки исправлены. Рекомендуется перезагрузка." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Защита нашла повреждённые файлы, но не может восстановить некоторые" -ForegroundColor Red
    Write-Host "     → Запустите пункт [2] Расширенная проверка." -ForegroundColor Red
    Write-Host "     → Или вручную: [4] DISM /RestoreHealth, затем снова [1] SFC." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Файлы отчётов:" -ForegroundColor Yellow
    Write-Host "   sfc_summary_*.log  — сводка: только итоги, без лишних строк" -ForegroundColor Gray
    Write-Host "   sfc_raw_*.log      — сырые строки [SR] из CBS.log для ручного анализа" -ForegroundColor Gray
    Write-Host "   (метод фильтрации: аналог findstr /c:[SR] cbs.log)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Совместимость: Windows 7 SP1 и выше (PowerShell 2.0+)" -ForegroundColor DarkGray
    Write-Host "  Пункт [5] (очистка WinSxS) не поддерживается на Windows 7." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Подробнее о CBS.log: https://safezone.cc/threads/30995/" -ForegroundColor Cyan
}

# =============================================================================
# МЕНЮ
# =============================================================================

function Show-Menu {
    Write-Host ""
    Write-Host "  =====================================" -ForegroundColor Cyan
    Write-Host "   Проверка системных файлов  v0.1" -ForegroundColor Cyan
    Write-Host "   SafeZone.cc" -ForegroundColor Cyan
    Write-Host "   $($script:osInfo.Caption)  |  $($script:osInfo.Arch)" -ForegroundColor Gray
    Write-Host "  =====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   [1]  Стандартная проверка и восстановление (SFC /scannow)" -ForegroundColor White
    Write-Host "   [2]  Расширенная проверка и восстановление (SFC → DISM → SFC)" -ForegroundColor Yellow
    Write-Host "   [3]  Быстрая проверка хранилища компонентов (DISM /CheckHealth)" -ForegroundColor White
    Write-Host "   [4]  Восстановление хранилища компонентов (DISM /RestoreHealth)" -ForegroundColor White
    Write-Host "   [5]  Очистка хранилища WinSxS (DISM /StartComponentCleanup)" -ForegroundColor White
    Write-Host "   [6]  Анализ размера хранилища WinSxS (DISM /AnalyzeComponentStore)" -ForegroundColor White
    Write-Host "   [7]  Открыть папки с логами" -ForegroundColor White
    Write-Host "   [8]  Сведения о системе" -ForegroundColor White
    Write-Host "   [9]  Справка" -ForegroundColor White
    Write-Host "   [0]  Выход" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-Choice {
    param([string]$Choice)
    switch ($Choice) {
        '1' {
            $ec = Run-SFCScan
            Show-SFCResults
            $st = Get-SFCStatus
            Write-SFCVerdict -Status $st -ExitCode $ec
        }
        '2' { 
            Run-FullRepairCycle
        }
        '3' {
            $ec = Run-DISM-Check -Operation Check
            
            Write-Host ""
            if ($ec -eq 0) {
                Write-Host "  [✓] Хранилище компонентов в порядке." -ForegroundColor Green
                Write-Summary "[DISM CheckHealth] OK (ExitCode=$ec)"
            } else {
                Write-Host "  [!] Обнаружены проблемы хранилища (ExitCode=$ec)." -ForegroundColor Red
                Write-Host "      Запустите пункт [4] DISM /RestoreHealth." -ForegroundColor Yellow
                Write-Summary "[DISM CheckHealth] ОШИБКА (ExitCode=$ec)"
            }
            
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '4' { 
            $ec = Run-DISM-Restore
            
            Write-Host ""
            if ($ec -eq 0) {
                Write-Host "  [✓] Хранилище восстановлено." -ForegroundColor Green
                Write-Host "      Запустите пункт [1] SFC /scannow." -ForegroundColor Yellow
                Write-Summary "[DISM RestoreHealth] OK (ExitCode=$ec)"
            } else {
                Write-Host "  [✗] Восстановление не удалось (ExitCode=$ec)." -ForegroundColor Red
                Write-Summary "[DISM RestoreHealth] ОШИБКА (ExitCode=$ec)"
            }
            
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '5' { 
            $ec = Run-DISM-Cleanup
            
            Write-Host ""
            if ($ec -eq 0) {
                Write-Host "  [✓] Очистка WinSxS завершена." -ForegroundColor Green
                Write-Summary "[DISM Cleanup] OK"
            } else {
                Write-Host "  [✗] Ошибка очистки (ExitCode=$ec)." -ForegroundColor Red
                Write-Summary "[DISM Cleanup] ОШИБКА"
            }
            
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '6' { 
            $ec = Run-DISM-Analyze
            
            Write-Host ""
            if ($ec -eq 0) {
                Write-Host "  [✓] Анализ завершён." -ForegroundColor Green
                Write-Summary "[DISM Analyze] OK"
            } else {
                Write-Host "  [✗] Ошибка анализа (ExitCode=$ec)." -ForegroundColor Red
                Write-Summary "[DISM Analyze] ОШИБКА"
            }
            
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '7' { 
            Open-Folders
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '8' { 
            Show-PCInfo
            Write-Host ""
            Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        '9' { Show-Help }
        '0' {
            Write-Summary "=== Сеанс завершён ==="
            Write-Host "  Выход." -ForegroundColor Gray
            exit 0
        }
        default { Write-Host "  Неверный выбор. Введите цифру 0–9." -ForegroundColor Red }
    }
}

# =============================================================================
# ЗАПУСК
# =============================================================================

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Check-Elevated

$script:osInfo = Get-OSInfo

Write-Summary "=== Сеанс начат. $(whoami). $($script:osInfo.Caption) $($script:osInfo.Arch) ==="
Write-Summary "    Сводный лог: только итоги | Сырой лог: $rawLog"

Write-Host ""
Write-Host "  [i] Запущен от имени администратора." -ForegroundColor Cyan
Write-Host "      Пользователь : $(whoami)"
Write-Host "      ОС           : $($script:osInfo.Caption) ($($script:osInfo.Build))  $($script:osInfo.Arch)"
Write-Host "      Сводный лог  : $sessionLog"
Write-Host "      Сырой лог    : $rawLog"
Write-Host ""

do {
    Show-Menu
    $choice = (Read-Host "  Выберите действие").Trim()
    if ($choice -ne '0') {
        Invoke-Choice -Choice $choice
        Write-Host ""
        Write-Host "  Нажмите Enter для возврата в меню..." -ForegroundColor DarkGray
        Read-Host | Out-Null
    }
} while ($choice -ne '0')