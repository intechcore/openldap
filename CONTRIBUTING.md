# Contributing

Issues and pull requests are welcome.

## Build and test

```sh
make build            # build the image
make test             # build and run the integration tests
make test-migration   # 2.4 to 2.6 migration test
make test-arch        # arm64 smoke test under emulation
make lint             # shellcheck + hadolint
```

CI runs the same tests on amd64 and arm64 for every pull request, together with ShellCheck,
Hadolint, actionlint, zizmor, `trivy config` and a Trivy scan of the image.

## Pull requests

1. Keep one change per pull request, with tests where it changes behavior.
2. Write commit messages as [Conventional Commits](https://www.conventionalcommits.org/):
   `fix: ...`, `feat: ...`, `ci: ...`, `docs: ...`.
3. Sign your commits. The default branch accepts verified signatures only.
4. Update the README and the CHANGELOG with the change. Write the CHANGELOG entry for users:
   the release notes quote it.

Pull requests are squash-merged once CI is green.

## Release notes

The Release workflow writes the notes with `.github/scripts/release-notes.sh`. They take the
entries of `## [Unreleased]` in `CHANGELOG.md` that were added since the previous release, and
the reason of a weekly rebuild. To give a release its own heading, cut a
`## [<tag>] - <date>` section before you run the workflow, for example `## [2.6.13-4]`. The
notes then take that section.
