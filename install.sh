#!/usr/bin/env bash
#
# Legal Agent Installer — разворачивает AI-агента для юридической фирмы.
# Использование: bash install.sh   (запуск из клонированного репозитория)
#
# Документация и критерии приёмки: docs/acceptance-criteria.md
# Ключ DeepSeek и (опционально) api-fns вводятся интерактивно и никогда не логируются.

set -euo pipefail

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------
VERSION="0.1.1"
LEGAL_AGENT_HOME="${LEGAL_AGENT_HOME:-$HOME/.local/share/legal-agent}"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.jsonc"
SKILLS_DIR="$OPENCODE_CONFIG_DIR/skills"
KNOWLEDGE_BASE="$HOME/knowledge_base"
LOG_FILE="${INSTALL_LOG_DIR:-$PWD}/install.log"

RU_LEGAL_REPO="https://github.com/AlsKozlov/ru-legal.git"
RU_LEGAL_DIR="$LEGAL_AGENT_HOME/ru-legal"
SUDRF_MCP_DIR="$LEGAL_AGENT_HOME/sudrf-scraper-mcp"
SUDRF_APP_DIR="$LEGAL_AGENT_HOME/sudrfscraper"
LAWS_DIR="$LEGAL_AGENT_HOME/laws"
LAWS_DATA_DIR="$LEGAL_AGENT_HOME/law7-lite"
SUDRF_RELEASE_TAG="v0.3.0.3"
GECKODRIVER_VERSION="v0.37.1"

# Базовый URL релиза для скачивания артефактов (laws.db.gz и т.п.).
# Заполняется на Этапе 6 (GitHub Release); можно переопределить окружением.
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/daks01/legal-agent-installer/releases/latest/download}"
# Источник базы законов для тестов/офлайн-установки: путь к laws.db.gz (или URL).
LAWS_DB_SRC="${LAWS_DB_SRC:-}"
WITH_PUBLICATIONS="${WITH_PUBLICATIONS:-0}"
WITH_RUSLAW="${WITH_RUSLAW:-0}"
INSTALL_DESKTOP="${INSTALL_DESKTOP:-1}"

# Тестовый/неинтерактивный режим: ключи можно передать через переменные окружения
DEEPSEEK_KEY="${DEEPSEEK_KEY:-}"
API_FNS_KEY="${API_FNS_KEY:-}"
FORCE="${FORCE:-0}"   # FORCE=1 — переустановить sudrfscraper заново

# ---------------------------------------------------------------------------
# Пути ресурсов (скрипт запускается из клонированного репозитория)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_LOG_DIR="${INSTALL_LOG_DIR:-$PWD}"
TEMPLATE_FILE="$SCRIPT_DIR/templates/opencode.jsonc.template"
SKILL_SRC="$SCRIPT_DIR/skills/source-locked-ru"
SUDRF_MCP_SRC="$SCRIPT_DIR/sudrf-scraper-mcp"
RULES_SRC="$SCRIPT_DIR/rules/AGENTS.md"

# ---------------------------------------------------------------------------
# Цвета и логирование (лог — без цветовых кодов и без секретов)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
step() { printf '\n%s▸ Шаг %s: %s%s\n' "$BOLD" "$1" "$2" "$NC"; log "Шаг $1: $2"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$NC" "$1"; log "  ✓ $1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$1"; log "  ! $1"; }
note() { printf '  %s•%s %s\n' "$BLUE" "$NC" "$1"; log "  • $1"; }

# Есть ли управляющий терминал (важно для curl|bash и неинтерактивных запусков)
HAS_TTY=""
{ : > /dev/tty; } 2>/dev/null && HAS_TTY=1
tty_print() { [ -n "$HAS_TTY" ] && printf '%s' "$1" > /dev/tty || true; }
tty_newline() { [ -n "$HAS_TTY" ] && printf '\n' > /dev/tty || true; }

fail() {
  printf '\n  %s✗ %s%s\n' "$RED" "$1" "$NC" >&2
  log "  ✗ $1"
  if [ -n "${2:-}" ]; then
    printf '    %s\n' "$2" >&2
    log "    $2"
  fi
  printf '\n%sУстановка прервана.%s Лог: %s\n' "$RED" "$NC" "$LOG_FILE" >&2
  exit 1
}

trap 'fail "Непредвиденная ошибка (строка $LINENO). Смотри $LOG_FILE"' ERR

# ---------------------------------------------------------------------------
# Вспомогательные проверки
# ---------------------------------------------------------------------------
require_resources() {
  [ -f "$TEMPLATE_FILE" ] || fail "Не найден шаблон конфига: $TEMPLATE_FILE" \
    "Запускай install.sh из клонированного репозитория legal-agent-installer."
  [ -f "$SKILL_SRC/SKILL.md" ] || fail "Не найден скилл: $SKILL_SRC/SKILL.md" \
    "Репозиторий повреждён — скачай его заново."
  [ -f "$SUDRF_MCP_SRC/pyproject.toml" ] || fail "Не найден sudrf-scraper-mcp: $SUDRF_MCP_SRC" \
    "Репозиторий повреждён — скачай его заново."
  [ -f "$SCRIPT_DIR/laws/pyproject.toml" ] || fail "Не найден laws (law7-lite): $SCRIPT_DIR/laws" \
    "Репозиторий повреждён — скачай его заново."
  [ -f "$RULES_SRC" ] || fail "Не найдены глобальные правила: $RULES_SRC" \
    "Репозиторий повреждён — скачай его заново."
}

check_network() {
  curl -fsS --max-time 15 -o /dev/null https://pypi.org/ 2>/dev/null \
    || fail "Нет доступа к интернету (pypi.org не отвечает)." \
      "Проверь соединение и повтори запуск: bash install.sh"
}

detect_os() {
  OS="unknown"
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *) fail "Неподдерживаемая ОС: $(uname -s)." \
         "Поддерживаются macOS и Linux (включая WSL2). Windows — через install.ps1." ;;
  esac
  if [ "$OS" = "linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then
    os_hint="Ubuntu в WSL2"
  elif [ "$OS" = "macos" ]; then
    os_hint="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
  else
    os_hint="Linux"
  fi
  ok "ОС: $os_hint"
}

# ---------------------------------------------------------------------------
# Шаг 1. Базовые инструменты и PATH
# ---------------------------------------------------------------------------
check_system_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    if [ "$OS" = "macos" ]; then
      fail "Не найден curl." "Он входит в macOS — возможно, повреждён PATH. Проверь: echo \$PATH"
    else
      fail "Не найден curl." "Установи: sudo apt install -y curl"
    fi
  fi
  if ! command -v git >/dev/null 2>&1; then
    if [ "$OS" = "macos" ]; then
      fail "Не найден git." "Установи инструменты разработчика: xcode-select --install"
    else
      fail "Не найден git." "Установи: sudo apt install -y git"
    fi
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    if [ "$OS" = "macos" ]; then
      fail "Не найден unzip." "Он входит в macOS — проверь PATH."
    else
      fail "Не найден unzip." "Установи: sudo apt install -y unzip"
    fi
  fi
  ok "curl, git и unzip на месте"

  mkdir -p "$LEGAL_AGENT_HOME"
  export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    ok "uv уже установлен: $(uv --version)"
  else
    note "Устанавливаю uv (менеджер Python-пакетов, без sudo)…"
    curl -LsSf https://astral.sh/uv/install.sh | sh >>"$LOG_FILE" 2>&1 \
      || fail "Не удалось установить uv." "Повтори вручную: curl -LsSf https://astral.sh/uv/install.sh | sh"
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || fail "uv установлен, но не найден в PATH." \
      "Добавь в ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\" и перезапусти терминал."
    ok "uv установлен: $(uv --version)"
  fi
  command -v uvx >/dev/null 2>&1 || fail "uvx не найден после установки uv." \
    "Добавь в ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\" и перезапусти терминал."
}

install_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    ok "opencode уже установлен: $(opencode --version 2>/dev/null || echo 'есть')"
    return
  fi
  note "Устанавливаю OpenCode (официальный установщик, без sudo)…"
  curl -fsSL https://opencode.ai/install | bash >>"$LOG_FILE" 2>&1 \
    || fail "Не удалось установить OpenCode." "Повтори вручную: curl -fsSL https://opencode.ai/install | bash"
  export PATH="$HOME/.opencode/bin:$PATH"
  command -v opencode >/dev/null 2>&1 || fail "opencode установлен, но не найден в PATH." \
    "Добавь в ~/.zshrc: export PATH=\"\$HOME/.opencode/bin:\$PATH\" и перезапусти терминал."
  ok "opencode установлен: $(opencode --version 2>/dev/null || echo 'есть')"
}

# ---------------------------------------------------------------------------
# Шаг 1b. OpenCode Desktop (GUI-приложение)
# ---------------------------------------------------------------------------
DESKTOP_URL_BASE="https://github.com/anomalyco/opencode/releases/latest/download"

install_desktop() {
  if [ "$INSTALL_DESKTOP" != "1" ]; then
    note "Пропускаю десктоп-приложение (--no-desktop)"
    return
  fi
  local asset
  if [ "$OS" = "macos" ]; then
    if [ "$(uname -m)" = "arm64" ]; then asset="opencode-desktop-mac-arm64.zip"; else asset="opencode-desktop-mac-x64.zip"; fi
    local app_dir="${MACOS_APP_DIR:-/Applications}"
    if [ -d "$app_dir/OpenCode.app" ]; then
      ok "OpenCode Desktop уже установлен: $app_dir/OpenCode.app"
      return
    fi
    if [ ! -w "$app_dir" ]; then
      app_dir="$HOME/Applications"
      mkdir -p "$app_dir"
      note "Нет доступа на запись в /Applications — ставлю в ~/Applications"
    fi
    note "Скачиваю OpenCode Desktop (~140 МБ)…"
    local tmp; tmp="$(mktemp -d)"
    if curl -L --fail --silent --show-error -o "$tmp/app.zip" "$DESKTOP_URL_BASE/$asset" >>"$LOG_FILE" 2>&1 \
       && unzip -q "$tmp/app.zip" -d "$tmp"; then
      local app; app="$(find "$tmp" -maxdepth 2 -name "*.app" -type d | head -1)"
      if [ -n "$app" ]; then
        rm -rf "$app_dir/$(basename "$app")"
        cp -R "$app" "$app_dir/"
        xattr -dr com.apple.quarantine "$app_dir/$(basename "$app")" 2>/dev/null || true
        ok "OpenCode Desktop установлен: $app_dir/$(basename "$app")"
      else
        warn "В архиве desktop-приложения нет .app — пропускаю"
      fi
    else
      warn "Не удалось скачать desktop-приложение (агент в терминале всё равно работает)"
    fi
    rm -rf "$tmp"
  elif [ "$OS" = "linux" ]; then
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
      asset="opencode-desktop-linux-arm64.AppImage"
    else
      asset="opencode-desktop-linux-x86_64.AppImage"
    fi
    local dir="$LEGAL_AGENT_HOME/opencode-desktop"
    local appimg="$dir/OpenCode.AppImage"
    if [ -f "$appimg" ]; then
      ok "OpenCode Desktop уже установлен: $appimg"
      return
    fi
    mkdir -p "$dir"
    note "Скачиваю OpenCode Desktop (~150 МБ)…"
    if curl -L --fail --silent --show-error -o "$appimg" "$DESKTOP_URL_BASE/$asset" >>"$LOG_FILE" 2>&1; then
      chmod +x "$appimg"
      mkdir -p "$HOME/.local/share/applications"
      cat > "$HOME/.local/share/applications/opencode-desktop.desktop" <<DESKTOP_EOF
[Desktop Entry]
Name=OpenCode
Comment=AI-агент юриста (OpenCode Desktop)
Exec=$appimg
Terminal=false
Type=Application
Categories=Utility;Office;
DESKTOP_EOF
      ok "OpenCode Desktop установлен (AppImage + ярлык в меню приложений)"
    else
      warn "Не удалось скачать desktop-приложение (агент в терминале всё равно работает)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Шаг 2. Ключи (не логируются)
# ---------------------------------------------------------------------------
prompt_secret() {
  # $1 — текст приглашения; читает с /dev/tty (важно для curl|bash), не эхоит.
  # Если tty нет (неинтерактивный запуск) — НЕ читает stdin: под curl|bash там
  # текст самого скрипта, а не ввод пользователя.
  local prompt="$1" value=""
  if [ -n "$HAS_TTY" ]; then
    tty_print "$prompt"
    IFS= read -rs value < /dev/tty || true
    tty_newline
  elif [ -t 0 ]; then
    IFS= read -rs value || true
  fi
  printf '%s' "$value"
}

ask_keys() {
  if [ -z "$DEEPSEEK_KEY" ]; then
    note "Ключ DeepSeek: получить можно на https://platform.deepseek.com/api_keys"
    DEEPSEEK_KEY="$(prompt_secret 'Вставьте DeepSeek API Key (Enter — пропустить): ')"
  fi
  if [ -n "$DEEPSEEK_KEY" ]; then
    ok "Ключ DeepSeek получен (в лог не записан)"
  else
    warn "Ключ DeepSeek не введён."
    note "Агент не сможет отвечать до добавления ключа. Позже: открой $OPENCODE_CONFIG_FILE и замени {{ВАШ_КЛЮЧ}}."
    DEEPSEEK_KEY="ВАШ_КЛЮЧ_DEEPSEEK"
  fi

  if [ -z "$API_FNS_KEY" ]; then
    tty_newline
    note "Опционально: проверка контрагентов в ЕГРЮЛ (api-fns.ru)."
    note "Бесплатный тариф: ~100 запросов на метод, доступ с одного IP. Регистрация: https://api-fns.ru"
    API_FNS_KEY="$(prompt_secret 'Вставьте API key api-fns.ru (Enter — пропустить): ')"
  fi
  if [ -n "$API_FNS_KEY" ]; then
    ok "Ключ api-fns получен (в лог не записан)"
  else
    warn "Ключ api-fns не введён — MCP egrul будет выключен (можно включить позже в конфиге)"
  fi
}

# ---------------------------------------------------------------------------
# Шаг 3. Конфиг opencode.jsonc
# ---------------------------------------------------------------------------
render_config() {
  local rendered
  rendered="$(sed -e "s|{{DEEPSEEK_KEY}}|$DEEPSEEK_KEY|g" \
                  -e "s|{{LEGAL_AGENT_HOME}}|$LEGAL_AGENT_HOME|g" \
                  -e "s|{{API_FNS_KEY}}|$API_FNS_KEY|g" \
                  "$TEMPLATE_FILE")"
  if [ -z "$API_FNS_KEY" ]; then
    # выключить egrul, если ключа нет (диапазон от блока "egrul" до его "enabled": true)
    rendered="$(printf '%s\n' "$rendered" | sed '/"egrul": {/,/"enabled": true/ s/"enabled": true/"enabled": false/')"
  fi
  printf '%s\n' "$rendered"
}

write_config() {
  mkdir -p "$OPENCODE_CONFIG_DIR"
  local rendered; rendered="$(render_config)"

  if [ -f "$OPENCODE_CONFIG_FILE" ]; then
    if [ "$(cat "$OPENCODE_CONFIG_FILE")" = "$rendered" ]; then
      ok "opencode.jsonc уже актуален — не трогаю"
      return
    fi
    cp "$OPENCODE_CONFIG_FILE" "$OPENCODE_CONFIG_FILE.bak"
    warn "Существующий конфиг сохранён как opencode.jsonc.bak"
  fi
  printf '%s\n' "$rendered" > "$OPENCODE_CONFIG_FILE"
  ok "Конфиг записан: $OPENCODE_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Шаг 4. Скилл source-locked-ru
# ---------------------------------------------------------------------------
install_skill() {
  mkdir -p "$SKILLS_DIR"
  local skill_dir
  for skill_dir in "$SCRIPT_DIR"/skills/*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    local name; name="$(basename "$skill_dir")"
    mkdir -p "$SKILLS_DIR/$name"
    cp "$skill_dir/SKILL.md" "$SKILLS_DIR/$name/SKILL.md"
    ok "Скилл установлен: $name"
  done
}

install_global_rules() {
  # Глобальные правила opencode: ~/.config/opencode/AGENTS.md — применяются
  # автоматически в любой папке (см. docs/rules у opencode).
  local dest="$OPENCODE_CONFIG_DIR/AGENTS.md"
  mkdir -p "$OPENCODE_CONFIG_DIR"
  if [ ! -f "$dest" ]; then
    cp "$RULES_SRC" "$dest"
    ok "Глобальные правила установлены: $dest"
  elif cmp -s "$RULES_SRC" "$dest"; then
    ok "Глобальные правила уже актуальны"
  else
    cp "$dest" "$dest.bak"
    cp "$RULES_SRC" "$dest"
    warn "Ваш AGENTS.md сохранён как AGENTS.md.bak, установлены правила агента"
  fi
}

# ---------------------------------------------------------------------------
# Шаг 5. MCP-серверы
# ---------------------------------------------------------------------------
clone_ru_legal() {
  if [ -d "$RU_LEGAL_DIR/.git" ]; then
    note "ru-legal уже склонирован — обновляю (git pull)…"
    if git -C "$RU_LEGAL_DIR" pull --ff-only -q >>"$LOG_FILE" 2>&1; then
      ok "ru-legal обновлён"
    else
      warn "Не удалось обновить ru-legal (git pull). Использую текущую версию."
    fi
  else
    note "Клонирую ru-legal (законы РФ + скиллы, Apache-2.0)…"
    rm -rf "$RU_LEGAL_DIR"
    git clone --depth 1 -q "$RU_LEGAL_REPO" "$RU_LEGAL_DIR" >>"$LOG_FILE" 2>&1 \
      || fail "Не удалось склонировать ru-legal." "Проверь доступ к github.com и повтори."
    ok "ru-legal склонирован в $RU_LEGAL_DIR"
  fi
}

copy_sudrf_mcp() {
  rm -rf "$SUDRF_MCP_DIR"
  mkdir -p "$SUDRF_MCP_DIR"
  cp -R "$SUDRF_MCP_SRC/." "$SUDRF_MCP_DIR/"
  rm -rf "$SUDRF_MCP_DIR/.ruff_cache" "$SUDRF_MCP_DIR/src"/*/__pycache__ 2>/dev/null || true
  # uvx кэширует локальные сборки — после обновления чистим кэш пакета
  uv cache clean sudrf-scraper-mcp >>"$LOG_FILE" 2>&1 || true
  ok "sudrf-scraper-mcp разложен в $SUDRF_MCP_DIR"
}

copy_laws_mcp() {
  rm -rf "$LAWS_DIR"
  mkdir -p "$LAWS_DIR"
  cp -R "$SCRIPT_DIR/laws/." "$LAWS_DIR/"
  rm -rf "$LAWS_DIR/.ruff_cache" "$LAWS_DIR/src"/*/__pycache__ "$LAWS_DIR/build"/*/__pycache__ 2>/dev/null || true
  uv cache clean laws-mcp >>"$LOG_FILE" 2>&1 || true
  ok "laws-mcp разложен в $LAWS_DIR"
}

install_laws_data() {
  local name="laws.db" src_gz="" got=0
  if [ -f "$LAWS_DATA_DIR/$name" ]; then
    ok "База законов уже установлена: $LAWS_DATA_DIR/$name"
    got=1
  else
    mkdir -p "$LAWS_DATA_DIR"
    if [ -n "$LAWS_DB_SRC" ] && [ -f "$LAWS_DB_SRC" ]; then
      gunzip -c "$LAWS_DB_SRC" > "$LAWS_DATA_DIR/$name" && got=1
      note "База законов взята из LAWS_DB_SRC=$LAWS_DB_SRC"
    elif [ -f "$SCRIPT_DIR/laws/laws.db.gz" ]; then
      gunzip -c "$SCRIPT_DIR/laws/laws.db.gz" > "$LAWS_DATA_DIR/$name" && got=1
      note "База законов взята из локального артефакта репозитория"
    elif [ -n "$RELEASE_BASE_URL" ]; then
      note "Скачиваю базу законов (~60 МБ)…"
      if curl -fL --silent --show-error "$RELEASE_BASE_URL/$name.gz" | gunzip -c > "$LAWS_DATA_DIR/$name"; then
        got=1
        if curl -fsL "$RELEASE_BASE_URL/$name.sha256" -o "$LAWS_DATA_DIR/.expected_sha" 2>/dev/null; then
          local actual; actual="$(shasum -a 256 "$LAWS_DATA_DIR/$name" 2>/dev/null | awk '{print $1}')"
          if [ "$actual" != "$(cat "$LAWS_DATA_DIR/.expected_sha")" ]; then
            warn "SHA256 базы законов не совпал — удаляю повреждённый файл"
            rm -f "$LAWS_DATA_DIR/$name"; got=0
          fi
          rm -f "$LAWS_DATA_DIR/.expected_sha"
        fi
      fi
    fi
    [ "$got" = "1" ] && ok "База законов установлена: $LAWS_DATA_DIR/$name"
  fi

  if [ "$got" = "1" ] && [ "$WITH_PUBLICATIONS" = "1" ] && [ ! -f "$LAWS_DATA_DIR/laws-publications.db" ] && [ -n "$RELEASE_BASE_URL" ]; then
    note "Скачиваю базу публикаций (~160 МБ)…"
    if curl -fL --silent --show-error "$RELEASE_BASE_URL/laws-publications.db.gz" | gunzip -c > "$LAWS_DATA_DIR/laws-publications.db"; then
      ok "База публикаций установлена"
    else
      warn "База публикаций не скачалась (опциональный компонент)"
    fi
  fi

  if [ "$got" = "1" ] && [ "$WITH_RUSLAW" = "1" ] && [ ! -f "$LAWS_DATA_DIR/ruslaw.db" ] && [ -n "$RELEASE_BASE_URL" ]; then
    note "Скачиваю полный корпус законов RusLawOD (~1.1 ГБ)…"
    if curl -fL --silent --show-error "$RELEASE_BASE_URL/ruslaw.db.gz" | gunzip -c > "$LAWS_DATA_DIR/ruslaw.db"; then
      if curl -fsL "$RELEASE_BASE_URL/ruslaw.db.sha256" -o "$LAWS_DATA_DIR/.expected_sha" 2>/dev/null; then
        actual_rus="$(shasum -a 256 "$LAWS_DATA_DIR/ruslaw.db" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_rus" != "$(cat "$LAWS_DATA_DIR/.expected_sha")" ]; then
          warn "SHA256 корпуса RusLawOD не совпал — удаляю повреждённый файл"
          rm -f "$LAWS_DATA_DIR/ruslaw.db"
        fi
        rm -f "$LAWS_DATA_DIR/.expected_sha"
      fi
      [ -f "$LAWS_DATA_DIR/ruslaw.db" ] && ok "Корпус RusLawOD установлен (310 тыс. актов 1991–2026)"
    else
      warn "Корпус RusLawOD не скачался (опциональный компонент)"
    fi
  fi

  if [ "$got" != "1" ]; then
    warn "База законов (laws) не загружена: MCP laws будет выключен."
    note "Установить позже: bash update-laws.sh (или перезапустить install.sh после релиза)."
    if [ -f "$OPENCODE_CONFIG_FILE" ]; then
      sed -i.bak '/"laws": {/,/"enabled": true/ s/"enabled": true/"enabled": false/' "$OPENCODE_CONFIG_FILE"
      rm -f "$OPENCODE_CONFIG_FILE.bak"
      note "MCP laws выключен в конфиге (enabled: false)"
    fi
  fi
}

check_mcp_servers() {
  local ok_count=0
  local total=7
  local checks=(
    "ru-legal-mcp|$RU_LEGAL_DIR/mcps/ru-legal-aggregator|ru_legal_mcp"
    "pravo-mcp|$RU_LEGAL_DIR/mcps/pravo|pravo_mcp"
    "kad-mcp|$RU_LEGAL_DIR/mcps/kad|kad_mcp"
    "egrul-mcp|$RU_LEGAL_DIR/mcps/egrul|egrul_mcp"
    "sudrf-scraper-mcp|$SUDRF_MCP_DIR|sudrf_scraper_mcp"
    "laws-mcp|$LAWS_DIR|laws_mcp"
  )
  for entry in "${checks[@]}"; do
    IFS='|' read -r name dir module <<<"$entry"
    note "Проверяю $name (первый запуск может занять минуту)…"
    if uvx --from "$dir" python -c "import $module" >>"$LOG_FILE" 2>&1; then
      ok "$name — готов"
      ok_count=$((ok_count + 1))
    else
      warn "$name — не собрался. Подробности: $LOG_FILE"
    fi
  done
  if uvx --from office-docs-mcp python -c "import office_docs_mcp" >>"$LOG_FILE" 2>&1; then
    ok "office-docs-mcp — готов"
    ok_count=$((ok_count + 1))
  else
    warn "office-docs-mcp — не установился. Проверь интернет и повтори запуск."
  fi
  ok "MCP-серверы готовы: $ok_count из $total"
}

# ---------------------------------------------------------------------------
# Шаг 6. sudrfscraper (судебная практика), macOS/Linux
# ---------------------------------------------------------------------------
sudrf_release_zip() {
  case "$OS" in
    macos) echo "macOS-x64.sudrfscraper.zip" ;;
    linux) echo "linux-x64.sudrfscraper.zip" ;;
  esac
}

install_sudrfscraper() {
  if [ -f "$SUDRF_APP_DIR/run.sh" ] && [ "$FORCE" != "1" ]; then
    ok "sudrfscraper уже установлен: $SUDRF_APP_DIR"
    note "Переустановить: FORCE=1 bash install.sh"
    patch_court_configs
    return
  fi

  local zip_name tmp_dir url
  zip_name="$(sudrf_release_zip)"
  url="https://github.com/tochno-st/sudrfscraper/releases/download/$SUDRF_RELEASE_TAG/$zip_name"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir:-}" || true' RETURN

  note "Скачиваю sudrfscraper ($SUDRF_RELEASE_TAG, ~190 МБ)…"
  curl -L --fail --silent --show-error -o "$tmp_dir/app.zip" "$url" >>"$LOG_FILE" 2>&1 \
    || fail "Не удалось скачать sudrfscraper." "Проверь доступ к github.com и повтори запуск."

  note "Распаковываю…"
  unzip -q "$tmp_dir/app.zip" -d "$tmp_dir/app" || fail "Не удалось распаковать архив sudrfscraper."
  local inner; inner="$(find "$tmp_dir/app" -maxdepth 1 -mindepth 1 -type d | head -1)"
  rm -rf "$SUDRF_APP_DIR"
  mkdir -p "$SUDRF_APP_DIR"
  cp -R "$inner/." "$SUDRF_APP_DIR/"

  if [ "$OS" = "macos" ]; then
    fix_geckodriver_macos
    xattr -dr com.apple.quarantine "$SUDRF_APP_DIR" 2>/dev/null || true
  fi
  chmod +x "$SUDRF_APP_DIR/run.sh" "$SUDRF_APP_DIR/src/main/resources/"*/geckodriver 2>/dev/null || true
  chmod +x "$SUDRF_APP_DIR/jre/Home/bin/java" "$SUDRF_APP_DIR/jre/bin/java" 2>/dev/null || true

  patch_court_configs
  ok "sudrfscraper установлен: $SUDRF_APP_DIR"

  check_firefox
}

fix_geckodriver_macos() {
  # В релизе под macOS лежит Linux-бинарник geckodriver (баг упаковки).
  local driver="$SUDRF_APP_DIR/src/main/resources/macOS/geckodriver"
  local asset="geckodriver-$GECKODRIVER_VERSION-macos.tar.gz"
  note "Заменяю встроенный geckodriver на официальный ($GECKODRIVER_VERSION)…"
  local tmp; tmp="$(mktemp -d)"
  if curl -L --fail --silent --show-error -o "$tmp/gd.tgz" \
      "https://github.com/mozilla/geckodriver/releases/download/$GECKODRIVER_VERSION/$asset" >>"$LOG_FILE" 2>&1 \
      && tar xzf "$tmp/gd.tgz" -C "$tmp"; then
    cp "$tmp/geckodriver" "$driver"
    chmod +x "$driver"
    xattr -c "$driver" 2>/dev/null || true
    ok "geckodriver заменён на официальный"
  else
    warn "Не удалось скачать geckodriver — sudrf-скрапер на macOS не заработает."
    note "Вручную: https://github.com/mozilla/geckodriver/releases → заменить src/main/resources/macOS/geckodriver"
  fi
  rm -rf "$tmp"
}

patch_court_configs() {
  # Сайты судов перешли на https и сменили домены: X--reg.sudrf.ru → X.reg.sudrf.ru.
  # Оставляем http:// (так обе ветки приложения получают корректный Host-заголовок).
  # Подробности: NOTES.md п. 6.
  local cfg_dir="$SUDRF_APP_DIR/src/main/resources/config"
  [ -d "$cfg_dir" ] || return 0
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    python3 - "$cfg_dir" <<'PYEOF' >>"$LOG_FILE" 2>&1 || warn "Не удалось пропатчить конфиги судов (python3)."
import json, sys, pathlib
cfg_dir = pathlib.Path(sys.argv[1])
for path in cfg_dir.glob("config_*.json"):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(data, list):
        continue
    changed = 0
    for court in data:
        value = court.get("searchString")
        if not value or "sudrf.ru" not in value:
            continue
        host = value.split("://", 1)[-1]
        new_host = host.replace("--", ".")
        new_value = "http://" + new_host
        if new_value != value:
            court["searchString"] = new_value
            changed += 1
    if changed:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
PYEOF
    ok "Конфиги судов пропатчены (канонические домены)"
  else
    warn "python3 недоступен — патч конфигов судов пропущен (sudrf может не собирать данные)."
  fi
}

check_firefox() {
  if [ "$OS" = "macos" ]; then
    if [ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ] || command -v firefox >/dev/null 2>&1; then
      ok "Firefox найден"
      return
    fi
  elif command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1; then
    ok "Firefox найден"
    return
  fi
  warn "Firefox не найден — сбор судебной практики (sudrf) работать не будет."
  if [ "$OS" = "macos" ]; then
    note "Установи Firefox: https://www.mozilla.org/firefox/new/ (или: npx playwright install firefox)"
  else
    note "Установи Firefox: sudo apt install -y firefox (или: npx playwright install firefox)"
  fi
}

# ---------------------------------------------------------------------------
# Шаг 7. Рабочая папка knowledge_base
# ---------------------------------------------------------------------------
create_knowledge_base() {
  mkdir -p "$KNOWLEDGE_BASE/court_practice" "$KNOWLEDGE_BASE/consultant" \
           "$KNOWLEDGE_BASE/templates" "$KNOWLEDGE_BASE/output"
  ok "Рабочая папка: $KNOWLEDGE_BASE (court_practice, consultant, templates, output)"
}

# ---------------------------------------------------------------------------
# Итоговый чек-лист
# ---------------------------------------------------------------------------
summary() {
  printf '\n%s%s Установка завершена!%s\n' "$BOLD" "$GREEN" "$NC"
  printf '\n%sЧто установлено:%s\n' "$BOLD" "$NC"
  printf '  ✓ OpenCode:      %s\n' "$(command -v opencode 2>/dev/null || echo "$HOME/.opencode/bin/opencode")"
  if [ "$INSTALL_DESKTOP" = "1" ]; then
    printf '  ✓ OpenCode GUI:  %s\n' "$([ -d "/Applications/OpenCode.app" ] && echo '/Applications/OpenCode.app' || { [ -d "$HOME/Applications/OpenCode.app" ] && echo "$HOME/Applications/OpenCode.app"; } || echo "AppImage: $LEGAL_AGENT_HOME/opencode-desktop/OpenCode.AppImage")"
  fi
  printf '  ✓ uv:            %s\n' "$(command -v uv 2>/dev/null || echo '~/.local/bin/uv')"
  printf '  ✓ Конфиг:        %s\n' "$OPENCODE_CONFIG_FILE"
  printf '  ✓ Скиллы:        %s\n' "$SKILLS_DIR"
  printf '  ✓ Правила:       %s\n' "$OPENCODE_CONFIG_DIR/AGENTS.md"
  printf '  ✓ MCP-серверы:   ru-legal, pravo, kad, egrul%s, laws%s, office-docs, sudrf-scraper\n' \
    "$([ -n "$API_FNS_KEY" ] && echo '' || echo ' (выключен)')" \
    "$([ -f "$LAWS_DATA_DIR/laws.db" ] && echo '' || echo ' (выключен — нет базы)')"
  printf '  ✓ База законов:  %s\n' \
    "$([ -f "$LAWS_DATA_DIR/laws.db" ] && echo "$LAWS_DATA_DIR/laws.db (снапшот; обновление: update-laws.sh)" || echo 'не загружена')"
  printf '  ✓ Корпус актов:  %s\n' \
    "$([ -f "$LAWS_DATA_DIR/ruslaw.db" ] && echo "$LAWS_DATA_DIR/ruslaw.db (RusLawOD 1991–2026, pet-проект)" || echo 'не установлен (--with-ruslaw)')"
  printf '  ✓ Публикации:    %s\n' \
    "$([ -f "$LAWS_DATA_DIR/laws-publications.db" ] && echo 'установлены' || echo 'не установлены (--with-publications)')"
  printf '  ✓ База знаний:   %s\n' "$KNOWLEDGE_BASE"

  printf '\n%sЧто дальше:%s\n' "$BOLD" "$NC"
  printf '  1. Проверь серверы:  opencode mcp list\n'
  printf '  2. Запусти агента:   opencode\n'
  printf '  3. Примеры запросов — в README.md; документы клади в %s\n' "$KNOWLEDGE_BASE"

  if [ "$DEEPSEEK_KEY" = "ВАШ_КЛЮЧ_DEEPSEEK" ]; then
    printf '\n  %s!%s Ключ DeepSeek не введён: вставь его в %s (замени ВАШ_КЛЮЧ_DEEPSEEK)\n' \
      "$YELLOW" "$NC" "$OPENCODE_CONFIG_FILE"
  fi
  if ! command -v firefox >/dev/null 2>&1 && [ ! -x "/Applications/Firefox.app/Contents/MacOS/firefox" ]; then
    printf '  %s!%s Firefox не найден — sudrf-практика не соберётся, пока не установишь Firefox\n' "$YELLOW" "$NC"
  fi
  printf '  %s!%s Сбор судебной практики требует российского IP и ввода капчи в браузере (http://localhost:8080)\n' \
    "$YELLOW" "$NC"

  printf '\nПолный лог: %s\n\n' "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  for arg in "$@"; do
    case "$arg" in
      --with-publications) WITH_PUBLICATIONS=1 ;;
      --with-ruslaw) WITH_RUSLAW=1 ;;
      --no-desktop) INSTALL_DESKTOP=0 ;;
      --help|-h)
        printf 'Использование: bash install.sh [--with-publications]\n'
        printf '  --with-publications — дополнительно скачать базу публикаций pravo.gov.ru (~160 МБ)\n'
        printf '  --no-desktop        — не ставить десктоп-приложение (GUI)\n'
        printf '  --with-ruslaw       — скачать полный корпус законов RusLawOD (~1.1 ГБ)\n'
        exit 0
        ;;
    esac
  done

  # Запуск через curl|bash (или из папки без файлов): скачиваем репозиторий и
  # перезапускаемся из него.
  if [ ! -f "$TEMPLATE_FILE" ]; then
    note "Скачиваю файлы установщика с GitHub…"
    local bootstrap_dir inner
    bootstrap_dir="$(mktemp -d)"
    if ! curl -fsSL "https://github.com/daks01/legal-agent-installer/archive/refs/heads/main.tar.gz" | tar xz -C "$bootstrap_dir"; then
      fail "Не удалось скачать файлы установщика." \
        "Проверь интернет или поставь вручную: git clone https://github.com/daks01/legal-agent-installer && cd legal-agent-installer && bash install.sh"
    fi
    inner="$(find "$bootstrap_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -n "$inner" ] || fail "Архив установщика пуст."
    cd "$inner"
    exec env INSTALL_LOG_DIR="$INSTALL_LOG_DIR" bash install.sh "$@"
  fi

  : > "$LOG_FILE"
  printf '%sLegal Agent Installer %s%s — разворачиваю агента-юриста.\n' "$BOLD" "$VERSION" "$NC"
  log "Legal Agent Installer $VERSION — старт"

  step 1 "Проверка системы"
  detect_os
  require_resources
  check_network
  check_system_tools
  install_uv
  install_opencode
  install_desktop

  step 2 "Ключи доступа (DeepSeek, опционально api-fns)"
  ask_keys

  step 3 "Конфигурация OpenCode"
  write_config

  step 4 "Скиллы и глобальные правила"
  install_skill
  install_global_rules

  step 5 "MCP-серверы (законы, практика, документы, контрагенты)"
  clone_ru_legal
  copy_sudrf_mcp
  copy_laws_mcp

  step 6 "Локальная база законов (law7-lite, без Docker)"
  install_laws_data

  step 7 "Проверка MCP-серверов"
  check_mcp_servers

  step 8 "sudrfscraper (судебная практика судов общей юрисдикции)"
  install_sudrfscraper

  step 9 "Рабочая папка ~/knowledge_base"
  create_knowledge_base

  summary
  log "Готово"
}

main "$@"
