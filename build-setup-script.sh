#!/bin/bash
# Writes the cloud environment setup script for a commit of this project to stdout:
# the tool, taken with `git archive` so its version line names the commit and date,
# wrapped in a heredoc, then `install`. Paste the output into the environment's
# setup script (claude.ai/code, environment settings).
#
#   projects/zstd-overlay/build-setup-script.sh [commit] > setup-script.sh
#
# The hash `zstd-overlay version` prints is the hash of this output's embedded
# file, not of the checkout's: the commit line differs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
commit=${1:-HEAD}
repo=$(git -C "$here" rev-parse --show-toplevel)
path=$(realpath --relative-to="$repo" "$here/zstd-overlay")
tool=$(git -C "$repo" archive "$commit" "$path" | tar -xOf - "$path")
grep -qx 'ZSTD_OVERLAY_EOF' <<<"$tool" && { echo "the tool contains the heredoc delimiter" >&2; exit 1; }
grep -q '^COMMIT = "\$Format' <<<"$tool" && { echo "git archive did not fill in the commit (is .gitattributes committed?)" >&2; exit 1; }
printf '#!/bin/bash\n# Claude Code cloud environment setup script: installs zstd-overlay and its SessionStart hook.\n'
printf '# It creates no image; the image appears at session start. Built from %s %s.\n\n' "$path" "$(git -C "$repo" rev-parse --short "$commit")"
printf "cat > /tmp/zstd-overlay <<'ZSTD_OVERLAY_EOF'\n%s\nZSTD_OVERLAY_EOF\npython3 /tmp/zstd-overlay install\n" "$tool"
