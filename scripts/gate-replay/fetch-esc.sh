#!/bin/bash
# Fetch the picked ESC-50 clips (measurement only, not committed) as /tmp/b4b/esc/<category>-<file>.
set -e
mkdir -p /tmp/b4b/esc
while read -r file category; do
  out="/tmp/b4b/esc/$category-$file"
  [ -s "$out" ] || curl -sfL "https://github.com/karolpiczak/ESC-50/raw/master/audio/$file" -o "$out"
done < /tmp/b4b/esc-pick.txt
ls /tmp/b4b/esc | wc -l
