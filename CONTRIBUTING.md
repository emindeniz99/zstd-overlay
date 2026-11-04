# Contributing

## Commits

Conventional Commits, with a scope, always:

```
<type>(<scope>): <subject>

[body: why, wrapped at 72]

[trailers]
```

- Types: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, `revert`.
- Scopes are areas of this repository: `tool` (the `zstd-overlay` file), `tests` (`tests/`), `setup-script` (`build-setup-script.sh`), `docs`, `ci`, `repo`.
- Subject in the imperative, lowercase, no trailing period, the whole header at most 72 characters.
- A body when the why is not in the diff: the problem, the cause, what changed and why, how it was checked.
- An AI assistant that materially wrote a commit is named in a `Co-Authored-By:` trailer, with the model's current name.

## Merging

Merge with a real merge commit (`git merge --no-ff`, or GitHub's "merge" button). Never squash and never rebase-merge: the per-commit history is the record of how the tool was built and tested, and the evidence note cites commits.

## Checks

```bash
mise run check     # format, lint, types, the unit tests with coverage (needs mise and uv)
mise run matrix    # the unit tests on Python 3.11 to 3.14
sudo tests/run.sh  # the Docker scenarios (root, Docker, a kernel with btrfs and overlayfs)
```

A behavior change comes with a test that fails without it. A measured finding goes into `docs/evidence/` with the script that produced it.

## Privacy

Nothing that identifies a user, a machine or an account goes into the repository: no session ids, hostnames or paths beyond the maintainer's own attribution, and no real repository content in fixtures.
