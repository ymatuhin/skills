#!/usr/bin/env bash
# Держит ~/.codex/skills синхронизированным с ~/.claude/skills (источник — claude).
# Идемпотентно: досоздаёт недостающие симлинки, чинит битые, сообщает о чужих файлах.
set -euo pipefail

SRC="$HOME/.claude/skills"
DST="$HOME/.codex/skills"

[ -d "$SRC" ] || { echo "нет $SRC"; exit 1; }
mkdir -p "$DST"

created=0
for path in "$SRC"/*; do
  name=$(basename "$path")
  case "$name" in sync-links.sh) continue ;; esac
  link="$DST/$name"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$path" ] && [ -e "$link" ]; then
    continue
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "пропуск: $link — обычный файл, не симлинк (разберись вручную)"
    continue
  fi
  ln -sfn "$path" "$link"
  echo "симлинк: $name"
  created=$((created + 1))
done

# битые симлинки в источник удаляем: скил удалён из источника
removed=0
for link in "$DST"/*; do
  name=$(basename "$link")
  [ "$name" = ".system" ] && continue
  if [ -L "$link" ] && [ ! -e "$link" ] && [[ $(readlink "$link") == "$SRC"/* ]]; then
    rm "$link"
    echo "удалён битый симлинк: $name"
    removed=$((removed + 1))
  elif [ ! -L "$link" ]; then
    echo "только в codex: $name"
  fi
done

echo "готово, новых симлинков: $created, удалено битых: $removed"
