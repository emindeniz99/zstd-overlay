# Rules for AI assistants

This is the one source of truth for coding agents (Codex reads it natively; `CLAUDE.md` imports it with `@AGENTS.md`). `CONTRIBUTING.md` is the human-facing version; where they overlap, they agree.

Read `MEMORY.md` before non-trivial work and record decisions and learnings there after.

## Commits and merges

- Conventional Commits with a scope, always: `feat(tool): …`, `fix(tests): …`, `docs(repo): …`. Scopes: `tool`, `tests`, `setup-script`, `docs`, `ci`, `repo`. Imperative subject, lowercase, no trailing period, header at most 72 characters; a body that explains why.
- Name the model in a `Co-Authored-By:` trailer on every commit you materially wrote. Keep the name current.
- Merge with a real merge commit. Never squash, never rebase-merge, never force-push a shared branch, never amend a pushed commit.

## The tool

- `zstd-overlay` is one Python 3.11+ file, standard library only, and the empty btrfs filesystem ships inside it as a blob. The kernel does the rest: no btrfs-progs, no downloads.
- No write made while a folder was unmounted is ever hidden under the image. The repository folder refuses on a conflict; `up --merge` is for the user to decide, never run it on your own.
- Every behavior change has a unit test that fails without it (`tests/test_logic.py`), and what the kernel does is covered by a Docker scenario (`tests/run.sh`). Run `mise run check` before committing; run the scenarios for anything that touches mounting, absorbing, merging, the image or the setup script.
- A measured finding goes into `docs/evidence/` with its script. A claim nobody can rerun is not evidence.
- `build-setup-script.sh` is the only way to build the environment's setup script. Never hand-edit a built script.

## Releases

- release-please owns the version: never edit `version.txt` and the `VERSION` line in `zstd-overlay` by hand, and never create a tag or a release by hand; merge the release PR. Its commit types decide the bump, so a behavior change is a `feat` or a `fix`, never a `chore`; and a change to a workflow or to the tests is `ci` or `test`, never `fix`, which would cut a release that ships nothing new (it reads the type, not the scope).

## Privacy

No session ids, hostnames, account names or paths that identify a user or a machine, in files, commit messages or notes. The maintainer's own attribution is the one exception.
