---
name: codex-plan-review
description: Ревью плана скилом `plan-review` в Codex (gpt-6-sol, medium); передаёт вопросы Codex пользователю и ответы обратно. Режим «Из `plan-review`» — Codex только ищет, правит и спрашивает основная сессия.
argument-hint: "Путь к плану"
disable-model-invocation: true
---

Два режима. Вызван пользователем (`/codex-plan-review`) — проверяет и правит Codex, ты передаёшь сообщения между ним и пользователем; план сам не проверяй и не правь, ответы Codex не дополняй и не сокращай. Вызван из `plan-review` — раздел «Из `plan-review`» в конце.

Codex не видит разговор: без пути к документу остановись и предложи `/handoff`.

Каждую команду запускай через Bash в фоне (`run_in_background`) и дождись завершения: прогон бывает дольше 10 минут.

Первый запуск, `<аргументы>` — аргументы скила:

```bash
cd "$(git rev-parse --show-toplevel)" && D=$(mktemp -d /tmp/codex-plan-review.XXXX) && echo "$D" && codex exec -m gpt-6-sol -c model_reasoning_effort=medium -c sandbox_mode=workspace-write -c 'sandbox_workspace_write.writable_roots=["/tmp/handoffs"]' --json -o "$D/last.md" '$plan-review <аргументы>. Скил $grilling, на который он ссылается, прочитай до работы.' < /dev/null > "$D/events.jsonl" 2> "$D/err.txt"; echo "exit $?"; jq -r 'select(.type=="thread.started").thread_id' "$D/events.jsonl" | head -1 > "$D/thread"
```

Ответ пользователя — дословно в ту же сессию; `<каталог>` — из вывода первого запуска:

```bash
cd "$(git rev-parse --show-toplevel)" && D=<каталог> && rm -f "$D/last.md" && codex exec resume -m gpt-6-sol -c model_reasoning_effort=medium -c sandbox_mode=workspace-write -c 'sandbox_workspace_write.writable_roots=["/tmp/handoffs"]' --json -o "$D/last.md" "$(cat "$D/thread")" - > "$D/events.jsonl" 2> "$D/err.txt" <<'CODEX_ANSWER'
<ответ пользователя>
CODEX_ANSWER
echo "exit $?"
```

После каждого прогона покажи пользователю `$D/last.md` дословно. Код выхода не 0 или `last.md` пуст — покажи `err.txt` и события `error` / `turn.failed` из `events.jsonl` и остановись.

Пока в последнем ответе Codex есть вопросы, следующее сообщение пользователя — ответ Codex. Вопросов нет — работа закончена: команду следующего скила Codex выводит сам.

## Из `plan-review`

Этот режим запускает `plan-review`, когда пользователь попросил Codex. Codex только ищет: документ не правит, вопросов не задаёт; его находки согласует основная сессия по правилам `plan-review`. Сообщения Codex пользователю не передавай — они входят в ответ `plan-review`. Без пути к документу режим недоступен: Codex не видит разговор.

Запусти в фоне до своих проверок; `<путь>` — путь к документу из аргументов `plan-review`:

```bash
cd "$(git rev-parse --show-toplevel)" && D=$(mktemp -d /tmp/codex-plan-review.XXXX) && echo "$D" && codex exec -m gpt-6-sol -c model_reasoning_effort=medium -c sandbox_mode=read-only --json -o "$D/last.md" '$plan-review <путь>. Скил $grilling, на который он ссылается, прочитай до работы. Режим только находок: документ и код не правь, вопросов не задавай, команды следующего скила не предлагай. Каждая находка — пункт документа или файл:строка, что не так, предлагаемый текст правки; неуверенное пометь «(не уверен)» с рекомендацией. Без находок — «Находок нет».' < /dev/null > "$D/events.jsonl" 2> "$D/err.txt"; echo "exit $?"
```

Дождись завершения перед разбором находок. Код выхода не 0 или `last.md` пуст — покажи `err.txt` и события `error` / `turn.failed` из `events.jsonl`, продолжай `plan-review` без Codex и скажи об этом. Находки — в `$D/last.md`; целиком не показывай, по просьбе пользователя — дословно.
