#!/bin/bash
# Writes the cloud environment setup script for a commit of this project to stdout.
# Paste the output into the environment's setup script (claude.ai/code, the
# environment's settings).
#
#   projects/zstd-overlay/build-setup-script.sh [commit] > setup-script.sh
#
# The field holds 64 KB and the plain tool passed it (64,282 bytes at dee02d7), so
# the code travels xz-compressed and base64-encoded, about 30 KB, and python3,
# which the tool needs anyway, decodes it. What can be read is in the output's
# header: the commit and its date, the SHA-256 of the decoded file (which
# `zstd-overlay version` prints the start of), and the tool's --help text. The
# script checks the SHA-256 before it runs `install`, so an altered paste installs
# nothing, and an EXIT trap turns a paste cut short, anywhere, into exit 1 with a
# message, so the platform reports a failed setup.
#
# The tool is taken with `git archive`, so `zstd-overlay version` names the commit
# and its date; its hash is of that file, not of the checkout's. The output is
# reproducible: the same commit gives the same bytes.
set -euo pipefail
LIMIT=65536
here=$(cd "$(dirname "$0")" && pwd)
commit=${1:-HEAD}
repo=$(git -C "$here" rev-parse --show-toplevel)
path=$(realpath --relative-to="$repo" "$here/zstd-overlay")
sha=$(git -C "$repo" rev-parse --short "$commit")
date=$(git -C "$repo" log -1 --format=%cI "$commit")
tool=$(git -C "$repo" archive "$commit" "$path" | tar -xOf - "$path")
grep -q '^COMMIT = "\$Format' <<<"$tool" && { echo "git archive did not fill in the commit (is .gitattributes committed?)" >&2; exit 1; }
hash=$(printf '%s\n' "$tool" | sha256sum | cut -d' ' -f1)
payload=$(printf '%s\n' "$tool" | xz -9e --format=xz | base64 -w 76)
# The module docstring, as a comment: from line 2 to the closing quotes.
help=$(printf '%s\n' "$tool" | awk 'NR==2{sub(/^"""/,"")} NR>=2{if($0=="\"\"\"")exit; print "#   " $0}')
out=$(cat <<SCRIPT
#!/bin/bash
# Claude Code cloud environment setup script: installs zstd-overlay and its SessionStart hook.
# It creates no image; the image appears at session start.
# Built from $path at $sha ($date) by build-setup-script.sh. The code is
# xz-compressed and base64-encoded below (the field holds 64 KB; the plain file passed it).
# python3 decodes it and checks its SHA-256 before install:
#   $hash  (zstd-overlay version prints ${hash:0:12})
# To read the file: \`git show $sha:$path\` in the repository, or decode the payload:
#   python3 -c 'import base64,lzma,sys;sys.stdout.buffer.write(lzma.decompress(base64.b64decode(sys.stdin.read())))'
#
# What it does (the tool's --help):
$help
reached_end=no
trap '[ "\$reached_end" = yes ] || { echo "zstd-overlay: the setup script is cut short (the paste did not reach its last line); paste the whole script again" >&2; exit 1; }' EXIT
python3 - <<'ZSTD_OVERLAY_PY' || { [ \$? = 3 ] && reached_end=yes; exit 1; }  # 3: the hash check; else a cut
import base64, hashlib, lzma, os, sys
PAYLOAD = """
$payload
"""
tool = lzma.decompress(base64.b64decode(PAYLOAD))
if hashlib.sha256(tool).hexdigest() != "$hash":
    print("zstd-overlay: the decoded file's SHA-256 is not $hash; the paste is altered. Nothing installed.", file=sys.stderr)
    sys.exit(3)
with open("/tmp/zstd-overlay", "wb") as f:
    f.write(tool)
os.chmod("/tmp/zstd-overlay", 0o755)
ZSTD_OVERLAY_PY
python3 /tmp/zstd-overlay install; rc=\$?; reached_end=yes; exit \$rc
SCRIPT
)
size=$(printf '%s\n' "$out" | wc -c)  # bytes, as the field counts them
[ "$size" -lt "$LIMIT" ] || { echo "the setup script is $size bytes, over the field's $LIMIT" >&2; exit 1; }
printf '%s\n' "$out"
echo "setup script: $size bytes, $((LIMIT - size)) under the field's $LIMIT" >&2
