@echo off
chcp 65001 >nul 2>&1

REM Проверка прав администратора
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Требуется права Администратора.
    echo.
    echo Запустите этот файл от имени Администратора:
    echo   Правая кнопка мыши -> Запустить от имени Администратора
    echo.
    pause
    exit /b 1
)

echo [i] Скрипт запущен от имени администратора.
echo.

REM Запуск PowerShell скрипта
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0sfc-check.ps1'"

REM Возврат в консоль после завершения PowerShell
exit /b %ERRORLEVEL%