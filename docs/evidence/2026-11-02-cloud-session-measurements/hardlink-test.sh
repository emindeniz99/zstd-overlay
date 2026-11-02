#!/bin/bash
# Do pnpm (store -> node_modules) and uv (cache -> .venv) keep their hardlinks under cloud-disk.sh?
# A: cache and project on SEPARATE overlays.  B: one overlay holding both (XDG dirs moved under it).
S=/tmp/claude-0/-home-user-playground/9834e68b-9fbd-5758-9f60-6a5d09bb01a3/scratchpad
CD=$S/cd/cloud-disk.sh
SRC=/home/user/playground/projects
U=/mnt/cloud-disk/upper

run() { # label home proj-root
  local label=$1 home=$2 root=$3
  cp -a $SRC/ai-date/. $root/js/; cp -a $SRC/devlock/. $root/py/
  local before=$(du -sB1M /var/lib/cloud-disk/disk.img | cut -f1)
  ( export XDG_DATA_HOME=$home/.local/share XDG_CACHE_HOME=$home/.cache UV_CACHE_DIR=$home/.cache/uv
    pnpm -C $root/js install --ignore-scripts --config.store-dir=$home/.local/share/pnpm/store > $S/hl-$label-pnpm.log 2>&1
    cd $root/py && uv sync --python 3.13 > $S/hl-$label-uv.log 2>&1 )
  sync
  local f=$(find $root/js/node_modules/.pnpm -name package.json -path '*react@*' | head -1)
  local py=$(find $root/py/.venv -name '*.py' -path '*site-packages*' | head -1)
  printf "%-9s pnpm links=%s  uv links=%s  uv-warning=%s  image grew %s MiB\n" "$label" \
    "$(stat -c %h "$f")" "$(stat -c %h "$py")" "$(grep -c 'Failed to hardlink' $S/hl-$label-uv.log)" \
    "$(( $(du -sB1M /var/lib/cloud-disk/disk.img | cut -f1) - before ))"
}

# A: separate overlays (home dirs on one, projects on another)
A=/srv/hlA; mkdir -p $A/home/.local/share $A/home/.cache $A/proj/js $A/proj/py
$CD $A/home $A/proj > /dev/null
run separate $A/home $A/proj

# B: one overlay for home and projects
B=/srv/hlB; mkdir -p $B/home/.local/share $B/home/.cache $B/home/proj/js $B/home/proj/py
$CD $B/home > /dev/null
run single $B/home $B/home/proj
