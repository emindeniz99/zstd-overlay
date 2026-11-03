#!/bin/bash
# Writes the cloud environment setup script for a commit of this project to stdout.
# Paste the output into the environment's setup script (claude.ai/code, the
# environment's settings). The field has a size limit the plain file reached
# (64,286 bytes at ca8178c), so the tool travels xz-compressed and base64-encoded,
# about 27 KB, and python3, which the tool needs anyway, decodes it. The script
# checks the decoded file's SHA-256 before it runs `install`: a truncated or
# altered paste stops with a message and installs nothing.
#
#   projects/zstd-overlay/build-setup-script.sh [commit] > setup-script.sh
#
# The tool is taken with `git archive`, so `zstd-overlay version` names the commit
# and its date. Its hash is of that file, not of the checkout's: the commit line
# differs. The header of the output names the hash, so a session's `version` can
# be checked against the script it came from.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
commit=${1:-HEAD}
repo=$(git -C "$here" rev-parse --show-toplevel)
path=$(realpath --relative-to="$repo" "$here/zstd-overlay")
sha=$(git -C "$repo" rev-parse --short "$commit")
tool=$(git -C "$repo" archive "$commit" "$path" | tar -xOf - "$path")
grep -q '^COMMIT = "\$Format' <<<"$tool" && { echo "git archive did not fill in the commit (is .gitattributes committed?)" >&2; exit 1; }
hash=$(printf '%s\n' "$tool" | sha256sum | cut -d' ' -f1)
payload=$(printf '%s\n' "$tool" | xz -9e --format=xz | base64 -w 76)
cat <<HEADER
#!/bin/bash
# Claude Code cloud environment setup script: installs zstd-overlay and its SessionStart hook.
# It creates no image; the image appears at session start.
# Built from $path at $sha by build-setup-script.sh; the tool is xz-compressed and
# base64-encoded below, with SHA-256 $hash (zstd-overlay version prints ${hash:0:12}).
# To see the file: python3 -c 'import base64,lzma,sys; sys.stdout.buffer.write(lzma.decompress(base64.b64decode(sys.stdin.read())))' < payload
python3 - <<'ZSTD_OVERLAY_PY'
import base64, hashlib, lzma, os, subprocess, sys
PAYLOAD = """
$payload
"""
tool = lzma.decompress(base64.b64decode(PAYLOAD))
if hashlib.sha256(tool).hexdigest() != "$hash":
    sys.exit("zstd-overlay: the decoded file's SHA-256 is not $hash; the paste is truncated or altered. Nothing installed.")
with open("/tmp/zstd-overlay", "wb") as f:
    f.write(tool)
os.chmod("/tmp/zstd-overlay", 0o755)
sys.exit(subprocess.run([sys.executable, "/tmp/zstd-overlay", "install"]).returncode)
ZSTD_OVERLAY_PY
HEADER
