<#
.SYNOPSIS
  Legal Agent Installer для Windows: запускает install.sh внутри WSL2.

.DESCRIPTION
  Проверяет наличие WSL2, при отсутствии — предлагает установить (с согласия).
  Запускает bash-установщик в WSL. Ключ DeepSeek можно передать через переменную
  окружения $env:DEEPSEEK_KEY (WSLENV) — в командную строку ключ не попадает.
  Если ключ не передан, install.sh спросит его интерактивно внутри WSL.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
  $env:DEEPSEEK_KEY = "sk-..."   # необязательно, ключ не попадёт в argv
  powershell -ExecutionPolicy Bypass -File install.ps1
#>

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
# 2. WSL2 установлен?
# ---------------------------------------------------------------------------
Write-Step "Проверяю WSL2"

$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
  Write-Warn "WSL не найден."
  Write-Host "  WSL2 ставится одной командой (потребуются права администратора и перезагрузка)."
  $answer = Read-Host "  Установить WSL2 сейчас? [y/N]"
  if ($answer -match "^(y|Y|д|Д)") {
    Write-Host "  Запускаю: wsl --install"
    wsl.exe --install 2>$null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
      Write-Warn "Не удалось запустить автоматически (нужны права администратора)."
    }
    Write-Host "`n  После установки/перезагрузки откройте PowerShell и повторите: install.ps1" -ForegroundColor Yellow
    exit 0
  } else {
    Fail "WSL2 не установлен." "Откройте PowerShell от администратора и выполните: wsl --install, затем перезагрузите ПК."
  }
}

# WSL_UTF8 заставляет wsl.exe выводить текст в UTF-8 (иначе PS 5.1 ломает кириллицу/UTF-16)
$env:WSL_UTF8 = "1"
try {
  wsl.exe --status *> $null
} catch {
  # старые сборки без --status: не критично, проверим список дистрибутивов
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
