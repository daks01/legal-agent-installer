#!/usr/bin/env bash
#
# Smoke-тест установки Legal Agent (запускать после install.sh, без sudo).
# Использование:
#   bash tests/test_install.sh            # все проверки (MCP-опрос может занять ~1 мин)
#   SKIP_MCP=1 bash tests/test_install.sh # без запуска opencode mcp list

set -uo pipefail

LEGAL_AGENT_HOME="$HOME/.local/share/legal-agent"
OPENCODE_CONFIG_FILE="$HOME/.config/opencode/opencode.jsonc"
SKILL_FILE="$HOME/.config/opencode/skills/source-locked-ru/SKILL.md"
KNOWLEDGE_BASE="$HOME/knowledge_base"

PASS=0
FAIL=0

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  GREEN=""; RED=""; BOLD=""; NC=""
fi

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s✓%s %s\n' "$GREEN" "$NC" "$name"
    PASS=$((PASS + 1))
  else
    printf '  %s✗%s %s\n' "$RED" "$NC" "$name"
    FAIL=$((FAIL + 1))
  fi
}

printf '%sПроверка установки Legal Agent%s\n' "$BOLD" "$NC"

check "opencode в PATH"                    command -v opencode
check "uvx в PATH"                         command -v uvx
check "конфиг opencode.jsonc существует"   test -f "$OPENCODE_CONFIG_FILE"
check "в конфиге есть deepseek"            grep -q '"deepseek"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть ru-legal"            grep -q '"ru-legal"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть pravo"               grep -q '"pravo"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть kad"                 grep -q '"kad"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть egrul"               grep -q '"egrul"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть office-docs"         grep -q '"office-docs"' "$OPENCODE_CONFIG_FILE"
check "в конфиге есть sudrf-scraper"       grep -q '"sudrf-scraper"' "$OPENCODE_CONFIG_FILE"
check "нет плейсхолдеров {{...}} в конфиге" bash -c "! grep -q '{{' '$OPENCODE_CONFIG_FILE'"
check "скилл source-locked-ru установлен"  test -f "$SKILL_FILE"
check "ru-legal склонирован"               test -d "$LEGAL_AGENT_HOME/ru-legal/packs"
check "sudrf-scraper-mcp разложен"         test -f "$LEGAL_AGENT_HOME/sudrf-scraper-mcp/pyproject.toml"
check "sudrfscraper установлен"            test -f "$LEGAL_AGENT_HOME/sudrfscraper/run.sh"
check "knowledge_base/court_practice"      test -d "$KNOWLEDGE_BASE/court_practice"
check "knowledge_base/templates"           test -d "$KNOWLEDGE_BASE/templates"
check "knowledge_base/output"              test -d "$KNOWLEDGE_BASE/output"

if command -v python3 >/dev/null 2>&1; then
  check "конфиг — валидный JSON"          bash -c "python3 -m json.tool '$OPENCODE_CONFIG_FILE' >/dev/null"
fi

if [ "${SKIP_MCP:-0}" != "1" ] && command -v opencode >/dev/null 2>&1; then
  mcp_out="$(opencode mcp list --pure 2>/dev/null || true)"
  if [ -z "$mcp_out" ]; then
    printf '  %s✗%s opencode mcp list не ответил (проверь PATH и логи)\n' "$RED" "$NC"
    FAIL=$((FAIL + 1))
  else
    for server in ru-legal pravo kad office-docs sudrf-scraper; do
      if printf '%s' "$mcp_out" | grep -q "✓ $server"; then
        printf '  %s✓%s MCP %s: connected\n' "$GREEN" "$NC" "$server"
        PASS=$((PASS + 1))
      else
        printf '  %s✗%s MCP %s: не подключён\n' "$RED" "$NC" "$server"
        FAIL=$((FAIL + 1))
      fi
    done
  fi
fi

printf '\nИтог: %s%d ✓%s, %s%d ✗%s\n' "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC"
[ "$FAIL" -eq 0 ]
