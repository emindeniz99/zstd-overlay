# MEMORY — zstd-overlay

## Now

- 2026-11-02: first version done: `zstd-overlay` (up, migrate, install, status, doctor) and `tests/run.sh` (13 Docker scenarios, all passing). Not yet used through a real cloud environment's setup script; the first session that does should run `zstd-overlay doctor` and record whether the hook fired on `resume` and the snapshot kept `~/.claude/settings.json`.
- Next: graduate to a public repo so setup scripts can `curl` it (this repo is private).

## Decisions

- 2026-11-02: btrfs `compress-force=zstd:3` under overlayfs, kernel features only: zstd:3 was the best writable ratio per write cost of 15 configurations measured; squashfs/erofs/DwarFS are read-only ([evidence](docs/evidence/2026-11-02-cloud-session-measurements.md)).
- 2026-11-02: the image is preallocated (`fallocate`, `nodiscard`) and leaves 4 GiB outside: a sparse image turned read-only when the disk filled from outside.
- 2026-11-02: a folder written while unmounted is refused, not merged (owner's choice, "B"); `--merge` exists for after a look.
- 2026-11-02: `install` never creates the image: a snapshot of a container with a 1 GiB reserved image grew by 1 GiB (scenario 12).
- 2026-11-02: the empty btrfs ships as a base64 blob at the end of the script: the kernel cannot format btrfs and `mkfs.btrfs` is not in the base image; resizing uses `BTRFS_IOC_RESIZE` through perl.

## Learnings

- 2026-11-02: a cloud session's VM restarted three times in one idle day; files stay, mounts go. The SessionStart hook is what makes this work.
- 2026-11-02: shrink btrfs in 256 MiB steps; one big step fails with ENOSPC when empty block groups sit above the new end.
- 2026-11-02: after a delete in a full image, btrfs offers the space again after 1–15 s; tests must wait, not expect it at once.
- 2026-11-02: overlayfs refuses reflinks between two mounts; pnpm and uv fall back to compressed copies.
- 2026-11-02: in Docker tests, a proxy on 127.0.0.1 needs `--network host`; `> file 2>&1` sends the error message into the file.
- 2026-11-02: Claude Code resolves its working directory per command, so commands after the hook see the mount; processes started earlier keep the old folder.
- 2026-11-02: Claude Code reads a SessionStart hook's stdout only on exit 0; a refusal reported with exit 3 would reach nobody. Hence `up --hook`: exit 0, JSON `systemMessage` + `additionalContext`.

## Done

- 2026-11-02: project created; script, harness, README, evidence.
