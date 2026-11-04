#!/bin/bash
# Compare compressed filesystems available in this kernel.
# Output: dataset, fs, algo, MiB on the ext4 host disk, build s, cold read s
S=${ZO_SCRATCH:?set ZO_SCRATCH to a scratch folder with room for the images}
IMG=$S/b.img; MNT=$S/m; mkdir -p $MNT
declare -A DATA=([node_modules]=$S/data/ai-date [toolchain_rustup]=/root/.rustup)

mib() { echo $(( $(du -sB1 "$1" | cut -f1) / 1048576 )); }
cold_read() { sync; echo 3 > /proc/sys/vm/drop_caches; local t0=$(date +%s.%N)
  tar -C "$1" -cf - . | cat > /dev/null; echo "$(date +%s.%N) - $t0" | bc; }
row() { printf "%-17s %-9s %-14s %7s %8.1f %8.1f\n" "$@"; }
for name in node_modules toolchain_rustup; do
  src=${DATA[$name]}
  for algo in lz4 lz4hc,12 deflate,9 libdeflate,12 lzma,6 "lzma,9 -C1048576"; do
    t0=$(date +%s.%N); mkfs.erofs --quiet -z${algo% *} $( [[ $algo == *" "* ]] && echo ${algo#* } || echo -C131072 ) $IMG $src >/dev/null 2>&1; bt=$(echo "$(date +%s.%N) - $t0" | bc)
    if mount -t erofs -o loop,ro $IMG $MNT 2>/dev/null; then
      rd=$(cold_read $MNT); umount $MNT; row "$name" erofs "${algo/ -C1048576/+1M}" "$(mib $IMG)" "$bt" "$rd"
    else row "$name" erofs "$algo(nomount)" "$(mib $IMG)" "$bt" 0; fi
    rm -f $IMG
  done
done
