#!/usr/bin/env bash
# Запускает внешних агентов read-only, каждого в своей модели по умолчанию с high effort, параллельно. Протокол работы — PROTOCOL.md.
# Агента-хоста не запускает: из Claude — только Codex, из Codex — только Claude; хост не определён — оба.
# Перед запуском Claude обновляет его через `brew upgrade --cask claude-code@latest`; Codex — симлинк на CLI из ChatGPT.app, обновляется с приложением.
#   run.sh [-C каталог] < промпт                                — раунд 1, одинаковый промпт всем
#   run.sh [-C каталог] --skill <имя> '<аргументы>'             — раунд 1 скилом: Codex получает `$имя аргументы`, Claude — `/имя аргументы`
#   run.sh [-C каталог] --resume <каталог прогона> [агент] < промпт — следующий раунд в тех же сессиях
# Файлы раунда — <каталог прогона>/<агент>/round-<N>/, ответ агента — answer.md.
# Печатает каталог прогона, строку «host: …» и по строке на агента: «<агент>: ok <путь к ответу>» или «<агент>: failed — <причина>».
# Прогон агента ограничен ASK_AGENTS_TIMEOUT секундами (по умолчанию 1200). Код выхода 0, если ответил хотя бы один агент.
set -uo pipefail

dir=$PWD
skill=""
args=""
D=""
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || { echo "-C: нужен каталог" >&2; exit 2; }; dir=$2; shift 2 ;;
    --skill) [ $# -ge 3 ] && [ -n "$2" ] || { echo "--skill: нужны имя скила и строка аргументов" >&2; exit 2; }; skill=$2; args=$3; shift 3 ;;
    --resume)
      [ -d "${2:-}" ] || { echo "--resume: нужен каталог прогона" >&2; exit 2; }
      D=$(cd "$2" && pwd); shift 2
      case "${1:-}" in codex|claude) only=$1; shift ;; esac ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
[ -z "$skill" ] || [ -z "$D" ] || { echo "--skill и --resume несовместимы" >&2; exit 2; }
limit=${ASK_AGENTS_TIMEOUT:-1200}
case "$limit" in ''|*[!0-9]*|0) echo "ASK_AGENTS_TIMEOUT: нужно целое число секунд больше 0" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 2; }

cd "$dir" || exit 2
if [ -z "$skill" ]; then
  prompt=$(cat)
  [ -n "$prompt" ] || { echo "пустой промпт" >&2; exit 2; }
fi

if [ -n "$D" ]; then
  # Продолжаем агентов, у которых в прогоне есть раунд 1.
  host=resume; agents=""
  for a in codex claude; do
    [ -z "$only" ] || [ "$a" = "$only" ] || continue
    [ -d "$D/$a/round-1" ] && agents="$agents $a"
  done
  agents=${agents# }
  [ -n "$agents" ] || { echo "в $D нет раунда 1${only:+ у $only}" >&2; exit 2; }
else
  # Хост — по переменным, которые агент выставляет своим шеллам; при обоих наборах хост неоднозначен.
  is_claude=${CLAUDECODE:-}
  is_codex=${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}
  if [ -n "$is_claude" ] && [ -z "$is_codex" ]; then
    host=claude; agents="codex"
  elif [ -n "$is_codex" ] && [ -z "$is_claude" ]; then
    host=codex; agents="claude"
  else
    host=unknown; agents="codex claude"
  fi
  D=$(mktemp -d /tmp/ask-agents.XXXX) || exit 2
fi
echo "$D"
echo "host: $host, запускаю: $agents"

# Каталог текущего раунда агента: R_codex, R_claude.
for agent in $agents; do
  n=1
  while [ -d "$D/$agent/round-$n" ]; do n=$((n + 1)); done
  C="$D/$agent/round-$n"
  mkdir -p "$C"
  printf -v "R_$agent" '%s' "$C"
  if [ -n "$skill" ]; then
    [ "$agent" = codex ] && sigil='$' || sigil='/'
    printf '%s%s %s\n' "$sigil" "$skill" "$args" > "$C/prompt.md"
  else
    printf '%s\n' "$prompt" > "$C/prompt.md"
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

# Запускает команду с лимитом в секундах: по истечении убивает её со всеми потомками (TERM, через 5 с — KILL), причину пишет в $C/timeout. В macOS нет `timeout`.
run_limited() {
  local secs=$1 C=$2 t=0 p pids
  shift 2
  # Без явного <&0 фоновая команда получает stdin из /dev/null.
  "$@" <&0 &
  p=$!
  while kill -0 "$p" 2>/dev/null; do
    if [ "$t" -ge "$secs" ]; then
      echo "не ответил за $secs с" > "$C/timeout"
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
  run_limited 15 "$C" "$1" --version < /dev/null > /dev/null 2>&1 && return 0
  echo 1 > "$C/exit"
  return 1
}

# Для следующего раунда нужен id сессии из раунда 1.
resume_id() {
  local C=$2 id
  [ "$C" != "$D/$1/round-1" ] || return 0
  id=$(session_id "$1")
  [ -n "$id" ] && { echo "$id"; return 0; }
  echo "нет id сессии в $D/$1/round-1" > "$C/err.txt"
  echo 1 > "$C/exit"
  return 1
}

# Вложенному агенту не передаём переменные хоста, чтобы он определял хоста по себе.
run_codex() {
  local C id
  C=$(round_dir codex)
  smoke codex "$C" || return
  id=$(resume_id codex "$C") || return
  if [ -n "$id" ]; then
    set -- exec resume --skip-git-repo-check -c model_reasoning_effort=high -c sandbox_mode=read-only --json -o "$C/answer.md" "$id" -
  else
    set -- exec --skip-git-repo-check -c model_reasoning_effort=high -s read-only --json -o "$C/answer.md" -
  fi
  run_limited "$limit" "$C" env -u CLAUDECODE codex "$@" \
    < "$C/prompt.md" > "$C/events.jsonl" 2> "$C/err.txt"
  echo $? > "$C/exit"
}

run_claude() {
  local C id
  C=$(round_dir claude)
  # Обновляем CLI перед запуском; сбой обновления запуск не останавливает.
  command -v brew >/dev/null && HOMEBREW_NO_ENV_HINTS=1 brew upgrade --cask claude-code@latest > "$C/upgrade.txt" 2>&1
  smoke claude "$C" || return
  id=$(resume_id claude "$C") || return
  set --
  [ -z "$id" ] || set -- --resume "$id"
  run_limited "$limit" "$C" env -u CLAUDECODE -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    claude -p "$@" --effort high --permission-mode dontAsk --add-dir "$D" \
    --allowedTools 'Read,Grep,Glob,Bash(git status *),Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git ls-files *)' \
    --disallowedTools 'Edit,Write,NotebookEdit' \
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
