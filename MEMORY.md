# MEMORY — zstd-overlay

## Now

- 2026-11-03: 94085a131cbe runs in both sessions of the environment: the old one was fixed by hand (layer folded, 12,769 npm files merged, nothing refused), this one resumed at 06:37 with nothing refused or moved again. Open: the old session's next resume; the final setup script pasted into both environments; the PR.
- 2026-11-02: Python version: `zstd-overlay` (up, migrate, install, status, doctor), 44 unit tests (`mise run check`, `mise run matrix`) and `tests/run.sh` (13 Docker scenarios). 2026-11-03: works through a real environment's setup script (hook ran at start; 200 MB of text cost 7 MB). Hook on `resume` observed working (9fdf465928aa, this session, 05:45).
- Next: graduate to a public repo so setup scripts can `curl` it (this repo is private).

## Decisions

- 2026-11-03: a cache folder stays empty on the normal disk: before each mount, everything there moves into the image (owner: "merging into a cache is silly"). Replaces the newer-wins merge and the one-time migration with its marker; what was written while unmounted is the newest by construction. The repository folder stays strict and keeps its files on the normal disk: Claude Code reads CLAUDE.md, .claude/ and .mcp.json there before the hook, and the platform writes .git.

- 2026-11-03: a conflict is a file written while unmounted that the image also has a version of (it would be hidden); the repository folder refuses on one, the default home folders (caches) take the newer file. Each `.git` stays on the normal disk, bind-mounted: the platform rewrites every `.git/config` on resume, before any hook, so the old rule refused the repository folder on every resume (field report, reproduced as scenario 14).

- 2026-11-02: btrfs `compress-force=zstd:3` under overlayfs, kernel features only: zstd:3 was the best writable ratio per write cost of 15 configurations measured; squashfs/erofs/DwarFS are read-only ([evidence](docs/evidence/2026-11-02-cloud-session-measurements.md)).
- 2026-11-02: the image is preallocated (`fallocate`, `nodiscard`) and leaves 4 GiB outside: a sparse image turned read-only when the disk filled from outside.
- 2026-11-02: a folder written while unmounted is refused, not merged (owner's choice, "B"); `--merge` exists for after a look.
- 2026-11-02: `install` never creates the image: a snapshot of a container with a 1 GiB reserved image grew by 1 GiB (scenario 12).
- 2026-11-02: the empty btrfs ships as a base64 blob at the end of the script: the kernel cannot format btrfs and `mkfs.btrfs` is not in the base image; resizing uses `BTRFS_IOC_RESIZE` from Python's `fcntl.ioctl`.
- 2026-11-03: the default list covers the folder holding the repository (/home/user in a cloud session), not the repository: repositories attached later land next to it (owner: "every repo, also future attached ones"). `migrate` refuses that folder too.
- 2026-11-02: rewritten from bash to Python 3.11+ stdlib, one file (owner: "a well-tested tool deserves a real language"): unit tests for the logic, no perl/jq fallbacks; a cloud session has Python 3.13. The bash version (0253ed0) passed all 13 scenarios first; the scenarios are language-independent and gate the rewrite.

## Learnings

- 2026-11-03: 94085a131cbe's newer-wins merge copied files into the image but left them below the mount (12,852 under ~/.npm); absorb then took those stale copies for new writes. absorb now drops a file that predates the last mount when the image has its own version (field report, scenario 19).

- 2026-11-03: a killed migration that had already renamed the original to `.zstd-overlay-old` left the folder looking empty and the next migrate crashed (ENOTEMPTY); no data lost. Fix: recover before mounting (scenario 18). The first version of that recovery also fired inside migrate's own final mount and undid it; migrate's remount now skips recovery.

- 2026-11-03: a running session never gets a changed setup script (it runs only for the environment cache); update it by hand. A session still on dd94e60 keeps the repository's own layer (%home%user%playground) while the new default mounts /home/user, so `up` folds nested old layers into the normal disk (scenario 17).
- 2026-11-03: a VM resume stops dockerd too; restart it before `tests/run.sh`.

- 2026-11-03: overlayfs refuses FICLONE from a lower-layer file (EXDEV) while reporting one st_dev; uv 0.13 then stops ("Failed to clone"). Fix: a cache folder's first mount migrates its content into the image (marker `stamps/<key>.migrated`).
- 2026-11-03: a session that runs zstd-overlay leaves only its reserve (4 GiB) free; Docker tests there need `ZSTD_OVERLAY_RESERVE_MB=16384 zstd-overlay up` first, which shrank the live image 25 -> 13 GB in under a second.

- 2026-11-03: written before the SessionStart hook on every resume: each repository's `.git/config` (the platform, 4 s after boot), `~/.npm/_logs` and `_cacache` (`npm exec` MCP servers), `~/.cache/claude-cli-nodejs/*/mcp-logs-*` (Claude Code). No earlier mount point exists: the setup script runs only for the cache, PID 1 is `process_api`.
- 2026-11-03: the environment embeds the setup script as pasted; it never fetches the tool. A stale install means a stale paste; `zstd-overlay version` and `doctor` print the file's hash.

- 2026-11-03: the platform docs say cloud sessions run only server-managed and repository hooks; a hook in the VM's own `~/.claude/settings.json`, written by the setup script, ran anyway. Revisit if a session starts with nothing mounted.

- 2026-11-02: a cloud session's VM restarted three times in one idle day; files stay, mounts go. The SessionStart hook is what makes this work.
- 2026-11-02: shrink btrfs in 256 MiB steps; one big step fails with ENOSPC when empty block groups sit above the new end.
- 2026-11-02: after a delete in a full image, btrfs offers the space again after 1–15 s; tests must wait, not expect it at once.
- 2026-11-02: overlayfs refuses reflinks between two mounts; pnpm and uv fall back to compressed copies.
- 2026-11-02: in Docker tests, a proxy on 127.0.0.1 needs `--network host`; `> file 2>&1` sends the error message into the file.
- 2026-11-02: Claude Code resolves its working directory per command, so commands after the hook see the mount; processes started earlier keep the old folder.
- 2026-11-02: Claude Code reads a SessionStart hook's stdout only on exit 0; a refusal reported with exit 3 would reach nobody. Hence `up --hook`: exit 0, JSON `systemMessage` + `additionalContext`.

## Done

- 2026-11-02: rewritten in Python with unit tests.
- 2026-11-02: project created; script, harness, README, evidence.
