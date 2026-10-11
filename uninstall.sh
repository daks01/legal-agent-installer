#!/usr/bin/env bash
#
# Legal Agent Installer — удаление всех следов установки (критерий G4).
#
# Что удаляется:
#   - ~/.local/share/legal-agent/            (ru-legal, sudrfscraper, sudrf-scraper-mcp)
#   - ~/.config/opencode/skills/source-locked-ru/
#   - ~/.config/opencode/opencode.jsonc      (.bak будет восстановлен, если есть)
#
# Что НЕ трогается по умолчанию:
#   - ~/knowledge_base/  — ваши документы (удаляются только с --purge-docs)
#   - opencode и uv      — общие инструменты (в конце скрипт подскажет, как убрать)
#
# Использование:
#   bash uninstall.sh                # с подтверждениями
#   bash uninstall.sh --yes          # без вопросов (кроме документов)
#   bash uninstall.sh --yes --purge-docs   # удалить и ~/knowledge_base

set -euo pipefail

LEGAL_AGENT_HOME="$HOME/.local/share/legal-agent"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.jsonc"
SKILL_DIR="$OPENCODE_CONFIG_DIR/skills/source-locked-ru"
KNOWLEDGE_BASE="$HOME/knowledge_base"

ASSUME_YES=0
PURGE_DOCS=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge-docs) PURGE_DOCS=1 ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "Неизвестный аргумент: $arg (см. --help)"; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; NC=""
fi

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$1"; }

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local answer=""
  if [ -r /dev/tty ]; then
    printf '%s [y/N] ' "$1" > /dev/tty
    IFS= read -r answer < /dev/tty || true
  else
    printf '%s [y/N] (нет терминала — считаю 'no') ' "$1"
    IFS= read -r answer || true
  fi
  case "$answer" in y|Y|д|Д|yes|YES) return 0 ;; *) return 1 ;; esac
}

printf '%sLegal Agent Uninstaller%s — удаляю следы установки.\n\n' "$BOLD" "$NC"
printf 'Будет удалено:\n'
printf '  • %s\n' "$LEGAL_AGENT_HOME"
printf '  • %s\n' "$SKILL_DIR"
if [ -f "$OPENCODE_CONFIG_FILE.bak" ]; then
  printf '  • %s (будет восстановлен из .bak)\n' "$OPENCODE_CONFIG_FILE"
else
  printf '  • %s\n' "$OPENCODE_CONFIG_FILE"
fi
printf '\nДокументы в %s сохраняются (если не указан --purge-docs).\n\n' "$KNOWLEDGE_BASE"

if ! confirm "Продолжить удаление?"; then
  echo "Отменено — ничего не удалено."
  exit 0
fi

# 1. Остановить приложение sudrfscraper, если запущено
if pgrep -f "sudrfcsraper-0.3.0.jar" >/dev/null 2>&1; then
  pkill -f "sudrfcsraper-0.3.0.jar" 2>/dev/null || true
  ok "Остановлен процесс sudrfscraper"
fi

# 2. Конфиг: восстановить .bak или удалить
if [ -f "$OPENCODE_CONFIG_FILE.bak" ]; then
  mv "$OPENCODE_CONFIG_FILE.bak" "$OPENCODE_CONFIG_FILE"
  ok "Восстановлен прежний конфиг из opencode.jsonc.bak"
elif [ -f "$OPENCODE_CONFIG_FILE" ]; then
  rm -f "$OPENCODE_CONFIG_FILE"
  ok "Удалён $OPENCODE_CONFIG_FILE"
else
  ok "Конфиг отсутствовал — пропускаю"
fi

# 3. Скилл
if [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  rmdir "$SKILL_DIR/.." 2>/dev/null || true   # убрать skills/, если пуста
  ok "Удалён скилл source-locked-ru"
else
  ok "Скилл отсутствовал — пропускаю"
fi

# 4. Каталог legal-agent (ru-legal, sudrfscraper, sudrf-scraper-mcp)
if [ -d "$LEGAL_AGENT_HOME" ]; then
  rm -rf "$LEGAL_AGENT_HOME"
  ok "Удалён $LEGAL_AGENT_HOME"
else
  ok "Каталог legal-agent отсутствовал — пропускаю"
fi

# 5. Документы (только по явному согласию; --yes их не удаляет)
if [ -d "$KNOWLEDGE_BASE" ]; then
  if [ "$PURGE_DOCS" = "1" ]; then
    rm -rf "$KNOWLEDGE_BASE"
    ok "Удалена папка $KNOWLEDGE_BASE"
  elif [ "$ASSUME_YES" = "1" ]; then
    warn "Документы сохранены: $KNOWLEDGE_BASE (удалить: --purge-docs)"
  elif confirm "Удалить и ваши документы в $KNOWLEDGE_BASE?"; then
    rm -rf "$KNOWLEDGE_BASE"
    ok "Удалена папка $KNOWLEDGE_BASE"
  else
    warn "Документы сохранены: $KNOWLEDGE_BASE"
  fi
fi

printf '\n%sГотово.%s\n' "$GREEN" "$NC"
printf 'Остались общие инструменты (не трогаю):\n'
printf '  • opencode — удалить: opencode uninstall (или: rm -rf ~/.opencode)\n'
printf '  • uv       — удалить: rm -rf ~/.local/bin/uv ~/.local/bin/uvx ~/.local/share/uv ~/.cache/uv\n'
