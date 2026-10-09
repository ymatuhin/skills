#!/usr/bin/env bash
# Запускает Codex и Claude параллельно, read-only, каждого в своей модели по умолчанию с high effort. Порядок работы — SKILL.md.
# Перед раундом 1 обновляет Claude через `brew upgrade --cask claude-code@latest` (не дольше 120 с); Codex — симлинк на CLI из ChatGPT.app, обновляется с приложением.
#   run.sh [-C каталог] < промпт                          — раунд 1: один промпт обоим агентам
#   run.sh [-C каталог] --cross <каталог прогона> [агент] — раунд 2 или 3 перекрёстной проверки в тех же сессиях
# Команду скила в начале промпта (`/имя` или `$имя`) скрипт передаёт Codex как `$имя`, Claude — как `/имя`.
# К промпту раунда 1 добавляет ROUND-1.md, промпт следующих раундов собирает из CROSS.md.
# Файлы раунда — <каталог прогона>/<агент>/round-<N>/, ответ агента — answer.md.
# Печатает каталог прогона, строку «раунд N: …» и по строке на агента: «<агент>: ok <путь к ответу>» или «<агент>: failed — <причина>».
# Прогон агента ограничен ASK_AGENTS_TIMEOUT секундами (по умолчанию 1200). Код выхода 0, если ответил хотя бы один агент.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
max_round=3
dir=$PWD
D=""
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || { echo "-C: нужен каталог" >&2; exit 2; }; dir=$2; shift 2 ;;
    --cross)
      [ -d "${2:-}" ] || { echo "--cross: нужен каталог прогона" >&2; exit 2; }
      D=$(cd "$2" && pwd); shift 2
      case "${1:-}" in codex|claude) only=$1; shift ;; esac ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
limit=${ASK_AGENTS_TIMEOUT:-1200}
case "$limit" in ''|*[!0-9]*|0) echo "ASK_AGENTS_TIMEOUT: нужно целое число секунд больше 0" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 2; }
cd "$dir" || exit 2

other() { [ "$1" = codex ] && echo claude || echo codex; }
title() { [ "$1" = codex ] && echo Codex || echo Claude; }
id_prefix() { [ "$1" = codex ] && echo CX || echo CL; }

# Подставляет {ключ} в шаблоне: fill <файл> ключ значение ...
fill() {
  local text k
  text=$(cat "$1"); shift
  while [ $# -ge 2 ]; do k="{$1}"; text=${text//"$k"/$2}; shift 2; done
  printf '%s\n' "$text"
}

if [ -z "$D" ]; then
  prompt=$(cat)
  [ -n "${prompt//[[:space:]]/}" ] || { echo "пустой промпт" >&2; exit 2; }
  # Команда скила — первое слово промпта; остальное идёт ей аргументами.
  skill=""; rest=$prompt
  if [[ $prompt =~ ^[[:space:]]*[/\$]([A-Za-z0-9][A-Za-z0-9:_-]*)([[:space:]]|$) ]]; then
    skill=${BASH_REMATCH[1]}
    rest=${prompt#*"$skill"}
  fi
  agents="codex claude"
  round=1
  D=$(mktemp -d /tmp/ask-agents.XXXX) || exit 2
else
  [ -z "$only" ] && agents="codex claude" || agents=$only
  for a in $agents; do
    [ -d "$D/$a/round-1" ] || { echo "в $D нет раунда 1 у $a" >&2; exit 2; }
  done
  # Номер раунда — следующий после последнего у любого из агентов: раунд 3 бывает у одного.
  round=2
  while [ -d "$D/codex/round-$round" ] || [ -d "$D/claude/round-$round" ]; do round=$((round + 1)); done
  [ "$round" -le "$max_round" ] || { echo "раундов не больше $max_round: в $D уже есть раунд $max_round" >&2; exit 2; }
fi
echo "$D"
echo "раунд $round: $agents"

for agent in $agents; do
  C="$D/$agent/round-$round"
  mkdir -p "$C"
  printf -v "R_$agent" '%s' "$C"
  if [ "$round" = 1 ]; then
    {
      if [ -n "$skill" ]; then
        [ "$agent" = codex ] && printf '$%s' "$skill" || printf '/%s' "$skill"
      fi
      printf '%s\n\n' "$rest"
      fill "$here/ROUND-1.md" ID "$(id_prefix "$agent")"
    } > "$C/prompt.md"
  else
    o=$(other "$agent")
    last=""
    [ "$round" = "$max_round" ] && last="Это последний раунд: новых находок не добавляй."
    fill "$here/CROSS.md" OTHER "$(title "$o")" ANSWER "$D/$o/round-$((round - 1))/answer.md" LAST "$last" > "$C/prompt.md"
  fi
done

round_dir() { local v="R_$1"; echo "${!v}"; }

# id сессии — из раунда 1; resume его не меняет.
session_id() {
  if [ "$1" = codex ]; then
    jq -r 'select(.type=="thread.started") | .thread_id' "$D/codex/round-1/events.jsonl" 2>/dev/null | head -1
  else
    jq -r '.session_id // empty' "$D/claude/round-1/result.json" 2>/dev/null
  fi
}

# Все потомки процесса, сначала дети.
descendants() {
  local c
  for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done
}

any_alive() {
  local x
  for x; do kill -0 "$x" 2>/dev/null && return 0; done
  return 1
}

# Запускает команду с лимитом в секундах: по истечении убивает её со всеми потомками (TERM, через 5 с — KILL), причину пишет в файл-метку. В macOS нет `timeout`.
run_limited() {
  local secs=$1 mark=$2 t=0 p pids
  shift 2
  # Без явного <&0 фоновая команда получает stdin из /dev/null.
  "$@" <&0 &
  p=$!
  while kill -0 "$p" 2>/dev/null; do
    if [ "$t" -ge "$secs" ]; then
      echo "не ответил за $secs с" > "$mark"
      pids="$p $(descendants "$p")"
      kill -TERM $pids 2>/dev/null
      for t in 1 2 3 4 5; do any_alive $pids || break; sleep 1; done
      kill -KILL $pids 2>/dev/null
      break
    fi
    sleep 1; t=$((t + 1))
  done
  wait "$p"
}

# Зависший при старте CLI ловим за 15 с, а не за весь лимит прогона.
smoke() {
  local C=$2
  run_limited 15 "$C/timeout" "$1" --version < /dev/null > /dev/null 2>&1 && return 0
  echo 1 > "$C/exit"
  return 1
}

# Для раундов 2–3 нужен id сессии из раунда 1.
resume_id() {
  local C=$2 id
  [ "$C" != "$D/$1/round-1" ] || return 0
  id=$(session_id "$1")
  [ -n "$id" ] && { echo "$id"; return 0; }
  echo "нет id сессии в $D/$1/round-1" > "$C/err.txt"
  echo 1 > "$C/exit"
  return 1
}

# Перекрёстной проверке нужен ответ другого агента за прошлый раунд.
need_other_answer() {
  local C=$2 a
  [ "$round" = 1 ] && return 0
  a="$D/$(other "$1")/round-$((round - 1))/answer.md"
  [ -s "$a" ] && return 0
  echo "нет ответа другого агента: $a" > "$C/err.txt"
  echo 1 > "$C/exit"
  return 1
}

# Вложенным агентам не передаём переменные хоста. MCP, плагины и приложения отключены: у них свои права, read-only песочница их не ограничивает.
host_env=(env -u CLAUDECODE -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED)

run_codex() {
  local C id s
  local -a off
  C=$(round_dir codex)
  need_other_answer codex "$C" || return
  smoke codex "$C" || return
  id=$(resume_id codex "$C") || return
  off=(--disable plugins --disable apps --disable computer_use)
  for s in $(codex "${off[@]}" mcp list --json 2>/dev/null | jq -r '.[] | select(.enabled) | .name'); do
    off+=(-c "mcp_servers.$s.enabled=false")
  done
  if [ -n "$id" ]; then
    set -- exec resume --skip-git-repo-check -c model_reasoning_effort=high -c sandbox_mode=read-only "${off[@]}" --json -o "$C/answer.md" "$id" -
  else
    set -- exec --skip-git-repo-check -c model_reasoning_effort=high -s read-only "${off[@]}" --json -o "$C/answer.md" -
  fi
  run_limited "$limit" "$C/timeout" "${host_env[@]}" codex "$@" \
    < "$C/prompt.md" > "$C/events.jsonl" 2> "$C/err.txt"
  echo $? > "$C/exit"
}

run_claude() {
  local C id
  C=$(round_dir claude)
  need_other_answer claude "$C" || return
  # Обновляем CLI перед раундом 1: в resume версия не меняется. Сбой или зависание обновления запуск не останавливает.
  if [ "$round" = 1 ] && command -v brew >/dev/null; then
    run_limited 120 "$C/upgrade-timeout" env HOMEBREW_NO_ENV_HINTS=1 brew upgrade --cask claude-code@latest < /dev/null > "$C/upgrade.txt" 2>&1
  fi
  smoke claude "$C" || return
  id=$(resume_id claude "$C") || return
  set --
  [ -z "$id" ] || set -- --resume "$id"
  run_limited "$limit" "$C/timeout" "${host_env[@]}" \
    claude -p "$@" --effort high --permission-mode dontAsk --strict-mcp-config --add-dir "$D" --add-dir "$(dirname "$here")" \
    --allowedTools 'Read,Grep,Glob,WebSearch,WebFetch,Bash(git status *),Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git ls-files *)' \
    --disallowedTools 'Edit,Write,NotebookEdit,Bash(git * --output*)' \
    --append-system-prompt "Работаешь только на чтение. Файлы читай через Read, Grep и Glob. Bash — только git status/diff/log/show/ls-files, без cd и цепочек команд: рабочий каталог уже $PWD." \
    --output-format json \
    < "$C/prompt.md" > "$C/result.json" 2> "$C/err.txt"
  echo $? > "$C/exit"
  jq -r 'if .is_error then empty else .result // empty end' "$C/result.json" > "$C/answer.md" 2>/dev/null
}

for agent in $agents; do "run_$agent" & done
wait

reason() {
  local agent=$1 C r=""
  C=$(round_dir "$agent")
  if [ -s "$C/timeout" ]; then
    r=$(cat "$C/timeout")
  elif [ ! -e "$C/err.txt" ]; then
    r="CLI $agent не запускается: «$agent --version» упал или не ответил за 15 с"
  elif [ "$agent" = codex ]; then
    r=$(jq -r 'select(.type=="error" or .type=="turn.failed") | .message // .error.message // empty' "$C/events.jsonl" 2>/dev/null | tail -1)
  else
    r=$(jq -r 'select(.is_error) | .result // empty' "$C/result.json" 2>/dev/null)
  fi
  [ -n "$r" ] || r=$(grep -v '^\s*$' "$C/err.txt" | tail -1)
  echo "exit $(cat "$C/exit"): ${r:-причина не найдена, см. $C}"
}

ok=0
for agent in $agents; do
  C=$(round_dir "$agent")
  if [ "$(cat "$C/exit")" = 0 ] && [ -s "$C/answer.md" ] && [ ! -e "$C/timeout" ]; then
    echo "$agent: ok $C/answer.md"
    ok=1
  else
    echo "$agent: failed — $(reason "$agent")"
  fi
done
[ $ok = 1 ]
