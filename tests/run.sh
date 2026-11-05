#!/bin/bash
# Test harness for zstd-overlay: each scenario runs in its own privileged
# Ubuntu 24.04 container, which shares this host's kernel (the btrfs, overlayfs
# and loop code under test). `docker restart` stands in for a cloud VM restore:
# processes and mounts go, files stay.
#
#   tests/run.sh               every scenario
#   tests/run.sh 3 6           only scenarios 3 and 6
#
# Needs root, Docker, and network for the first image build (apt, and mise for
# scenario 9). Honours HTTPS_PROXY/HTTP_PROXY/NO_PROXY and ZO_CA_BUNDLE (a CA
# file to trust inside the containers). ZO_CLAUDE_BIN points at a Claude Code
# binary for scenario 11 (default: the one on PATH).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROJ=$(dirname "$HERE")
BASE=${ZO_BASE_IMAGE:-mirror.gcr.io/library/ubuntu:24.04}
CLOUD=zstd-overlay-test:cloud   # the tools a cloud session has: git curl jq python3
BARE=zstd-overlay-test:bare     # nothing added: no python3
CA=${ZO_CA_BUNDLE:-}
CLAUDE_BIN=${ZO_CLAUDE_BIN:-$(command -v claude || true)}
[ -n "$CLAUDE_BIN" ] && CLAUDE_BIN=$(readlink -f "$CLAUDE_BIN")

PASS=0; FAIL=0; SKIP=0; RESULTS=(); CT=""; LOG=$HERE/.last-run.log
: > "$LOG"

proxy_env() {
  local v; for v in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do [ -n "${!v:-}" ] && printf -- '-e %s ' "$v"; done
  # A proxy on this host's loopback is reachable from a container only on the host network.
  case "${HTTPS_PROXY:-}${https_proxy:-}" in *127.0.0.1*|*localhost*) printf -- '--network host ' ;; esac
}
ca_mount() {
  local c=/etc/ssl/certs/zo-test-ca.pem
  [ -n "$CA" ] && printf -- '-v %s:%s:ro -e SSL_CERT_FILE=%s -e CURL_CA_BUNDLE=%s -e NODE_EXTRA_CA_CERTS=%s -e REQUESTS_CA_BUNDLE=%s' "$CA" $c $c $c $c $c
}

build_images() {
  docker image inspect "$BARE" >/dev/null 2>&1 || docker tag "$BASE" "$BARE" || { docker pull -q "$BASE" && docker tag "$BASE" "$BARE"; } || return 1
  docker image inspect "$CLOUD" >/dev/null 2>&1 && return 0
  echo "building $CLOUD (apt: git curl ca-certificates jq python3 xz-utils)"
  # shellcheck disable=SC2046
  docker run --name zo-build $(proxy_env) $(ca_mount) "$BARE" bash -c '
    set -e; o=""; [ -f /etc/ssl/certs/zo-test-ca.pem ] && o="-o Acquire::https::CAInfo=/etc/ssl/certs/zo-test-ca.pem"
    apt-get $o update -qq && DEBIAN_FRONTEND=noninteractive apt-get $o install -y -qq --no-install-recommends git curl ca-certificates jq python3 xz-utils >/dev/null
    apt-get clean; rm -rf /var/lib/apt/lists/*' >> "$LOG" 2>&1 || { docker rm -f zo-build >/dev/null 2>&1; return 1; }
  docker commit zo-build "$CLOUD" >/dev/null && docker rm zo-build >/dev/null
}

# --- helpers -------------------------------------------------------------------

start() { # name [image]
  CT=zo-test-$1
  docker rm -f "$CT" >/dev/null 2>&1
  local extra=""
  [ -n "$CLAUDE_BIN" ] && extra="-v $CLAUDE_BIN:/usr/local/bin/claude:ro"
  # shellcheck disable=SC2046,SC2086
  docker run -d --privileged --name "$CT" -e HOME=/root -e CLAUDE_PROJECT_DIR=/work/repo -e CLAUDE_CODE_REMOTE=true \
    -v "$PROJ:/src:ro" $extra $(proxy_env) $(ca_mount) "${2:-$CLOUD}" sleep infinity >/dev/null
  x 'mkdir -p /work/repo && cd /work/repo && git init -q 2>/dev/null; printf "hello\n" > README; printf "only in the clone\n" > LOWERONLY; true'
}
stop() { docker rm -f "$CT" >/dev/null 2>&1; CT=""; }
x() { docker exec "$CT" bash -c "$1" 2>>"$LOG"; }            # run, stdout back
xs() { docker exec "$CT" bash -c "$1" >>"$LOG" 2>&1; }       # run silently, status back
restart() { docker restart -t 1 "$CT" >/dev/null; }
ZO=/src/zstd-overlay
# /src is excluded: when the host itself runs zstd-overlay, the test's own bind mount of the
# project shows up as one of its overlays inside the container.
mounts() { x 'findmnt -rn -t overlay -o TARGET,OPTIONS | grep -v "^/src " | grep -c "upperdir=/mnt/zstd-overlay/upper/" || true'; }
used_mb() { x 'sync; df -B1M --output=used /mnt/zstd-overlay | tail -1 | tr -d " "'; }   # what btrfs holds, compressed
alloc_mb() { x 'du -m /var/lib/zstd-overlay/disk.img | cut -f1'; }                        # what the image reserves on disk

check() { # description, then a shell test run on this host
  local d=$1; shift
  if "$@"; then echo "    ok    $d"; else echo "    FAIL  $d"; SCN_FAIL=1; fi
}
eq() { [ "$1" = "$2" ] || { echo "          got [$1], want [$2]"; return 1; }; }
has() { case "$1" in *"$2"*) return 0 ;; *) echo "          [$2] not in output:"; printf '%s\n' "$1" | sed 's/^/            /' | head -12; return 1 ;; esac; }
lt() { [ "$1" -lt "$2" ] || { echo "          $1 is not < $2"; return 1; }; }

scenario() { # number, title
  SCN=$1; SCN_FAIL=0; echo; echo "[$1] $2"; printf '\n===== scenario %s: %s\n' "$1" "$2" >> "$LOG"
}
done_scenario() {
  stop
  if [ "${SCN_SKIP:-0}" = 1 ]; then SKIP=$((SKIP + 1)); RESULTS+=("SKIP $SCN"); SCN_SKIP=0
  elif [ "$SCN_FAIL" = 0 ]; then PASS=$((PASS + 1)); RESULTS+=("pass $SCN")
  else FAIL=$((FAIL + 1)); RESULTS+=("FAIL $SCN"); fi
}

# --- scenarios -----------------------------------------------------------------

s1() {
  scenario 1 "fresh session: default list, compression, capacity follows the disk"
  start s1
  local out; out=$(x "cd /work/repo && $ZO up; echo exit=\$?")
  check "up exits 0" has "$out" "exit=0"
  check "up does not report its own shell as a process to restart" eq "$(printf '%s\n' "$out" | grep -c 'started earlier')" 0
  check "the folder holding the repo, ~/.cache, ~/.local/share, ~/.local/bin, ~/.npm mounted" eq "$(mounts)" 5
  check "it is /work, the folder holding /work/repo" eq "$(x 'findmnt -rn -t overlay -o TARGET | grep -cx /work')" 1
  xs 'git clone -q /work/repo /work/attached-later && head -c 20M /dev/zero > /work/attached-later/big && sync'
  check "a repository cloned next to it later lands in the image" eq "$(x 'ls /mnt/zstd-overlay/upper/%work/attached-later/big | wc -l')" 1
  xs 'yes "the same line of build output, again and again" | head -c 300M > /work/repo/build.log; head -c 50M /dev/urandom > /root/.cache/random.bin; sync'
  local used; used=$(used_mb)
  check "300 MiB of text + 50 MiB of random: btrfs holds < 80 MiB (holds ${used})" lt "$used" 80
  local cap avail img
  read -r cap avail img < <(x 'echo $(df -B1M --output=size /mnt/zstd-overlay | tail -1) $(df -B1M --output=avail /var/lib/zstd-overlay | tail -1) $(du -m /var/lib/zstd-overlay/disk.img | cut -f1)')
  check "the image reserves its whole capacity on disk ($img of $cap MiB)" lt $((cap - img)) 64
  check "4 GiB stay free outside the image ($avail MiB)" lt $(( (avail - 4096) * (avail - 4096) )) $((300 * 300))
  check "doctor without CLAUDE_PROJECT_DIR still lists the mounted repo folder" has "$(x "env -u CLAUDE_PROJECT_DIR $ZO doctor")" "ok        /work"
  check "the loop device reads the image directly (cached once in memory)" eq "$(x 'cat /sys/block/$(findmnt -rn -o SOURCE /mnt/zstd-overlay | sed s,/dev/,,)/loop/dio')" 1
  check "no btrfs-progs in the container" eq "$(x 'command -v mkfs.btrfs btrfs | wc -l')" 0
  done_scenario
}

s2() {
  scenario 2 "up again: idempotent"
  start s2
  xs "$ZO up"
  local out; out=$(x "$ZO up; echo exit=\$?")
  check "second up exits 0" has "$out" "exit=0"
  check "second up mounts nothing new" eq "$(printf '%s\n' "$out" | grep -c compressed:)" 0
  check "still 5 overlays" eq "$(mounts)" 5
  done_scenario
}

s3() {
  scenario 3 "VM restore (docker restart): everything comes back"
  start s3
  xs "$ZO up && head -c 20M /dev/urandom > /work/repo/data.bin && cd /work/repo && git add -A && git -c user.email=t@t -c user.name=t commit -qm one"
  local sum; sum=$(x 'sha256sum /work/repo/data.bin | cut -c1-16')
  restart
  check "after restart: no overlays" eq "$(mounts)" 0
  check "after restart: the old folder is visible (no data.bin)" eq "$(x 'ls /work/repo/data.bin 2>/dev/null | wc -l')" 0
  local out; out=$(x "$ZO up; echo exit=\$?")
  check "up after restart exits 0" has "$out" "exit=0"
  check "5 overlays again" eq "$(mounts)" 5
  check "direct I/O again after the restart" eq "$(x 'cat /sys/block/$(findmnt -rn -o SOURCE /mnt/zstd-overlay | sed s,/dev/,,)/loop/dio')" 1
  check "data.bin back, same bytes" eq "$(x 'sha256sum /work/repo/data.bin | cut -c1-16')" "$sum"
  check "git history back" has "$(x 'git -C /work/repo log --oneline')" "one"
  done_scenario
}

s4() {
  scenario 4 "written while unmounted: hidden writes refused (B), --merge on request"
  start s4
  # The session writes a new file and changes README: both live in the image.
  xs "$ZO up && echo 'from the session' > /work/repo/session.txt && echo 'session edit' >> /work/repo/README"
  restart
  xs 'echo "edited while unmounted" >> /work/repo/README'
  local out; out=$(x "$ZO up; echo exit=\$?")
  check "up exits 3" has "$out" "exit=3"
  check "repo folder NOT MOUNTED, README named" has "$out" "/work/repo/README"
  check "the other 4 folders mounted" eq "$(mounts)" 4
  check "the edit is visible (the folder stays on the normal disk)" has "$(x 'cat /work/repo/README')" "edited while unmounted"
  check "session.txt not visible yet (it is in the image)" eq "$(x 'ls /work/repo/session.txt 2>/dev/null | wc -l')" 0
  out=$(x "$ZO doctor")
  check "doctor names the changed folder" has "$out" "CHANGED   /work ("
  out=$(x "$ZO up --hook; echo exit=\$?")
  check "hook mode: exits 0 so Claude Code reads the output" has "$out" "exit=0"
  out=$(x "$ZO up --hook | jq -r '.systemMessage, .hookSpecificOutput.hookEventName, .hookSpecificOutput.additionalContext'")
  check "hook mode: a warning for the user" has "$out" "1 folder(s) not compressed this session"
  check "hook mode: the details and the --merge rule for Claude" has "$out" "only after the user has looked at the listed files and agreed"
  out=$(x "$ZO up --merge /work; echo exit=\$?")
  check "--merge exits 0" has "$out" "exit=0"
  check "after merge: the normal disk's edit wins" has "$(x 'cat /work/repo/README')" "edited while unmounted"
  check "after merge: session.txt is back" has "$(x 'cat /work/repo/session.txt')" "from the session"
  restart
  out=$(x "$ZO up; echo exit=\$?")
  check "unchanged folder after restart: no false alarm" has "$out" "exit=0"
  restart
  xs 'echo "a new file on the normal disk" > /work/repo/new-outside.txt; rm /work/repo/LOWERONLY'
  out=$(x "$ZO up; echo exit=\$?")
  check "a new file or a delete the image has no version of: mounted, nothing to hide" has "$out" "exit=0"
  check "the new file shows, the deleted one stays deleted" eq "$(x 'cat /work/repo/new-outside.txt; ls /work/repo/LOWERONLY 2>/dev/null | wc -l')" $'a new file on the normal disk\n0'
  done_scenario
}

s5() {
  scenario 5 "migrate: verified move, deletions stay deleted, repo refused, kill-safe"
  start s5
  x 'mkdir -p /root/.m2/a/b && yes m2 | head -c 100M > /root/.m2/a/b/big.txt && echo keep > /root/.m2/keep && echo gone > /root/.m2/gone
     ln -s a/b/big.txt /root/.m2/link && ln /root/.m2/keep /root/.m2/hard && chmod 640 /root/.m2/keep && touch -d 2020-01-01 /root/.m2/keep' >/dev/null
  # directory sizes and link counts differ between ext4 and btrfs by design; files must not
  local sig='cd /root/.m2 && { find . -type d -printf "%p d %m\n"; find . ! -type d -printf "%p %y %m %s %TY %TD\n"; } | sort | sha256sum | cut -c1-16'
  local before; before=$(x "$sig")
  local out; out=$(x "$ZO migrate /root/.m2; echo exit=\$?")
  check "migrate exits 0" has "$out" "migrated: /root/.m2"
  check "names, types, modes, sizes, mtimes unchanged" eq "$(x "$sig")" "$before"
  check "no .zstd-overlay-old left" eq "$(x 'ls -d /root/.m2.zstd-overlay-old 2>/dev/null | wc -l')" 0
  check "the old folder under the mount is empty" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && ls -A /tmp/r/root/.m2 | wc -l; umount /tmp/r')" 0
  out=$(x "$ZO migrate /root/.m2; echo exit=\$?")
  check "migrate of a mounted folder: skipped" has "$out" "skipped: /root/.m2 is mounted"
  xs 'echo newer > /root/.m2/keep; rm /root/.m2/gone'
  restart
  out=$(x "$ZO migrate /root/.m2; echo exit=\$?")
  check "migrate after restart exits 0" has "$out" "exit=0"
  check "newer version kept" eq "$(x 'cat /root/.m2/keep')" "newer"
  check "deleted file stays deleted" eq "$(x 'ls /root/.m2/gone 2>/dev/null | wc -l')" 0
  out=$(x "$ZO migrate /work/repo; echo exit=\$?")
  check "a repository is refused" has "$out" "is a repository"
  out=$(x "$ZO migrate /work; echo exit=\$?")
  check "the folder holding the repository is refused too" has "$out" "refused: /work is a repository"
  # kill -9 in the middle of the copy, then check nothing was lost
  x 'mkdir -p /root/.gradle && for i in $(seq 1 40); do yes "g$i" | head -c 20M > /root/.gradle/f$i; done' >/dev/null
  before=$(x 'cd /root/.gradle && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16')
  # Kill once the copy has started: the migrating layer exists and holds files. The patterns
  # match the python3 process and its cp child, not this bash -c, whose command line has both.
  x "$ZO migrate /root/.gradle >/dev/null 2>&1 &
     for i in \$(seq 1500); do [ -n \"\$(ls -A /mnt/zstd-overlay/upper/%root%.gradle.migrating 2>/dev/null)\" ] && break; sleep 0.02; done
     pkill -9 -f '^python3 [^ ]*zstd-overlay migrate'; pkill -9 -x cp; sleep 1; true" >/dev/null
  check "killed in the middle of the copy" eq "$(x 'ls /mnt/zstd-overlay/upper/%root%.gradle.migrating | wc -l' | awk '{print ($1 > 0 && $1 < 40)}')" 1
  check "no migrate or cp left running" eq "$(x 'pgrep -f "^python3 [^ ]*zstd-overlay migrate|^cp -a" | wc -l')" 0
  check "after kill -9: content intact" eq "$(x 'cd /root/.gradle && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16')" "$before"
  restart
  out=$(x "$ZO migrate /root/.gradle; echo exit=\$?")
  check "migrate after the killed one succeeds" has "$out" "migrated: /root/.gradle"
  check "content still intact" eq "$(x 'cd /root/.gradle && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16')" "$before"
  check "no leftover .migrating" eq "$(x 'ls -d /mnt/zstd-overlay/upper/*.migrating 2>/dev/null | wc -l')" 0
  done_scenario
}

s6() {
  scenario 6 "disk full, from inside and from outside the image"
  start s6
  # A 3 GiB ext4 disk stands in for the session's 30 GB disk; reserve 1 GiB outside.
  local env='export ZSTD_OVERLAY_IMG=/small/zo/disk.img ZSTD_OVERLAY_RESERVE_MB=1024'
  xs 'truncate -s 3G /disk3g.img && mkfs.ext4 -q /disk3g.img && mkdir -p /small && mount -o loop /disk3g.img /small'
  xs "$env; $ZO up /work/data"
  local cap; cap=$(x 'df -B1M --output=size /mnt/zstd-overlay | tail -1 | tr -d " "')
  check "capacity sized to the small disk minus the reserve (${cap} MiB)" lt "$cap" 2000
  local out; out=$(x '{ head -c 3G /dev/urandom > /work/data/fill; } 2>&1; echo exit=$?')
  check "filling the image: a plain 'No space left'" has "$out" "No space left"
  check "the disk outside keeps its reserve (>900 MiB free)" lt 900 "$(x 'df -B1M --output=avail /small | tail -1')"
  xs 'rm /work/data/fill; sync'
  out=$(x 'for i in $(seq 1 30); do head -c 200M /dev/urandom > /work/data/after 2>/dev/null && sync && { echo "wrote after ${i}s"; break; }; sync; sleep 1; done')
  check "after deleting, the image takes writes again within 30 s, without remount (${out:-never})" has "$out" "wrote"
  out=$(x '{ head -c 3G /dev/urandom > /small/outside.bin; } 2>&1; echo exit=$?')
  check "filling the disk from outside: the outside writer gets 'No space left'" has "$out" "No space left"
  out=$(x 'head -c 300M /dev/urandom > /work/data/late && sync && cmp -n 1000 /work/data/late /work/data/late && echo wrote')
  check "the image still takes writes with the disk under it full" has "$out" "wrote"
  check "btrfs did not turn read-only" eq "$(x 'findmnt -n -o OPTIONS /mnt/zstd-overlay | grep -c "^ro,"')" 0
  check "no btrfs errors in the kernel log" eq "$(x 'dmesg 2>/dev/null | grep -c "BTRFS error (device $(basename $(findmnt -n -o SOURCE /mnt/zstd-overlay)))" || true')" 0
  xs 'rm -f /work/data/late /work/data/after; sync'
  out=$(x "$env; $ZO up /work/data; df -B1M --output=avail /small | tail -1")
  printf '%s\n' "$out" | sed '$d' | sed 's/^/    info  /'
  check "up gives the reserve back from the image when the outside ran out (free now $(printf '%s' "$out" | tail -1) MiB)" lt 700 "$(printf '%s\n' "$out" | tail -1)"
  xs 'rm -f /small/outside.bin'
  local before; before=$(x 'df -B1M --output=size /mnt/zstd-overlay | tail -1')
  out=$(x "$env; $ZO up /work/data; df -B1M --output=size /mnt/zstd-overlay | tail -1")
  check "up grows the image again when the disk has room ($before -> $(printf '%s' "$out" | tail -1) MiB)" lt "$before" "$(printf '%s\n' "$out" | tail -1)"
  done_scenario
}

s7() {
  scenario 7 "deleting files frees space inside the image for reuse"
  start s7
  xs "$ZO up && head -c 500M /dev/urandom > /root/.cache/blob && sync"
  local a1 u1 u2 a2; a1=$(alloc_mb); u1=$(used_mb)
  xs 'rm /root/.cache/blob; sync; sleep 2'
  u2=$(used_mb)
  check "btrfs usage drops by > 400 MiB after delete ($u1 -> $u2 MiB)" lt "$u2" $((u1 - 400))
  xs 'head -c 500M /dev/urandom > /root/.cache/blob2 && sync'
  a2=$(alloc_mb)
  check "writing again reuses the space: the reservation did not grow ($a1 -> $a2 MiB)" lt "$a2" $((a1 + 64))
  done_scenario
}

s8() {
  scenario 8 "reflinks within and across folders; git in a mounted repo"
  start s8
  xs "$ZO up && head -c 30M /dev/urandom > /work/repo/a.bin"
  check "reflink copy inside one folder" xs 'cp --reflink=always /work/repo/a.bin /work/repo/b.bin'
  local r; r=$(x 'cp --reflink=always /work/repo/a.bin /root/.cache/c.bin 2>&1 && echo shared || echo copied')
  echo "    info  reflink across two mounted folders: ${r##*$'\n'} (overlayfs refuses it; tools fall back to a compressed copy)"
  check "a plain copy across two folders works" xs 'cp /work/repo/a.bin /root/.cache/d.bin'
  check "git commit / branch / checkout / stash / gc" xs 'cd /work/repo && git -c user.email=t@t -c user.name=t commit -qam x --allow-empty && git add -A && git -c user.email=t@t -c user.name=t commit -qm y && git checkout -qb feature && echo z > z && git stash -qu && git stash pop -q && git checkout -q - && git gc -q && git fsck --no-progress'
  done_scenario
}

s9() {
  scenario 9 "the Stack toolchain: mise -> node 24 + pnpm 12, uv + Python"
  start s9
  if ! xs 'curl -fsSL https://mise.run | MISE_INSTALL_PATH=/root/.local/bin/mise sh'; then
    echo "    SKIP  mise could not be downloaded (network)"; SCN_SKIP=1; done_scenario; return
  fi
  xs "$ZO up"
  xs 'cp -a /src/tests/fixtures/node-app /work/node-app && cp -a /src/tests/fixtures/py-app /work/py-app'
  local out
  out=$(x 'export PATH=/root/.local/bin:$PATH; cd /work/node-app && mise trust -q . && mise install -q && mise exec -- node --version && mise exec -- pnpm --version && mise exec -- pnpm install >/dev/null && echo pnpm-ok')
  check "node 24 + pnpm 12 + pnpm install" has "$out" "pnpm-ok"
  out=$(x 'export PATH=/root/.local/bin:$PATH; cd /work/py-app && mise trust -q . && mise install -q && mise exec -- uv sync >/dev/null 2>&1 && mise exec -- uv run python -c "import six; print(\"py-ok\")"')
  check "uv + Python + uv sync" has "$out" "py-ok"
  check "mise installs live in the image" has "$(x 'ls /mnt/zstd-overlay/upper/%root%.local%share/mise/installs')" "node"
  check "node_modules lives in the image" eq "$(x 'ls -d /mnt/zstd-overlay/upper/%work/node-app/node_modules | wc -l')" 1
  done_scenario
}

s10() {
  scenario 10 "install: hook merged into settings.json safely"
  start s10
  local out
  out=$(x "$ZO install; echo exit=\$?; jq -c '.hooks.SessionStart' /root/.claude/settings.json")
  check "install on a fresh home adds the hook" has "$out" '/usr/local/bin/zstd-overlay up'
  check "install does not create the image" eq "$(x 'ls /var/lib/zstd-overlay/disk.img 2>/dev/null | wc -l')" 0
  x "echo '{\"model\":\"x\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo mine\"}]}],\"Stop\":[]}}' > /root/.claude/settings.json" >/dev/null
  xs "$ZO install && $ZO install"
  out=$(x "jq -c '[.model, (.hooks.SessionStart|length), (.hooks|has(\"Stop\")), ([.hooks.SessionStart[].hooks[].command]|join(\",\"))]' /root/.claude/settings.json")
  check "existing settings kept, our hook once (twice installed)" eq "$out" '["x",2,true,"echo mine,/usr/local/bin/zstd-overlay up --hook"]'
  x 'echo "{broken" > /root/.claude/settings.json' >/dev/null
  out=$(x "$ZO install 2>&1; echo exit=\$?; cat /root/.claude/settings.json")
  check "invalid JSON: exit 2, file untouched" has "$out" $'exit=2\n{broken'
  out=$(x "rm -f /root/.claude/settings.json; PATH=/usr/sbin:/usr/bin:/sbin:/bin; mv /usr/bin/jq /usr/bin/jq.off; $ZO install; echo exit=\$?; mv /usr/bin/jq.off /usr/bin/jq; python3 -c 'import json;print(json.load(open(\"/root/.claude/settings.json\"))[\"hooks\"][\"SessionStart\"][0][\"matcher\"])'")
  check "install needs no jq" has "$out" "startup|resume"
  stop
  start s10b "$BARE"
  out=$(x "$ZO up 2>&1; echo exit=\$?")
  check "bare image without python3: stops at once and names python3" has "$out" "python3"
  # (the container's own root is an overlay too; count only ours and btrfs)
  check "bare image: nothing was mounted" eq "$(mounts):$(x 'findmnt -rn -t btrfs | wc -l')" "0:0"
  done_scenario
}

s11() {
  scenario 11 "the real Claude Code binary runs the SessionStart hook"
  if [ -z "$CLAUDE_BIN" ]; then echo "    SKIP  no claude binary"; SCN_SKIP=1; CT=""; done_scenario; return; fi
  start s11
  xs "$ZO install"
  local out
  out=$(x 'cd /work/repo && ANTHROPIC_API_KEY=sk-ant-invalid timeout 90 claude -p "say hi" --max-turns 1 2>&1 | tail -2; echo "exit=${PIPESTATUS[0]}"')
  echo "    info  claude: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
  check "after claude started: the folder holding the repo is mounted (hook ran with CLAUDE_PROJECT_DIR)" \
    eq "$(x 'findmnt -rn -t overlay -o TARGET | grep -cx /work')" 1
  check "and the default folders" eq "$(mounts)" 5
  done_scenario
}

s12() {
  scenario 12 "snapshot: why the setup script must not create the image"
  start s12
  xs "$ZO install"
  docker commit "$CT" zo-snap-install >/dev/null
  # Keep the image small for this test: capacity ~1 GiB, whatever the host has free.
  local free; free=$(x 'df -B1M --output=avail /var/lib | tail -1')
  xs "ZSTD_OVERLAY_RESERVE_MB=$((free - 1024)) $ZO up /work/data"
  local apparent; apparent=$(x 'du -m --apparent-size /var/lib/zstd-overlay/disk.img | cut -f1')
  xs 'umount /work/data /mnt/zstd-overlay'
  docker commit "$CT" zo-snap-image >/dev/null
  local a b; a=$(docker image inspect -f '{{.Size}}' zo-snap-install); b=$(docker image inspect -f '{{.Size}}' zo-snap-image)
  echo "    info  docker commit after install: $((a / 1048576)) MiB; with a ${apparent} MiB image (fully reserved): $((b / 1048576)) MiB"
  check "install leaves nothing large for a snapshot" lt $(( (a - $(docker image inspect -f '{{.Size}}' "$CLOUD")) / 1048576 )) 5
  docker rmi -f zo-snap-install zo-snap-image >/dev/null 2>&1
  done_scenario
}

s13() {
  scenario 13 "lock, nesting, root"
  start s13
  local out
  x "$ZO up >/tmp/a 2>&1 & $ZO up >/tmp/b 2>&1 & wait" >/dev/null
  check "two ups at once: 5 overlays, not 10" eq "$(mounts)" 5
  out=$(x "$ZO up /root/.cache/sub; echo exit=\$?")
  check "a folder inside a mounted one is refused" has "$out" "inside /root/.cache, which is already mounted"
  out=$(x "$ZO up /tmp/n /tmp/n/inner; echo exit=\$?")
  check "a folder inside another listed one is refused" has "$out" "inside /tmp/n, also listed"
  out=$(x "$ZO up / /usr/lib /root /opt/claude-code /root/.claude; echo exit=\$?")
  check "system folders, /root and ~/.claude refused" eq "$(printf '%s\n' "$out" | grep -c refused:)" 5
  out=$(x "setpriv --reuid=65534 --regid=65534 --clear-groups $ZO up 2>&1; echo exit=\$?")
  check "non-root: refused with exit 2" has "$out" $'needs root (it mounts)\nexit=2'
  out=$(x "setpriv --reuid=65534 --regid=65534 --clear-groups $ZO --help | head -1")
  check "non-root: --help works" has "$out" "zstd-overlay"
  done_scenario
}

s14() {
  scenario 14 "resume: the platform and MCP servers write before the hook runs"
  start s14
  local commit='git -c user.email=t@t -c user.name=t commit -q'
  xs "cd /work/repo && git add -A && $commit -m base"
  xs "$ZO up"
  # In the session: git writes .git/config (push -u does), npm its cache and a log, Claude Code an MCP log.
  xs "cd /work/repo && git config branch.main.remote origin && echo work > notes.txt && git add notes.txt && $commit -m session
      mkdir -p /root/.npm/_cacache/index-v5/aa /root/.npm/_logs /root/.cache/cc/mcp-logs
      echo one > /root/.npm/_cacache/index-v5/aa/bucket; echo s > /root/.npm/_logs/session.log; echo s > /root/.cache/cc/mcp-logs/session.jsonl"
  restart
  # Before the hook, as measured in a cloud session: the platform rewrites every repository's
  # .git/config; `npm exec` (an MCP server) writes its cache and a log; Claude Code logs MCP.
  xs 'git -C /work/repo config core.sshCommand platform-wrote-this
      mkdir -p /root/.npm/_cacache/index-v5/aa /root/.npm/_logs /root/.cache/cc/mcp-logs
      echo two > /root/.npm/_cacache/index-v5/aa/bucket; echo r > /root/.npm/_logs/resume.log; echo r > /root/.cache/cc/mcp-logs/resume.jsonl'
  local out; out=$(x "$ZO up --hook; echo exit=\$?")
  check "hook exits 0" has "$out" "exit=0"
  check "no folder refused" eq "$(printf '%s' "$out" | grep -c 'not compressed')" 0
  check "all 5 folders mounted" eq "$(mounts)" 5
  check "the session's commit and file are there" eq "$(x 'git -C /work/repo log --format=%s -1; cat /work/repo/notes.txt')" $'session\nwork'
  check ".git/config keeps the platform's write" eq "$(x 'git -C /work/repo config core.sshCommand')" "platform-wrote-this"
  check ".git/config keeps the session's write" eq "$(x 'git -C /work/repo config branch.main.remote')" "origin"
  check "git metadata stays on the normal disk" eq "$(x 'ls -d /mnt/zstd-overlay/upper/%work/repo/.git 2>/dev/null | wc -l')" 0
  check "a cache file written on both sides: the one from before the hook wins" eq "$(x 'cat /root/.npm/_cacache/index-v5/aa/bucket')" "two"
  check "the caches below the mount are empty" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && ls -A /tmp/r/root/.npm /tmp/r/root/.cache | grep -vc "^/\|^$"; umount /tmp/r')" 0
  check "new log files from both sides are all there" eq "$(x 'ls /root/.npm/_logs /root/.cache/cc/mcp-logs | grep -cE "[.](log|jsonl)$"')" 4
  check "git works: status, commit" xs "cd /work/repo && git status --short >/dev/null && echo more >> notes.txt && $commit -am more"
  # Still strict for work: a file the session wrote, changed again on the normal disk, is refused.
  restart
  xs 'echo outside > /work/repo/notes.txt'
  out=$(x "$ZO up; echo exit=\$?")
  check "a real conflict in the repository folder is still refused" has "$out" "NOT MOUNTED: /work changed"
  check "and names the file" has "$out" "/work/repo/notes.txt"
  check "the caches still mount" eq "$(mounts)" 4
  done_scenario
}

s15() {
  scenario 15 "migration: .git left in the image by an earlier version moves out without loss"
  start s15
  local commit='git -c user.email=t@t -c user.name=t commit -q'
  xs "cd /work/repo && git add -A && $commit -m base && $ZO up /root/.cache"   # creates the image
  # Mount /work the way versions before this one did: .git inside the overlay.
  xs "mkdir -p /mnt/zstd-overlay/upper/%work /mnt/zstd-overlay/work/%work
      mount -t overlay overlay -o lowerdir=/work,upperdir=/mnt/zstd-overlay/upper/%work,workdir=/mnt/zstd-overlay/work/%work /work
      touch /mnt/zstd-overlay/stamps/%work
      cd /work/repo && git config branch.main.remote origin && echo work > notes.txt && git add notes.txt && $commit -m session"
  check "precondition: the old layout has .git in the image" eq "$(x 'ls -d /mnt/zstd-overlay/upper/%work/repo/.git | wc -l')" 1
  restart
  xs 'git -C /work/repo config core.sshCommand platform-wrote-this'
  local out; out=$(x "$ZO up; echo exit=\$?")
  check "up exits 0" has "$out" "exit=0"
  check "it says what it moved" has "$out" "moved /work/repo/.git out of the image"
  check "the session's commit is there" eq "$(x 'git -C /work/repo log --format=%s -1')" "session"
  check "both config writes survive" eq "$(x 'git -C /work/repo config core.sshCommand; git -C /work/repo config branch.main.remote')" $'platform-wrote-this\norigin'
  check "no .git left in the image" eq "$(x 'ls -d /mnt/zstd-overlay/upper/%work/repo/.git 2>/dev/null | wc -l')" 0
  check "git fsck is clean" xs 'git -C /work/repo fsck --no-progress'
  done_scenario
}

s16() {
  scenario 16 "a cache folder below the mount stays empty: its files move into the image"
  start s16
  # What a cloud image ships in ~/.cache, ~/.local/share and the rest is on the normal disk.
  xs 'mkdir -p /root/.cache/uv/archive && head -c 5M /dev/urandom > /root/.cache/uv/archive/pkg.whl && yes cache | head -c 50M > /root/.cache/big.txt'
  local out; out=$(x "$ZO up; echo exit=\$?")
  check "up exits 0" has "$out" "exit=0"
  check "it says it moved the cache" has "$out" "from the normal disk into the image: /root/.cache"
  # uv clones (reflinks) cached files; overlayfs refuses that from the lower layer (EXDEV), which stopped uv.
  check "a reflink from a file the cache held before works" xs 'cp --reflink=always /root/.cache/uv/archive/pkg.whl /root/.cache/uv/clone.whl'
  check "nothing is left of it on the normal disk" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && ls -A /tmp/r/root/.cache | wc -l; umount /tmp/r')" 0
  check "the content is intact" eq "$(x 'wc -c < /root/.cache/big.txt')" 52428800
  out=$(x "$ZO up; echo exit=\$?")
  check "a second up moves nothing" eq "$(printf '%s\n' "$out" | grep -c 'into the image')" 0
  restart
  xs 'echo r > /root/.cache/written-before-the-hook.log'
  out=$(x "$ZO up --hook; echo exit=\$?")
  check "after a restart: the write from before the hook moves in, nothing refused" eq "$(printf '%s\n' "$out" | grep -c 'moved 1 files'):$(printf '%s\n' "$out" | grep -c 'not compressed'):$(mounts)" "1:0:5"
  check "the write from before the hook shows" eq "$(x 'cat /root/.cache/written-before-the-hook.log')" "r"
  check "the normal disk below the cache is empty again" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && ls -A /tmp/r/root/.cache | wc -l; umount /tmp/r')" 0
  done_scenario
}

s17() {
  scenario 17 "an old session: dd94e60 mounted the repository itself, then refused it on resume"
  start s17
  local commit='git -c user.email=t@t -c user.name=t commit -q'
  xs "cd /work/repo && git add -A && $commit -m base && $ZO up /root/.cache"   # creates the image
  # dd94e60 mounted the repository on its own (layer %work%repo) and ~/.npm (same layer name as now).
  xs "for d in /work/repo /root/.npm; do k=\${d//\//%}; mkdir -p \$d /mnt/zstd-overlay/upper/\$k /mnt/zstd-overlay/work/\$k
        mount -t overlay overlay -o lowerdir=\$d,upperdir=/mnt/zstd-overlay/upper/\$k,workdir=/mnt/zstd-overlay/work/\$k \$d; touch /mnt/zstd-overlay/stamps/\$k; done
      cd /work/repo && echo 'first period' > early.txt && echo 'first edit' >> README && git add -A && $commit -m 'first period'
      mkdir -p /root/.npm/_cacache && echo old > /root/.npm/_cacache/entry"
  restart
  # The resume refused both; the session went on working on the normal disk.
  xs 'sleep 1; cd /work/repo && echo "later edit" > README && echo later > late.txt && git config core.sshCommand platform
      mkdir -p /root/.npm/_cacache && echo new > /root/.npm/_cacache/entry'
  local out; out=$(x "$ZO up --hook; echo exit=\$?")
  check "the new version mounts everything, refuses nothing" eq "$(printf '%s' "$out" | grep -c 'not compressed'):$(mounts)" "0:5"
  check "it folded the old layer of the repository" has "$out" "folded the earlier layer of /work/repo"
  check "the later edit wins" eq "$(x 'cat /work/repo/README')" "later edit"
  check "work from both periods is there" eq "$(x 'cat /work/repo/early.txt /work/repo/late.txt')" $'first period\nlater'
  check "the first period's commit is there" eq "$(x 'git -C /work/repo log --format=%s -1')" "first period"
  check "both sides of .git/config" eq "$(x 'git -C /work/repo config core.sshCommand')" "platform"
  check "git fsck is clean" xs 'git -C /work/repo fsck --no-progress'
  check "the old layer is gone from the image" eq "$(x 'ls -d /mnt/zstd-overlay/upper/%work%repo 2>/dev/null | wc -l')" 0
  check "the cache keeps the newer file" eq "$(x 'cat /root/.npm/_cacache/entry')" "new"
  done_scenario
}

s18() {
  scenario 18 "a migration killed after the original was moved aside recovers, at each step"
  start s18
  xs "$ZO up /root/.cache"   # creates the image
  local sum='cd /root/.gradle && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16'
  local U=/mnt/zstd-overlay/upper/%root%.gradle
  # Build each state the code passes through between its rename and its final check, as a
  # kill (or a VM pause) would leave it, then run the command a session would run next.
  local step
  for step in renamed swapped; do
    xs "rm -rf /root/.gradle /root/.gradle.zstd-overlay-old $U $U.migrating /mnt/zstd-overlay/stamps/%root%.gradle*
        mkdir -p /root/.gradle/caches && for i in 1 2 3; do yes g\$i | head -c 5M > /root/.gradle/caches/f\$i; done"
    local before; before=$(x "$sum")
    xs "mkdir -p $U && cp -a /root/.gradle/. $U.migrating/ && mv /root/.gradle /root/.gradle.zstd-overlay-old && mkdir /root/.gradle"
    [ $step = swapped ] && xs "rm -rf $U && mv $U.migrating $U"
    local out; out=$(x "$ZO up; echo exit=\$?")
    check "killed after '$step': up recovers and says so" has "$out" "recovered an interrupted migration of /root/.gradle"
    check "killed after '$step': then moves it into the image" has "$out" $'into the image: /root/.gradle'
    check "killed after '$step': content intact" eq "$(x "$sum")" "$before"
    check "killed after '$step': nothing left over" eq "$(x "ls -d /root/.gradle.zstd-overlay-old $U.migrating 2>/dev/null | wc -l")" 0
    xs 'umount /root/.gradle 2>/dev/null; true'
  done
  done_scenario
}

s19() {
  scenario 19 "upgrade from 94085a131cbe: a leftover below a cache does not roll the image back"
  start s19
  xs "$ZO up"
  xs 'mkdir -p /root/.npm/_cacache/index && echo "appended while mounted" > /root/.npm/_cacache/index/bucket'
  restart
  # 94085a131cbe's merge left a copy below the mount, older than the mount that followed it.
  xs 'mkdir -p /root/.npm/_cacache/index && echo "stale copy" > /root/.npm/_cacache/index/bucket && sleep 1.1
      '"$ZO"' up /root/.cache >/dev/null && touch /mnt/zstd-overlay/stamps/%root%.npm'   # a later mount, as then
  local out; out=$(x "$ZO up --hook; echo exit=\$?")
  check "up exits 0, nothing refused" eq "$(printf '%s\n' "$out" | grep -c 'not compressed'):$(printf '%s\n' "$out" | tail -1)" "0:exit=0"
  check "the image's newer version stays" eq "$(x 'cat /root/.npm/_cacache/index/bucket')" "appended while mounted"
  check "the leftover is gone from below the mount" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && ls -A /tmp/r/root/.npm | wc -l; umount /tmp/r')" 0
  # `up | tail` from inside the repository: the pipe is up's own, not a process to restart.
  restart
  out=$(x "cd /work/repo && $ZO up | tail -40")
  check "up | tail: no process named as started before the mount" eq "$(printf '%s\n' "$out" | grep -c 'started earlier')" 0
  done_scenario
}

s20() {
  scenario 20 "CLAUDE.md, .claude/ and .mcp.json go back to the normal disk for the next start"
  start s20
  local below='mkdir -p /tmp/r && mount --bind / /tmp/r && cat /tmp/r/work/repo/CLAUDE.md; umount /tmp/r'
  xs "printf 'as cloned\n' > /work/repo/CLAUDE.md && $ZO up"
  # The session edits its instructions, its settings and some code; then the VM pauses.
  xs 'echo "edited in the session" > /work/repo/CLAUDE.md && mkdir -p /work/repo/.claude/rules && echo "{\"x\":1}" > /work/repo/.claude/settings.json && echo rule > /work/repo/.claude/rules/commits.md && echo code > /work/repo/src.py'
  restart
  check "before the hook, Claude Code would read the clone's CLAUDE.md" eq "$(x 'cat /work/repo/CLAUDE.md')" "as cloned"
  local out; out=$(x "$ZO up --hook; echo exit=\$?")
  check "up exits 0, nothing refused" eq "$(printf '%s\n' "$out" | grep -c 'not compressed'):$(printf '%s\n' "$out" | tail -1)" "0:exit=0"
  check "it wrote the three files back" has "$out" "wrote 3 startup files back to the normal disk"
  check "Claude is told to read the instructions again now, by name" \
    has "$(printf '%s\n' "$out" | grep 'read them again now')" "/work/repo/.claude/rules/commits.md"
  check "CLAUDE.md among them" has "$(printf '%s\n' "$out" | grep 'read them again now')" "/work/repo/CLAUDE.md"
  check "settings take effect at the next start" \
    has "$(printf '%s\n' "$out" | grep 'next start')" "/work/repo/.claude/settings.json"
  # Not the folder count: with zstd-overlay on the host, the container's /src is one of its
  # overlays too (see mounts()).
  check "the header comes first and explains the image" has "$(printf '%s\n' "$out" | head -1)" \
    "home folders are compressed (zstd) in an image"
  check "naming the folder that holds the repository" has "$(printf '%s\n' "$out" | head -1)" ": /work and "
  check "and the space outside it" has "$out" "Outside the image only"
  check "and the --merge rule" has "$out" "Never run \`zstd-overlay up --merge\` unless the user agreed"
  check "the normal disk now has the session's CLAUDE.md" eq "$(x "$below")" "edited in the session"
  check "and its .claude/settings.json" eq "$(x 'mkdir -p /tmp/r && mount --bind / /tmp/r && cat /tmp/r/work/repo/.claude/settings.json; umount /tmp/r')" '{"x":1}'
  check "the image holds neither any more" eq "$(x 'ls /mnt/zstd-overlay/upper/%work/repo/CLAUDE.md /mnt/zstd-overlay/upper/%work/repo/.claude 2>/dev/null | wc -l')" 0
  check "code stays in the image" eq "$(x 'cat /mnt/zstd-overlay/upper/%work/repo/src.py')" "code"
  check "the mounted view shows all three" eq "$(x 'cat /work/repo/CLAUDE.md /work/repo/src.py')" $'edited in the session\ncode'
  restart
  check "after the next restart, the start reads the current CLAUDE.md" eq "$(x 'cat /work/repo/CLAUDE.md')" "edited in the session"
  out=$(x "$ZO up --hook")
  check "and nothing is written back again" eq "$(printf '%s\n' "$out" | grep -c 'startup files')" 0
  # Still strict: the session edits CLAUDE.md again, and the normal disk's copy changes too.
  xs 'echo "second edit" > /work/repo/CLAUDE.md'
  restart
  xs 'echo "edited outside" > /work/repo/CLAUDE.md'
  out=$(x "$ZO up; echo exit=\$?")
  check "a real conflict on CLAUDE.md still refuses the repository folder" has "$out" "NOT MOUNTED: /work changed"
  # --merge: the normal disk's version must win, also for a startup file (review finding: the
  # write-back used to run first and replace it with the image's).
  out=$(x "$ZO up --merge /work; echo exit=\$?")
  check "--merge exits 0" has "$out" "exit=0"
  check "the normal disk's CLAUDE.md wins the merge" eq "$(x 'cat /work/repo/CLAUDE.md')" "edited outside"
  restart
  xs "$ZO up --hook"
  check "and is what the next start reads" eq "$(x 'cat /work/repo/CLAUDE.md')" "edited outside"
  done_scenario
}

s21() {
  scenario 21 "the built setup script (--embed): installs from the paste, names the commit, refuses a truncated paste"
  local built="$HERE/.setup-script.sh"
  if ! "$PROJ/build-setup-script.sh" --embed HEAD > "$built" 2>>"$LOG"; then echo "    SKIP  build-setup-script.sh failed (see log)"; SCN_SKIP=1; CT=""; done_scenario; return; fi
  start s21
  check "the built script is well under the paste field (under 40 KB of 64)" lt "$(wc -c < "$built")" 40960
  docker cp "$built" "$CT:/setup-script.sh" 2>>"$LOG"
  local out; out=$(x 'bash /setup-script.sh; echo exit=$?')
  check "the setup script runs install" has "$out" "installed /usr/local/bin/zstd-overlay"
  check "and exits 0" has "$out" "exit=0"
  out=$(x '/usr/local/bin/zstd-overlay version')
  check "version names the commit and its date" has "$out" "(commit $(git -C "$PROJ" rev-parse --short HEAD), 20"
  check "and the hash the script's header names" has "$out" "$(sed -n 's/.*zstd-overlay version prints \([0-9a-f]*\)).*/\1/p' "$built")"
  xs '/usr/local/bin/zstd-overlay up'   # the installed copy, not the source under /src
  check "the installed copy works: the default folders mount" eq "$(mounts)" 5
  stop
  # Cut inside the heredoc, and cut after it (the install line missing): both must fail loudly.
  local cut
  for cut in "head -c -3000" "sed \$d"; do
    start s21b
    $cut "$built" > "$HERE/.setup-script-cut.sh"
    docker cp "$HERE/.setup-script-cut.sh" "$CT:/setup-script.sh" 2>>"$LOG"
    out=$(x 'bash /setup-script.sh 2>&1; echo exit=$?')
    check "a paste cut short ($cut) exits non-zero" eq "$(printf '%s\n' "$out" | grep -c 'exit=0')" 0
    check "and says it is cut short" has "$out" "cut short"
    check "and installs nothing" eq "$(x 'ls /usr/local/bin/zstd-overlay /root/.claude/settings.json 2>/dev/null | wc -l')" 0
    stop
  done
  # No python3: the script must say so, not call the paste cut short.
  start s21c "$BARE"
  docker cp "$built" "$CT:/setup-script.sh" 2>>"$LOG"
  out=$(x 'bash /setup-script.sh 2>&1; echo exit=$?')
  check "without python3: names python3, exits non-zero" eq "$(printf '%s\n' "$out" | grep -c 'python3 is not installed'):$(printf '%s\n' "$out" | grep -c 'exit=0')" "1:0"
  check "and does not call the paste cut short" eq "$(printf '%s\n' "$out" | grep -c 'cut short')" 0
  rm -f "$HERE/.setup-script.sh" "$HERE/.setup-script-cut.sh"
  done_scenario
}

s22() {
  scenario 22 "the built setup script (download): fetches the pinned commit from GitHub and checks its hash"
  # Needs a commit that is on GitHub: ZO_FETCH_COMMIT names it (CI passes the pushed one).
  if [ -z "${ZO_FETCH_COMMIT:-}" ]; then echo "    SKIP  set ZO_FETCH_COMMIT to a commit that is on GitHub"; SCN_SKIP=1; CT=""; done_scenario; return; fi
  local built="$HERE/.setup-script.sh"
  if ! "$PROJ/build-setup-script.sh" "$ZO_FETCH_COMMIT" > "$built" 2>>"$LOG"; then echo "    SKIP  build-setup-script.sh failed (see log)"; SCN_SKIP=1; CT=""; done_scenario; return; fi
  start s22
  check "the script is short" lt "$(wc -c < "$built")" 2048
  docker cp "$built" "$CT:/setup-script.sh" 2>>"$LOG"
  local out; out=$(x 'bash /setup-script.sh 2>&1; echo exit=$?')
  check "the setup script downloads and installs" has "$out" "installed /usr/local/bin/zstd-overlay"
  check "and exits 0" has "$out" "exit=0"
  out=$(x '/usr/local/bin/zstd-overlay version')
  check "version names the pinned commit" has "$out" "(commit $(git -C "$PROJ" rev-parse --short=7 "$ZO_FETCH_COMMIT"), 20"
  check "and the hash the script names" has "$out" "$(sed -n 's/.*zstd-overlay version prints \([0-9a-f]*\)).*/\1/p' "$built")"
  xs '/usr/local/bin/zstd-overlay up'
  check "the installed copy works: the default folders mount" eq "$(mounts)" 5
  stop
  start s22b
  sed 's/^echo "[0-9a-f]*  /echo "0000000000000000000000000000000000000000000000000000000000000000  /' "$built" > "$HERE/.setup-script-cut.sh"
  docker cp "$HERE/.setup-script-cut.sh" "$CT:/setup-script.sh" 2>>"$LOG"
  out=$(x 'bash /setup-script.sh 2>&1; echo exit=$?')
  check "a wrong hash in the script exits non-zero" eq "$(printf '%s\n' "$out" | grep -c 'exit=0')" 0
  check "and installs nothing" eq "$(x 'ls /usr/local/bin/zstd-overlay 2>/dev/null | wc -l')" 0
  rm -f "$HERE/.setup-script.sh" "$HERE/.setup-script-cut.sh"
  done_scenario
}

s23() {
  scenario 23 "the image fills while the caches move in: no file is lost or truncated"
  start s23
  # Field report (2026-11-05): 0.2.1 left the file it was copying truncated in a full image,
  # dated the stamp anyway, and the next up deleted the intact original as a leftover. The
  # image must be big enough (2.5 GiB) for btrfs to keep metadata apart from data: then a file
  # is created and its write fails, which is what left the truncated copies. 3 GiB of random
  # data fill the data space while ~/.cache moves in; ~/.npm's file is created and fails too.
  xs 'mkdir -p /root/.cache/big /root/.npm && for i in $(seq 1 30); do head -c 100M /dev/urandom > /root/.cache/big/r$i; done
      head -c 50M /dev/urandom > /root/.npm/blob && echo "version = 12" > /root/.npm/settings.toml'
  local before; before=$(x 'cd /root && find .cache .npm -type f -exec sha256sum {} + | sort -k2')
  local out; out=$(x "ZSTD_OVERLAY_RESERVE_MB=\$((\$(df -B1M --output=avail / | tail -1) - 2560)) $ZO up 2>&1; echo exit=\$?")
  check "the first up runs out of space" has "$out" "No space left on device"
  check "and leaves no partial copy in the image" eq "$(x 'find /mnt/zstd-overlay/upper -name .zstd-overlay-partial | wc -l')" 0
  out=$(x "$ZO up 2>&1; echo exit=\$?")
  check "the next up, with room, exits 0" has "$out" "exit=0"
  check "and mounts ~/.cache and ~/.npm" eq "$(x 'findmnt -rn -t overlay -o TARGET | grep -cxE "/root/.cache|/root/.npm"')" 2
  check "every file is whole, by SHA-256" eq "$(x 'cd /root && find .cache .npm -type f -exec sha256sum {} + | sort -k2')" "$before"
  done_scenario
}

# --- main ------------------------------------------------------------------------

[ "$(id -u)" = 0 ] || { echo "run as root (privileged containers)"; exit 2; }
build_images || { echo "could not build the test images; see $LOG"; exit 2; }
want=("$@"); [ ${#want[@]} -gt 0 ] || want=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)
for n in "${want[@]}"; do "s$n"; done
echo; echo "== $PASS passed, $FAIL failed, $SKIP skipped (log: $LOG)"; printf '   %s\n' "${RESULTS[@]}"
[ "$FAIL" = 0 ]
