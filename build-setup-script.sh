#!/bin/bash
# Writes the cloud environment setup script for a commit of this project to stdout.
# Paste the output into the environment's setup script (claude.ai/code, the
# environment's settings).
#
#   build-setup-script.sh [commit]            a short script that downloads the tool at
#                                             that commit from GitHub and checks its SHA-256
#   build-setup-script.sh --embed [commit]    the tool itself, xz-compressed and base64-
#                                             encoded, for an environment that cannot
#                                             reach github.com (about 30 KB of the field's
#                                             64 KB)
#
# Both take the tool with `git archive`, so `zstd-overlay version` names the commit
# and its date, and both check the file's SHA-256 before `install`. The download
# is GitHub's archive of the commit, which fills in the commit line as git archive
# does, so the bytes and the hash are the ones computed here; the commit must be
# on GitHub. An EXIT trap turns a paste cut short, anywhere, into exit 1 with a
# message, so the platform reports a failed setup. The output is reproducible:
# the same commit gives the same script.
set -euo pipefail
REPO=emindeniz99/zstd-overlay
LIMIT=65536
here=$(cd "$(dirname "$0")" && pwd)
mode=fetch
[ "${1:-}" = --embed ] && { mode=embed; shift; }
commit=${1:-HEAD}
repo=$(git -C "$here" rev-parse --show-toplevel)
path=$(realpath --relative-to="$repo" "$here/zstd-overlay")
full=$(git -C "$repo" rev-parse --verify "$commit^{commit}")  # ^{commit}: a tag names its commit, not the tag object
sha=${full:0:7}
date=$(git -C "$repo" log -1 --format=%cI "$full")
tool=$(git -C "$repo" archive "$full" "$path" | tar -xOf - "$path")
grep -q '^COMMIT = "\$Format' <<<"$tool" && { echo "git archive did not fill in the commit (is .gitattributes committed?)" >&2; exit 1; }
hash=$(printf '%s\n' "$tool" | sha256sum | cut -d' ' -f1)
header="#!/bin/bash
# Claude Code cloud environment setup script: installs zstd-overlay and its SessionStart hook.
# It creates no image; the image appears at session start."
# The file goes to a fresh temporary name, removed on every exit: a fixed path under /tmp could
# be a symlink or a directory already, and the script runs as root.
trap_line="trap '[ -n \"\${tool:-}\" ] && rm -f \"\$tool\"; [ \"\$reached_end\" = yes ] || { echo \"zstd-overlay: the setup script is cut short (the paste did not reach its last line); paste the whole script again\" >&2; exit 1; }' EXIT"
tmp_line="tool=\$(mktemp /tmp/zstd-overlay.XXXXXX) || { reached_end=yes; exit 1; }"
# The tool needs python3, and the trap must not blame a missing one on a cut paste.
python_line="command -v python3 >/dev/null || { echo \"zstd-overlay: python3 is not installed; nothing installed\" >&2; reached_end=yes; exit 1; }"
install_line="python3 \"\$tool\" install; rc=\$?; reached_end=yes; exit \$rc"
if [ "$mode" = fetch ]; then
  out=$(cat <<SCRIPT
$header
# Downloads $path at commit $sha ($date) from github.com/$REPO, as GitHub's archive of
# that commit, and checks its SHA-256 before install:
#   $hash  (zstd-overlay version prints ${hash:0:12})
# Built by build-setup-script.sh in that repository; the same commit gives the same script.
reached_end=no
$trap_line
$python_line
$tmp_line
curl -fsSL "https://github.com/$REPO/archive/$full.tar.gz" | tar -xzOf - "zstd-overlay-$full/$path" > "\$tool" \\
  || { echo "zstd-overlay: could not download commit $sha from github.com/$REPO; nothing installed" >&2; reached_end=yes; exit 1; }
echo "$hash  \$tool" | sha256sum -c --quiet || { echo "zstd-overlay: the downloaded file is not the one built from $sha; nothing installed" >&2; reached_end=yes; exit 1; }
$install_line
SCRIPT
)
else
  payload=$(printf '%s\n' "$tool" | xz -9e --format=xz | base64 -w 76)
  # The module docstring, as a comment: from line 2 to the closing quotes.
  # awk reads all of its input: an early exit left printf with a broken pipe, which pipefail
  # turned into a failure on the CI runner.
  help=$(printf '%s\n' "$tool" | awk 'NR==2{sub(/^"""/,"")} NR>=2 && !done {if($0=="\"\"\""){done=1} else print "#   " $0}')
  out=$(cat <<SCRIPT
$header
# Built from $path at $sha ($date) by build-setup-script.sh --embed. The code is
# xz-compressed and base64-encoded below (the field holds 64 KB; the plain file passed it).
# python3 decodes it and checks its SHA-256 before install:
#   $hash  (zstd-overlay version prints ${hash:0:12})
# To read the file: \`git show $sha:$path\` in the repository, or decode the payload:
#   python3 -c 'import base64,lzma,sys;sys.stdout.buffer.write(lzma.decompress(base64.b64decode(sys.stdin.read())))'
#
# What it does (the tool's --help):
$help
reached_end=no
$trap_line
$python_line
$tmp_line
ZSTD_OVERLAY_FILE="\$tool" python3 - <<'ZSTD_OVERLAY_PY' || { [ \$? = 3 ] && reached_end=yes; exit 1; }  # 3: the hash or decode check; else a cut
import base64, hashlib, lzma, os, sys
PAYLOAD = """
$payload
"""
try:
    tool = lzma.decompress(base64.b64decode(PAYLOAD))
except Exception as e:
    print(f"zstd-overlay: the payload does not decode ({e}); the paste is altered. Nothing installed.", file=sys.stderr)
    sys.exit(3)
if hashlib.sha256(tool).hexdigest() != "$hash":
    print("zstd-overlay: the decoded file's SHA-256 is not $hash; the paste is altered. Nothing installed.", file=sys.stderr)
    sys.exit(3)
with open(os.environ["ZSTD_OVERLAY_FILE"], "wb") as f:
    f.write(tool)
ZSTD_OVERLAY_PY
$install_line
SCRIPT
)
fi
size=$(printf '%s\n' "$out" | wc -c)  # bytes, as the field counts them
[ "$size" -lt "$LIMIT" ] || { echo "the setup script is $size bytes, over the field's $LIMIT" >&2; exit 1; }
printf '%s\n' "$out"
echo "setup script ($mode): $size bytes" >&2
