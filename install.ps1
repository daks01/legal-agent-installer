<#
.SYNOPSIS
  Legal Agent Installer для Windows: запускает install.sh внутри WSL2.

.DESCRIPTION
  Проверяет наличие WSL2, при отсутствии — предлагает установить (с согласия).
  Запускает bash-установщик в WSL. Ключ DeepSeek можно передать через переменную
  окружения $env:DEEPSEEK_KEY (WSLENV) — в командную строку ключ не попадает.
  Если ключ не передан, install.sh спросит его интерактивно внутри WSL.

.PARAMETER Doctor
  Только диагностика: версия Windows, виртуализация, WSL, дистрибутивы.
  Ничего не устанавливает — удобно для инвентаризации парка машин.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Doctor

.EXAMPLE
  $env:DEEPSEEK_KEY = "sk-..."   # необязательно, ключ не попадёт в argv
  powershell -ExecutionPolicy Bypass -File install.ps1
#>

param(
  [switch]$Doctor
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Step { param([string]$Text) Write-Host "`n▸ $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  ! $Text" -ForegroundColor Yellow }
function Fail {
  param([string]$Text, [string]$Hint)
  Write-Host "`n✗ $Text" -ForegroundColor Red
  if ($Hint) { Write-Host "  $Hint" -ForegroundColor Yellow }
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Платформа: только Windows
# ---------------------------------------------------------------------------
$isWindowsOs = ($env:OS -eq "Windows_NT")
if (-not $isWindowsOs) {
  Fail "install.ps1 предназначен для Windows." "На macOS/Linux запустите: bash install.sh"
}
Write-Ok "Windows определён"

# ---------------------------------------------------------------------------
# 1b. Версия Windows (WSL2 есть только на Windows 10 1903+ / Windows 11)
# ---------------------------------------------------------------------------
$osVersion = [System.Environment]::OSVersion.Version
$osBuild = $osVersion.Build
$winName = "Windows $($osVersion.Major).$($osVersion.Minor) (сборка $osBuild)"

$isWin11 = ($osVersion.Major -eq 10 -and $osBuild -ge 22000)
$isWin10 = ($osVersion.Major -eq 10 -and $osBuild -lt 22000)
$wslInstallAvailable = ($isWin11 -or ($isWin10 -and $osBuild -ge 19041))

# Версия виртуализации (для WSL2 нужна VT-x/AMD-V, часто выключена на старых ПК)
$hypervisorPresent = $null
$vtFirmware = $null
try { $hypervisorPresent = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch {}
try { $vtFirmware = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).VirtualizationFirmwareEnabled } catch {}

$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
$env:WSL_UTF8 = "1"
$distros = @()
if ($wslCmd) {
  $distros = @(wsl.exe -l -q 2>$null | Where-Object { $_ -and $_.Trim() -ne "" })
}

if ($Doctor) {
  Write-Step "Диагностика (режим -Doctor, ничего не устанавливается)"
  Write-Host "  ОС:              $winName"
  Write-Host "  Поддержка WSL2:  $(if ($wslInstallAvailable) { 'да' } elseif ($isWin10) { 'нужна ручная установка WSL (сборка < 19041)' } else { 'НЕТ (Windows 7/8/8.1 не поддерживаются)' })"
  Write-Host "  Виртуализация:   Present=$hypervisorPresent, VT/AMD-V в BIOS=$vtFirmware$(if ($vtFirmware -eq $false) { '  ← включите в BIOS!' })"
  Write-Host "  wsl.exe:         $(if ($wslCmd) { 'есть' } else { 'нет' })"
  Write-Host "  Дистрибутивы:    $(if ($distros.Count -gt 0) { $distros -join ', ' } else { 'нет' })"
  if ($wslCmd) {
    Write-Host "  Статус WSL:"
    wsl.exe --status 2>$null | ForEach-Object { Write-Host "    $_" }
  }
  Write-Host ""
  Write-Host "  Дальше: install.ps1 (установка), если ОС поддерживается." -ForegroundColor Cyan
  exit 0
}

if ($osVersion.Major -lt 10) {
  Fail "$winName не поддерживается." "WSL2 существует только на Windows 10/11. Варианты: обновить ОС; либо поставить агента на одной машине с Windows 10/11 и работать с неё. Установка остановлена."
}
if ($isWin10 -and $osBuild -lt 18362) {
  Fail "Слишком старая сборка Windows 10 ($osBuild)." "Нужна сборка 1903+ (рекомендуется 22H2: Параметры → Обновление и безопасность)."
}
Write-Ok "ОС подходит: $winName"

# ---------------------------------------------------------------------------
# 2. WSL2 установлен?
# ---------------------------------------------------------------------------
Write-Step "Проверяю WSL2"

if (-not $wslCmd) {
  Write-Warn "WSL не найден."
  if (-not $wslInstallAvailable) {
    # Windows 10 1903–2004: команды wsl --install нет, включение — вручную
    Write-Host "  На этой сборке Windows команда 'wsl --install' недоступна."
    Write-Host "  Включите WSL вручную (PowerShell от администратора):"
    Write-Host "    1. dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
    Write-Host "    2. dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
    Write-Host "    3. Перезагрузите компьютер"
    Write-Host "    4. wsl --set-default-version 2"
    Write-Host "    5. Установите Ubuntu из Microsoft Store"
    Write-Host "`n  Затем повторите: install.ps1" -ForegroundColor Yellow
    exit 1
  }
  Write-Host "  WSL2 ставится одной командой (потребуются права администратора и перезагрузка)."
  $answer = Read-Host "  Установить WSL2 сейчас? [y/N]"
  if ($answer -match "^(y|Y|д|Д)") {
    Write-Host "  Запускаю: wsl --install"
    try { wsl.exe --install 2>$null } catch { Write-Warn "Не удалось запустить автоматически." }
    Write-Host "`n  После установки/перезагрузки откройте PowerShell и повторите: install.ps1" -ForegroundColor Yellow
    exit 0
  } else {
    Fail "WSL2 не установлен." "Откройте PowerShell от администратора и выполните: wsl --install, затем перезагрузите ПК."
  }
}

$distros = @(wsl.exe -l -q 2>$null | Where-Object { $_ -and $_.Trim() -ne "" })
if ($LASTEXITCODE -ne 0 -or $distros.Count -eq 0) {
  Write-Warn "В WSL нет ни одного дистрибутива Linux."
  $answer = Read-Host "  Установить Ubuntu? [y/N]"
  if ($answer -match "^(y|Y|д|Д)") {
    Write-Host "  Запускаю: wsl --install -d Ubuntu"
    wsl.exe --install -d Ubuntu 2>$null
    Write-Host "`n  После установки/перезагрузки откройте PowerShell и повторите: install.ps1" -ForegroundColor Yellow
    exit 0
  } else {
    Fail "Нет дистрибутива WSL." "Установите с администратором: wsl --install -d Ubuntu"
  }
}
Write-Ok ("Дистрибутивы WSL: " + ($distros -join ", "))

# ---------------------------------------------------------------------------
# 3. Файлы установщика рядом со скриптом
# ---------------------------------------------------------------------------
Write-Step "Проверяю файлы установщика"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not (Test-Path (Join-Path $scriptDir "install.sh"))) {
  Fail "Рядом с install.ps1 нет install.sh." "Скачайте репозиторий legal-agent-installer целиком (install.sh, templates/, skills/, sudrf-scraper-mcp/)."
}
Write-Ok "Найден каталог установщика: $scriptDir"

# ---------------------------------------------------------------------------
# 4. Опциональная передача ключей через переменные окружения (не argv)
# ---------------------------------------------------------------------------
function Add-WslEnvVar {
  param([string]$Name)
  $current = $env:WSLENV
  if ([string]::IsNullOrEmpty($current)) {
    $env:WSLENV = $Name
  } elseif ($current -notmatch "(^|:)$([regex]::Escape($Name))(/[a-zA-Z]*)?(:|$)") {
    $env:WSLENV = "$current`:$Name"
  }
}

Write-Step "Ключи доступа"
if ($env:DEEPSEEK_KEY) {
  Add-WslEnvVar "DEEPSEEK_KEY"
  Write-Ok "Ключ DeepSeek будет передан в WSL через переменную окружения (не через командную строку)"
} else {
  Write-Warn "Ключ DeepSeek не задан в Windows — установщик спросит его интерактивно внутри WSL"
}
if ($env:API_FNS_KEY) {
  Add-WslEnvVar "API_FNS_KEY"
  Write-Ok "Ключ api-fns будет передан через переменную окружения"
}

# ---------------------------------------------------------------------------
# 5. Путь Windows → WSL и запуск install.sh
# ---------------------------------------------------------------------------
Write-Step "Запускаю установщик в WSL2"
$wslPath = (wsl.exe wslpath -a "$scriptDir" 2>$null | Out-String).Trim()
if (-not $wslPath -or $wslPath -notmatch "^/") {
  Fail "Не удалось преобразовать путь в WSL." "Проверьте, что WSL работает: wsl --status"
}
Write-Ok "Каталог в WSL: $wslPath"

Write-Host ""
& wsl.exe -- bash -c "cd '$wslPath' && exec bash install.sh"
$exitCode = $LASTEXITCODE

# ключ не оставляем в окружении этого процесса
Remove-Item Env:DEEPSEEK_KEY -ErrorAction SilentlyContinue
Remove-Item Env:API_FNS_KEY -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
  Fail "Установка завершилась с ошибкой (код $exitCode)." "Смотрите лог: $scriptDir\install.log"
}

Write-Host "`n✓ Готово!" -ForegroundColor Green
Write-Host "  Дальше — внутри WSL (запустите: wsl):"
Write-Host "    opencode mcp list   — проверить серверы"
Write-Host "    opencode            — запустить агента"
Write-Host "  Документы для агента: ~/knowledge_base (внутри WSL)"
