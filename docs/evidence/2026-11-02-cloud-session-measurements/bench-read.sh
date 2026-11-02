#!/bin/bash
# Fair read test: every format, ext4 included, lives in a freshly written image file.
# Columns: dataset fs algo MiB coldTar(s, median of 3) warmTar(s) coldTsc(s) warmTsc(s)
S=/tmp/claude-0/-home-user-playground/9834e68b-9fbd-5758-9f60-6a5d09bb01a3/scratchpad
DW=$S/dwarfs-dl/dwarfs-universal-0.15.8-Linux-x86_64
IMG=$S/r.img; MNT=$S/m; mkdir -p $MNT
declare -A DATA=([node_project]=$S/data/ai-date [rust_target]=$S/rproj/target)

mib() { echo $(( $(du -sB1 "$1" | cut -f1) / 1048576 )); }
now() { date +%s.%N; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
tarread() { local t=$(now); tar -C "$1" -cf - . | cat > /dev/null; echo "$(now) - $t" | bc; }
median3() { printf "%s\n" "$@" | sort -n | sed -n 2p; }
cold_tar() { local a b c; drop; a=$(tarread $1); drop; b=$(tarread $1); drop; c=$(tarread $1); median3 $a $b $c; }
tsc() { local t=$(now); (cd "$1/mobile" && node node_modules/typescript/bin/tsc --noEmit -p . >/dev/null 2>&1); echo "$(now) - $t" | bc; }

measure() { # name fs algo
  local c w tc=0 tw=0
  c=$(cold_tar $MNT); w=$(tarread $MNT)
  if [ $1 = node_project ]; then drop; tc=$(tsc $MNT); tw=$(tsc $MNT); fi
  printf "%-13s %-9s %-10s %6s %7.2f %7.2f %7.2f %7.2f\n" "$1" "$2" "$3" "$(mib $IMG)" "$c" "$w" "$tc" "$tw"
}

for name in node_project rust_target; do
  src=${DATA[$name]}
  # ext4 and btrfs: writable images
  for cfg in "ext4 -" "btrfs compress=no" "btrfs compress-force=zstd:1" "btrfs compress-force=zstd:3" "btrfs compress-force=zstd:9"; do
    fs=${cfg% *}; opt=${cfg#* }; truncate -s 20G $IMG
    if [ $fs = ext4 ]; then mkfs.ext4 -q $IMG; mount -o loop,noatime,discard $IMG $MNT
    else mkfs.btrfs -q -f -m single $IMG; mount -o loop,noatime,discard=async,$opt $IMG $MNT; fi
    cp -a $src/. $MNT/; sync; fstrim $MNT; sync
    measure $name $fs "${opt#compress-force=}"; umount $MNT; rm -f $IMG
  done
  # squashfs zstd: read-only
  mksquashfs $src $IMG -comp zstd -quiet -no-progress >/dev/null 2>&1
  mount -t squashfs -o loop,ro $IMG $MNT && { measure $name squashfs zstd; umount $MNT; }; rm -f $IMG
  # dwarfs: read-only, FUSE
  for lvl in 5 7 9; do
    $DW --tool=mkdwarfs -i $src -o $IMG -l$lvl --log-level=error >/dev/null 2>&1
    $DW --tool=dwarfs $IMG $MNT >/dev/null 2>&1; sleep 1
    if mountpoint -q $MNT; then measure $name dwarfs "-l$lvl"; fusermount -u $MNT 2>/dev/null || umount $MNT
    else echo "$name dwarfs -l$lvl: mount failed, image $(mib $IMG) MiB"; fi
    rm -f $IMG
  done
done
