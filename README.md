# Reactory — organisation defaults and engineering standards

This repository holds organisation-wide defaults for the `reactorynet` GitHub
organisation.

## Contents

| Path | Purpose |
| --- | --- |
| `profile/README.md` | Public organisation profile rendered on github.com/reactorynet |
| `standards/` | Canonical engineering standards, propagated to every repo |
| `docs/` | Runbooks for workstation and process setup |
| `scripts/` | Tooling that applies the standards |

## Standards

### Pull request template

[`standards/pull_request_template.md`](standards/pull_request_template.md) is the
single source of truth. GitHub does not inherit PR templates from the
organisation `.github` repository, so each repository needs its own copy at
`.github/pull_request_template.md`. Propagate it with:

```bash
./scripts/sync-pr-template.sh            # report drift
./scripts/sync-pr-template.sh --apply    # write all copies
```

### Signed commits

All commits must be GPG signed. See
[docs/gpg-commit-signing.md](docs/gpg-commit-signing.md) for the runbook, then:

```bash
./scripts/gpg-setup.sh --name "Your Name" --email you@reactory.net
./scripts/gpg-verify.sh
```

## Repository inventory covered by the standards

`reactory-express-server`, `reactory-pwa-client`, `reactory-core`,
`reactory-docs`, `reactory-data`, `reactory-compute-service`,
`reactory-workflow-es`, `reactory-speech-service`, `reactory-electron`,
`reactory-native`, plus the submodules `reactory-express-server-devops` and
`reactory-client-core-pwa-plugin`.
