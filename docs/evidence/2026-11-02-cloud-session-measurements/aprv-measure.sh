#!/bin/bash
# Measure apple-purchase-receipt-verifier's full toolchain + build + test footprint
# with every write going through cloud-disk.sh (btrfs zstd:3 under overlayfs).
# Each step logs: status, seconds, real MiB on the image, uncompressed MiB stored.
S=/tmp/claude-0/-home-user-playground/9834e68b-9fbd-5758-9f60-6a5d09bb01a3/scratchpad
R=/home/user/apple-purchase-receipt-verifier
OUT=$R/.out
LOG=$S/aprv.log
CD=$S/cd/cloud-disk.sh
IMG=/var/lib/cloud-disk/disk.img
MNT=/mnt/cloud-disk

real() { echo $(( $(du -sB1 $IMG | cut -f1) / 1048576 )); }
stored() { echo $(( $(du -sB1 $MNT/upper | cut -f1) / 1048576 )); }
step() { # name, command...
  local name=$1; shift; local t=$(date +%s)
  echo "### $name" >> $S/aprv-steps.log
  if timeout 2400 bash -c "$*" >> $S/aprv-steps.log 2>&1; then st=ok; else st="FAIL($?)"; fi
  sync
  printf "%-22s %-9s %5ss  real %6s MiB  stored %6s MiB  ext4-used %6s MiB\n" \
    "$name" "$st" $(( $(date +%s) - t )) "$(real)" "$(stored)" "$(df -B1M --output=used / | tail -1 | tr -d ' ')" >> $LOG
}

: > $LOG; : > $S/aprv-steps.log
echo "ext4 used before: $(df -B1M --output=used / | tail -1) MiB" >> $LOG

mkdir -p /opt/swift
$CD $R ~/.cache ~/.rustup ~/.cargo ~/go ~/.m2 ~/.npm ~/.nuget /usr/lib/dotnet /opt/swift >> $LOG 2>&1

export PATH=/opt/swift/usr/bin:$PATH GOTOOLCHAIN=auto BUNDLE_PATH=$R/ruby/vendor/bundle
cd $R

step apt-dotnet-musl   'apt-get install -y dotnet-sdk-10.0 musl-tools && apt-get clean'
step swift-6.3         'curl -sSfL -o /opt/swift/swift.tgz https://download.swift.org/swift-6.3-release/ubuntu2404/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu24.04.tar.gz && tar -xzf /opt/swift/swift.tgz -C /opt/swift --strip-components 1 && rm /opt/swift/swift.tgz && swift --version'
step rust-toolchain    'cd rust && rustup show active-toolchain || rustup toolchain install'
step wasm-module       'eval "$(tools/wasm-toolchain.sh $HOME/.cache/aprv-wasm-toolchain)" && rust/bindings/abi/build.sh '$OUT
step place-module      'cp '$OUT'/aprv.wasm go/internal/wasm/aprv.wasm && cp '$OUT'/aprv.wasm swift/Sources/ApplePurchaseReceiptVerifier/Resources/aprv.wasm && tools/refresh-wasm-pins.sh '$OUT'/aprv.wasm '$OUT'/aprv.component.wasm'
step rust-test         'cargo test --locked --workspace --manifest-path rust/Cargo.toml'
step aprv-server       'rust/server/scripts/build-static.sh '$OUT'/aprv.component.wasm x86_64-unknown-linux-musl '$OUT'/server'
step java              'mvn -B -q -f java/pom.xml verify'
step java-wasm         'mvn -B -q -f java-wasm/pom.xml verify -Daprv.wasm='$OUT'/aprv.wasm -Daprv.server.linux-x86_64=$(ls '$OUT'/server/aprv* | grep -v json | head -1)'
step node              'APRV_COMPONENT='$OUT'/aprv.component.wasm npm ci --ignore-scripts --prefix node && APRV_COMPONENT='$OUT'/aprv.component.wasm npm test --prefix node'
step go                'go -C go test ./...'
step python            'cd python && APRV_WASM='$OUT'/aprv.wasm uv run --locked --extra dev python -m unittest discover -s tests'
step ruby              'cd ruby && bundle install && APRV_WASM='$OUT'/aprv.wasm bundle exec rake test'
step swift-test        'swift test -c release -Xswiftc -enable-testing --force-resolved-versions'
step dotnet            'APRV_WASM='$OUT'/aprv.wasm dotnet test -c Release dotnet/tests/ApplePurchaseReceiptVerifier.Tests'
step php               'cd php && composer install --no-interaction && APRV_BIN=$(ls '$OUT'/server/aprv* | grep -v json | head -1) vendor/bin/phpunit'
step tools-lint        'npm ci --ignore-scripts --prefix tools && node tools/lint-cases.mjs'

echo "per-dir stored (uncompressed MiB):" >> $LOG
du -sm $MNT/upper/* | sort -n >> $LOG
echo DONE >> $LOG
