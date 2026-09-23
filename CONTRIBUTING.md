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
4. Update the README and the CHANGELOG with the change.

Pull requests are squash-merged once CI is green.
