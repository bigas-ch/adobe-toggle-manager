# Contributing

Thanks for your interest in Adobe Toggle Manager. This is a zsh project
with a small native Swift helper; contributions are welcome via pull
request.

## Development setup

```bash
git clone https://github.com/bigas-ch/adobe-toggle-manager.git
cd adobe-toggle-manager
brew install bats-core
```

`fzf` is needed only to exercise the whitelist picker
(`brew install fzf`), and the Xcode Command Line Tools only to build the
FSEvents watcher (`xcode-select --install`).

## Running the tests

The test suite is [bats](https://github.com/bats-core/bats-core):

```bash
bats tests/
```

All unit tests must pass before a change is merged. Integration and
end-to-end checks are exercised through the TUI and the CI E2E job.

### Faster local runs (optional)

```bash
brew install parallel
./scripts/run-tests.sh
```

`scripts/run-tests.sh` auto-detects GNU `parallel` and runs bats with up
to 8 jobs; it falls back to sequential execution if `parallel` is missing.

## Coding conventions

- **zsh**, not bash. Keep functions small and single-purpose.
- Address system tools by absolute path; do not rely on the user's `PATH`.
- Add or update bats tests for any behaviour change.
- Run `bats tests/` and confirm it is green before opening a PR.

## Pull requests

1. Fork and branch from `main`.
2. Make your change with accompanying tests.
3. Ensure `bats tests/` passes.
4. Open a PR describing the change and the motivation.

Security issues should **not** be filed as public PRs or issues — see
[SECURITY.md](SECURITY.md).
