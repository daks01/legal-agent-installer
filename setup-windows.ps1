<#
.SYNOPSIS
  Legal Agent Installer для Windows 10/11 — НАТИВНО, без WSL.

.DESCRIPTION
  Ставит окружение агента-юриста: uv, MCP-серверы (ru-legal, pravo, kad, egrul,
  laws, office-docs, sudrf-scraper), локальную базу законов (laws.db), скиллы и
  конфиг opencode. Ключи (DeepSeek, опц. api-fns) спрашиваются защищённо и в
  логи не пишутся.

  Требования: Windows 10 1809+ / Windows 11, установленный opencode.
  Повторный запуск — обновление (идемпотентен).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup-windows.ps1
  powershell -ExecutionPolicy Bypass -File setup-windows.ps1 -WithPublications
#>

param(
  [switch]$WithPublications,
  [switch]$NoDesktop,
  [switch]$Force,
  [string]$ReleaseBaseUrl = "https://github.com/daks01/legal-agent-installer/releases/latest/download",
  [string]$RepoArchiveUrl = "https://github.com/daks01/legal-agent-installer/archive/refs/heads/main.zip",
  [string]$RuLegalArchiveUrl = "https://github.com/AlsKozlov/ru-legal/archive/refs/heads/master.zip"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Write-Step { param([string]$Text) Write-Host "`n> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  + $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  ! $Text" -ForegroundColor Yellow }
function Fail {
  param([string]$Text, [string]$Hint)
  Write-Host "`nX $Text" -ForegroundColor Red
  if ($Hint) { Write-Host "  $Hint" -ForegroundColor Yellow }
  exit 1
}

function Get-PlainSecret([System.Security.SecureString]$secure) {
  if ($null -eq $secure) { return "" }
  return [System.Net.NetworkCredential]::new("", $secure).Password
}

function Save-Text([string]$Path, [string]$Text) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)  # без BOM: JSON должен парситься как есть
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Expand-Gzip([string]$Source, [string]$Destination) {
  $in  = [System.IO.File]::OpenRead($Source)
  $out = [System.IO.File]::Create($Destination)
  $gz  = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
  try { $gz.CopyTo($out) } finally { $gz.Dispose(); $out.Dispose(); $in.Dispose() }
}

# --- 0. Версия Windows -----------------------------------------------------
$ver = [System.Environment]::OSVersion.Version
$winName = "Windows $($ver.Major).$($ver.Minor) (сборка $($ver.Build))"
if ($ver.Major -lt 10) {
  Fail "$winName не поддерживается." "Нужен Windows 10 1809+ или Windows 11 (opencode работает на Bun, ему нужна современная ОС). Варианты: обновить Windows; либо агент на другой машине + доступ через opencode web."
}
if ($ver.Major -eq 10 -and $ver.Build -lt 17763) {
  Fail "$winName — слишком старая сборка." "Обновите Windows 10 (минимум 1809, рекомендуется 22H2)."
}
Write-Ok "ОС подходит: $winName"

# --- 1. opencode -----------------------------------------------------------
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
  Write-Warn "opencode не найден в PATH — сначала установите его (см. docs/windows-manual.md, шаг 1)."
} else {
  Write-Ok "opencode найден"
}

# --- 2. uv -----------------------------------------------------------------
if (Get-Command uv -ErrorAction SilentlyContinue) {
  Write-Ok "uv уже установлен: $(uv --version)"
} else {
  Write-Step "Устанавливаю uv (менеджер Python-пакетов, без прав администратора)…"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" | Out-Null
  $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Fail "uv не установился." "Повторите вручную: powershell -ExecutionPolicy Bypass -c `"irm https://astral.sh/uv/install.ps1 | iex`""
  }
  Write-Ok "uv установлен: $(uv --version)"
}
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"

# --- 2b. OpenCode Desktop (GUI) --------------------------------------------
function Install-Desktop {
  if ($NoDesktop) { Write-Warn "Пропускаю desktop-приложение (-NoDesktop)"; return }
  $installed = Test-Path (Join-Path $env:LOCALAPPDATA "Programs\opencode-desktop")
  if ($installed) { Write-Ok "OpenCode Desktop уже установлен"; return }
  if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $asset = "opencode-desktop-win-arm64.exe"
  } else {
    $asset = "opencode-desktop-win-x64.exe"
  }
  Write-Host "  Скачиваю OpenCode Desktop (~120 МБ)…"
  $exe = Join-Path $env:TEMP "opencode-desktop-setup.exe"
  Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/anomalyco/opencode/releases/latest/download/$asset" -OutFile $exe
  Write-Host "  Устанавливаю (без окна)…"
  Start-Process -Wait -FilePath $exe -ArgumentList "/S"
  Remove-Item -Force $exe -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\opencode-desktop")) {
    Write-Ok "OpenCode Desktop установлен — появится в меню Пуск (OpenCode)"
  } else {
    Write-Warn "Desktop-приложение установилось нестандартно — проверьте меню Пуск"
  }
}

# --- 2c. Установить desktop ---
Install-Desktop

# --- 3. Пути ---------------------------------------------------------------
$LegalHome = Join-Path $env:USERPROFILE ".local\share\legal-agent"
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$SkillsDir = Join-Path $ConfigDir "skills"
$KnowledgeBase = Join-Path $env:USERPROFILE "knowledge_base"
$LawData = Join-Path $LegalHome "law7-lite"
New-Item -ItemType Directory -Force -Path $LegalHome, $ConfigDir, $SkillsDir, $LawData, $KnowledgeBase | Out-Null
$LegalHomeFw = $LegalHome.Replace("\", "/")

# --- 4. Скачать репозиторий установщика -------------------------------------
Write-Step "Скачиваю файлы установщика…"
$tmp = Join-Path $env:TEMP ("legal-agent-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$repoZip = Join-Path $tmp "repo.zip"
Invoke-WebRequest -UseBasicParsing -Uri $RepoArchiveUrl -OutFile $repoZip
Expand-Archive -Path $repoZip -DestinationPath (Join-Path $tmp "src") -Force
$src = (Get-ChildItem (Join-Path $tmp "src") -Directory | Select-Object -First 1).FullName
Write-Ok "Репозиторий распакован"

# --- 5. Наши MCP-пакеты и скиллы --------------------------------------------
foreach ($pkg in @("laws", "sudrf-scraper-mcp")) {
  $dest = Join-Path $LegalHome $pkg
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Copy-Item -Recurse -Force (Join-Path $src $pkg) $dest
}
Write-Ok "MCP-пакеты разложены: laws, sudrf-scraper-mcp"

Get-ChildItem (Join-Path $src "skills") -Directory | ForEach-Object {
  Copy-Item -Recurse -Force $_.FullName (Join-Path $SkillsDir $_.Name)
}
Write-Ok "Скиллы установлены: $( (Get-ChildItem $SkillsDir -Directory | ForEach-Object { $_.Name }) -join ', ' )"

# --- 6. ru-legal (законы, скилл-паки, sub-MCP) ------------------------------
$ruLegal = Join-Path $LegalHome "ru-legal"
if (Test-Path (Join-Path $ruLegal "packs")) {
  Write-Ok "ru-legal уже установлен"
} else {
  Write-Step "Скачиваю ru-legal (законы РФ + 145 скиллов)…"
  $rlZip = Join-Path $tmp "ru-legal.zip"
  Invoke-WebRequest -UseBasicParsing -Uri $RuLegalArchiveUrl -OutFile $rlZip
  Expand-Archive -Path $rlZip -DestinationPath (Join-Path $tmp "rl") -Force
  $rlSrc = (Get-ChildItem (Join-Path $tmp "rl") -Directory | Select-Object -First 1).FullName
  if (Test-Path $ruLegal) { Remove-Item -Recurse -Force $ruLegal }
  Move-Item $rlSrc $ruLegal
  Write-Ok "ru-legal установлен"
}

# --- 7. Ключи ---------------------------------------------------------------
Write-Step "Ключи доступа"

$existingKey = ""
$existingFns = ""
if (Test-Path (Join-Path $ConfigDir "opencode.jsonc")) {
  try {
    $old = Get-Content -Raw (Join-Path $ConfigDir "opencode.jsonc") | ConvertFrom-Json
    $existingKey = $old.provider.deepseek.options.apiKey
    $existingFns = $old.mcp.egrul.environment.API_FNS_KEY
  } catch { }
}

$deepseekKey = $env:DEEPSEEK_KEY
if ([string]::IsNullOrEmpty($deepseekKey)) { $deepseekKey = $existingKey }
if ($deepseekKey -eq "ВАШ_КЛЮЧ_DEEPSEEK") { $deepseekKey = "" }
if ([string]::IsNullOrEmpty($deepseekKey)) {
  Write-Host "  Ключ DeepSeek: получите на https://platform.deepseek.com/api_keys"
  $sec = Read-Host "  Вставьте DeepSeek API Key (Enter — пропустить)" -AsSecureString
  $deepseekKey = Get-PlainSecret $sec
}
if ([string]::IsNullOrEmpty($deepseekKey)) {
  Write-Warn "Ключ DeepSeek не введён — агент не будет отвечать до его добавления в конфиг."
  $deepseekKey = "ВАШ_КЛЮЧ_DEEPSEEK"
} else {
  Write-Ok "Ключ DeepSeek получен (в лог не записан)"
}

$apiFnsKey = $env:API_FNS_KEY
if ([string]::IsNullOrEmpty($apiFnsKey)) { $apiFnsKey = $existingFns }
if ([string]::IsNullOrEmpty($apiFnsKey)) {
  Write-Host "  Опционально: проверка контрагентов (api-fns.ru, бесплатный тариф, ~100 запросов/метод)"
  $sec2 = Read-Host "  Вставьте API key api-fns.ru (Enter — пропустить)" -AsSecureString
  $apiFnsKey = Get-PlainSecret $sec2
}
if ([string]::IsNullOrEmpty($apiFnsKey)) {
  Write-Warn "api-fns не введён — MCP egrul будет выключен (можно добавить позже)"
}

# --- 8. Конфиг opencode.jsonc ----------------------------------------------
Write-Step "Пишу конфиг opencode.jsonc…"
$template = Get-Content -Raw (Join-Path $src "templates\opencode.jsonc.template")
$cfg = $template.Replace("{{DEEPSEEK_KEY}}", $deepseekKey).Replace("{{API_FNS_KEY}}", $apiFnsKey).Replace("{{LEGAL_AGENT_HOME}}", $LegalHomeFw)
if ([string]::IsNullOrEmpty($apiFnsKey)) {
  $cfg = [regex]::Replace($cfg, '(?s)("egrul":\s*\{.*?"enabled":\s*)true', '${1}false')
}
$configFile = Join-Path $ConfigDir "opencode.jsonc"
if (Test-Path $configFile) { Copy-Item -Force $configFile "$configFile.bak"; Write-Warn "Старый конфиг сохранён как opencode.jsonc.bak" }
Save-Text $configFile ($cfg.TrimEnd() + "`n")
Write-Ok "Конфиг записан: $configFile"

# --- 9. Локальная база законов ----------------------------------------------
Write-Step "База законов (laws.db)…"
$lawsDb = Join-Path $LawData "laws.db"
if ((Test-Path $lawsDb) -and (-not $Force)) {
  Write-Ok "База законов уже установлена"
} else {
  $gz = Join-Path $tmp "laws.db.gz"
  Write-Host "  Скачиваю laws.db.gz (~60 МБ)…"
  Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBaseUrl/laws.db.gz" -OutFile $gz
  Expand-Gzip $gz $lawsDb
  try {
    $shaFile = Join-Path $tmp "laws.db.sha256"
    Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBaseUrl/laws.db.sha256" -OutFile $shaFile
    $expected = (Get-Content $shaFile).Trim()
    $actual = (Get-FileHash -Algorithm SHA256 $lawsDb).Hash.ToLower()
    if ($expected -ne $actual) {
      Remove-Item -Force $lawsDb
      Fail "SHA256 базы законов не совпал." "Скачайте заново: тот же скрипт ещё раз."
    }
    Write-Ok "SHA256 базы законов совпал"
  } catch {
    if ($_.Exception.Message -like "*SHA256*") { throw }
    Write-Warn "Не удалось проверить SHA256 (продолжаю)"
  }
  Write-Ok "База законов установлена"
}

if ($WithPublications) {
  $pubDb = Join-Path $LawData "laws-publications.db"
  if (-not (Test-Path $pubDb)) {
    $gz2 = Join-Path $tmp "laws-publications.db.gz"
    Write-Host "  Скачиваю laws-publications.db.gz (~160 МБ)…"
    Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBaseUrl/laws-publications.db.gz" -OutFile $gz2
    Expand-Gzip $gz2 $pubDb
    Write-Ok "База публикаций установлена"
  } else {
    Write-Ok "База публикаций уже установлена"
  }
}

# --- 10. knowledge_base -----------------------------------------------------
foreach ($sub in @("templates", "consultant", "court_practice", "output")) {
  New-Item -ItemType Directory -Force -Path (Join-Path $KnowledgeBase $sub) | Out-Null
}
Write-Ok "Рабочая папка: $KnowledgeBase"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# --- Итог -------------------------------------------------------------------
Write-Host "`n=== Готово! ===" -ForegroundColor Green
Write-Host "  Конфиг:    $configFile"
Write-Host "  GUI:       Пуск — OpenCode (desktop)"
Write-Host "  Скиллы:    $SkillsDir"
Write-Host "  База законов: $lawsDb"
Write-Host "  Документы: $KnowledgeBase"
Write-Host ""
Write-Host "ПЕРЕЗАПУСТИТЕ opencode (конфиг читается при старте), затем проверьте:" -ForegroundColor Yellow
Write-Host "  opencode mcp list"
Write-Host "Первый запуск может занять пару минут — MCP-серверы собираются через uv."
