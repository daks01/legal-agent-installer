# Windows: установка за 5 шагов (без WSL)

> **Windows 7 / 8 / 8.1 — не поддерживается**: opencode (среда Bun) и uv требуют
> Windows 10 1809+. Варианты: обновить ОС; либо поставить агента на другой
> компьютер (Windows 10/11 или Linux) и пользоваться с него; либо удалённый
> доступ к такой машине (например, `opencode web` и браузер).

## Шаг 1. Установите opencode

Скачайте `opencode-windows-x64.zip` со страницы
https://github.com/anomalyco/opencode/releases/latest, распакуйте в
`C:\Users\<вы>\.opencode\bin`, добавьте этот путь в PATH
(Параметры → Переменные среды) и проверьте в новом окне PowerShell:

```powershell
opencode --version
```

## Шаг 2. Получите ключ DeepSeek

https://platform.deepseek.com/api_keys → создайте ключ (он понадобится на шаге 4).

## Шаг 3 (необязательно). Ключ api-fns для проверки контрагентов

https://api-fns.ru → бесплатный тариф «СПК-старт» → ключ из личного кабинета.
Без него всё тоже работает — только проверка ЕГРЮЛ будет выключена.

## Шаг 4. Запустите настройку (одна команда)

В PowerShell вставьте две строки:

```powershell
irm https://raw.githubusercontent.com/daks01/legal-agent-installer/main/setup-windows.ps1 -OutFile "$env:TEMP\setup-windows.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\setup-windows.ps1"
```

Скрипт сам скачает и настроит MCP-серверы, базу законов и конфиг; ключи
спросит со скрытым вводом. Повторный запуск = обновление.
Для базы официальных публикаций добавьте `-WithPublications`.

## Шаг 5. Перезапустите opencode

Конфиг читается только при старте. Перезапустите `opencode` и проверьте:

```
opencode mcp list      → 6 connected + egrul disabled (без api-fns), включая laws
```

Первый запуск может занять пару минут: MCP-серверы собираются через uv.
Дальше просто спрашивайте агента по-русски — документы кладите в
`C:\Users\<вы>\knowledge_base\`.
