#!/bin/bash
# DwarFS (FUSE, user space): dedup across files + its own choice of algorithms.
S=/tmp/claude-0/-home-user-playground/9834e68b-9fbd-5758-9f60-6a5d09bb01a3/scratchpad
DW=$S/dwarfs-dl/dwarfs-universal-0.15.8-Linux-x86_64; chmod +x $DW
IMG=$S/d.dwarfs; MNT=$S/m; mkdir -p $MNT
declare -A DATA=([node_modules]=$S/data/ai-date [toolchain_rustup]=/root/.rustup)
mib() { echo $(( $(du -sB1 "$1" | cut -f1) / 1048576 )); }
cold_read() { sync; echo 3 > /proc/sys/vm/drop_caches; local t0=$(date +%s.%N)
  tar -C "$1" -cf - . | cat > /dev/null; echo "$(date +%s.%N) - $t0" | bc; }
row() { printf "%-17s %-9s %-14s %7s %8.1f %8.1f\n" "$@"; }

for name in node_modules toolchain_rustup; do
  src=${DATA[$name]}
  for lvl in 3 5 7 9; do
    t0=$(date +%s.%N); $DW --tool=mkdwarfs -i $src -o $IMG -l$lvl --log-level=error >/dev/null 2>&1
    bt=$(echo "$(date +%s.%N) - $t0" | bc)
    if $DW --tool=dwarfs $IMG $MNT -o ro >/dev/null 2>&1 && sleep 1 && mountpoint -q $MNT; then
      rd=$(cold_read $MNT); fusermount -u $MNT 2>/dev/null || umount $MNT
      row "$name" dwarfs "-l$lvl" "$(mib $IMG)" "$bt" "$rd"
    else row "$name" dwarfs "-l$lvl(nomount)" "$(mib $IMG)" "$bt" 0; fi
    rm -f $IMG
  done
done
