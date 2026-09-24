# Contributing

Issues and pull requests are welcome.

## Build and test

```sh
make build            # build the image
make test             # build and run the integration tests
make test-migration   # 2.4 to 2.6 migration test
make test-arch        # arm64 smoke test under emulation
make coverage         # line coverage of entrypoint.sh and reload-tls.sh
make lint             # contract + shellcheck + hadolint
```

CI runs for every pull request: ShellCheck, Hadolint, actionlint, zizmor, the configuration
contract and `trivy config`, the integration tests on amd64 and arm64, the coverage run with the
SonarCloud analysis, and a Trivy scan of the image.

## Pull requests

1. Branch from the default branch as `type/description`, for example `fix/empty-title`.
2. Keep one change per pull request. New behavior comes with tests; a bug fix adds a test that
   fails without it.
3. Write commit messages as [Conventional Commits](https://www.conventionalcommits.org/) without a
   scope: `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, `build: ...`,
   `ci: ...`, `chore: ...`.
4. Sign your commits. The default branch accepts verified signatures only.
5. Add an entry under `## [Unreleased]` in `CHANGELOG.md`, written for users: the release notes
   quote it. Update the README when behavior or configuration changes.

Pull requests are squash-merged once all required checks are green.

## Releases

Releases are automatic when an input changes. The notes take the Unreleased entries added since
the previous release, see `.github/scripts/release-notes.sh`.

## Changelog

1. Keep one `## [Unreleased]` section on top, and add every entry there.
2. Do not cut per-release sections. The release notes pick the new entries by themselves.
