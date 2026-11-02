#!/bin/bash
# Compare compressed filesystems available in this kernel.
# Output: dataset, fs, algo, MiB on the ext4 host disk, build s, cold read s
S=/tmp/claude-0/-home-user-playground/9834e68b-9fbd-5758-9f60-6a5d09bb01a3/scratchpad
IMG=$S/b.img; MNT=$S/m; mkdir -p $MNT
declare -A DATA=([node_modules]=$S/data/ai-date [toolchain_rustup]=/root/.rustup)

mib() { echo $(( $(du -sB1 "$1" | cut -f1) / 1048576 )); }
cold_read() { sync; echo 3 > /proc/sys/vm/drop_caches; local t0=$(date +%s.%N)
  tar -C "$1" -cf - . | cat > /dev/null; echo "$(date +%s.%N) - $t0" | bc; }
row() { printf "%-17s %-9s %-14s %7s %8.1f %8.1f\n" "$@"; }

for name in node_modules toolchain_rustup; do
  src=${DATA[$name]}
  row "$name" ext4 "(baseline)" "$(mib $src)" 0 "$(cold_read $src)"

  for algo in none lzo zlib:1 zlib:3 zlib:9 zstd:-5 zstd:1 zstd:3 zstd:9 zstd:15; do
    truncate -s 20G $IMG; mkfs.btrfs -q -f -m single $IMG
    opt=compress-force=$algo; [ $algo = none ] && opt=compress=no
    if ! mount -o loop,$opt,noatime,discard=async $IMG $MNT 2>/dev/null; then
      row "$name" btrfs "$algo" "n/a" 0 0; rm -f $IMG; continue; fi
    t0=$(date +%s.%N); cp -a $src/. $MNT/; sync; bt=$(echo "$(date +%s.%N) - $t0" | bc)
    fstrim $MNT; sync; rd=$(cold_read $MNT)
    row "$name" btrfs "$algo" "$(mib $IMG)" "$bt" "$rd"
    umount $MNT; rm -f $IMG
  done

  for algo in lz4 lz4hc,12 deflate,9 libdeflate,12 lzma,6; do
    t0=$(date +%s.%N); mkfs.erofs -q -z$algo -C131072 $IMG $src >/dev/null 2>&1; bt=$(echo "$(date +%s.%N) - $t0" | bc)
    if mount -t erofs -o loop,ro $IMG $MNT 2>/dev/null; then
      rd=$(cold_read $MNT); umount $MNT; row "$name" erofs "$algo" "$(mib $IMG)" "$bt" "$rd"
    else row "$name" erofs "$algo(nomount)" "$(mib $IMG)" "$bt" 0; fi
    rm -f $IMG
  done

  for algo in gzip lzo lz4 zstd xz; do
    t0=$(date +%s.%N); mksquashfs $src $IMG -comp $algo -quiet -no-progress >/dev/null 2>&1; bt=$(echo "$(date +%s.%N) - $t0" | bc)
    if mount -t squashfs -o loop,ro $IMG $MNT 2>/dev/null; then
      rd=$(cold_read $MNT); umount $MNT; row "$name" squashfs "$algo" "$(mib $IMG)" "$bt" "$rd"
    else row "$name" squashfs "$algo(nomount)" "$(mib $IMG)" "$bt" 0; fi
    rm -f $IMG
  done
done
