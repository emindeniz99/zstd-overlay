#!/bin/bash
# Writes the cloud environment setup script for a commit of this project to stdout.
# Paste the output into the environment's setup script (claude.ai/code, the
# environment's settings). The script is the tool itself in a heredoc, readable as
# pasted, then a SHA-256 check and `install`. The field holds about 64 KB; the
# output is about 58 KB, and the check in the output's header says how much room
# is left.
#
#   projects/zstd-overlay/build-setup-script.sh [commit] > setup-script.sh
#
# The tool is taken with `git archive`, so `zstd-overlay version` names the commit
# and its date. Its hash is of that file, not of the checkout's: the commit line
# differs. The header names the hash, so a session's `version` can be checked
# against the script it came from. A paste cut short ends inside the heredoc:
# bash runs the `cat` with what it has and the script ends, with exit 0, having
# installed nothing. The EXIT trap set before the heredoc turns that into exit 1
# with a message. A paste altered on the way fails the hash check. Either way
# nothing is installed, and the platform reports a failed setup.
set -euo pipefail
LIMIT=65536
here=$(cd "$(dirname "$0")" && pwd)
commit=${1:-HEAD}
repo=$(git -C "$here" rev-parse --show-toplevel)
path=$(realpath --relative-to="$repo" "$here/zstd-overlay")
sha=$(git -C "$repo" rev-parse --short "$commit")
tool=$(git -C "$repo" archive "$commit" "$path" | tar -xOf - "$path")
grep -q '^COMMIT = "\$Format' <<<"$tool" && { echo "git archive did not fill in the commit (is .gitattributes committed?)" >&2; exit 1; }
grep -qx 'ZSTD_OVERLAY_EOF' <<<"$tool" && { echo "the tool contains the heredoc delimiter" >&2; exit 1; }
hash=$(printf '%s\n' "$tool" | sha256sum | cut -d' ' -f1)
out=$(cat <<SCRIPT
#!/bin/bash
# Claude Code cloud environment setup script: installs zstd-overlay and its SessionStart hook.
# It creates no image; the image appears at session start.
# Built from $path at $sha by build-setup-script.sh. The file below has SHA-256
# $hash (zstd-overlay version prints ${hash:0:12}).
heredoc=incomplete
trap '[ "\$heredoc" = complete ] || { echo "zstd-overlay: the setup script is cut short (the paste did not reach its end); nothing installed" >&2; exit 1; }' EXIT
cat > /tmp/zstd-overlay <<'ZSTD_OVERLAY_EOF'
$tool
ZSTD_OVERLAY_EOF
heredoc=complete
echo "$hash  /tmp/zstd-overlay" | sha256sum -c --quiet || { echo "zstd-overlay: the pasted file is not the one built from $sha; nothing installed" >&2; exit 1; }
python3 /tmp/zstd-overlay install
SCRIPT
)
size=$(( ${#out} + 1 ))
[ "$size" -lt "$LIMIT" ] || { echo "the setup script is $size bytes, over the field's $LIMIT; ship it compressed or trim the tool" >&2; exit 1; }
printf '%s\n' "$out"
echo "setup script: $size bytes, $((LIMIT - size)) under the field's $LIMIT" >&2
