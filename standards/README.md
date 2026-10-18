# Reactory engineering standards

Organisation-wide conventions that apply to **every** Reactory repository and
submodule. Each standard lives here once and is propagated mechanically — never
copy-paste these files by hand.

| Standard | Canonical file | Propagates to | Tooling |
| --- | --- | --- | --- |
| Pull request template | [`pull_request_template.md`](./pull_request_template.md) | `<repo>/.github/pull_request_template.md` | `scripts/sync-pr-template.sh` |
| GPG commit signing | [`../docs/gpg-commit-signing.md`](../docs/gpg-commit-signing.md) | workstation configuration | `scripts/gpg-setup.sh`, `scripts/gpg-verify.sh` |

## Changing the PR template

1. Edit `standards/pull_request_template.md` — this is the only copy that matters.
2. Preview the impact:
   ```bash
   ./scripts/sync-pr-template.sh
   ```
3. Apply across the local checkouts:
   ```bash
   ./scripts/sync-pr-template.sh --apply
   ```
4. Commit and open one PR per repository (or a batch if your tooling supports it).

`sync-pr-template.sh` is idempotent and byte-comparing, so re-running it is safe
and it reports "in sync" instead of rewriting identical files.

### CI drift check

Add this to any repository's workflow to fail when its copy diverges from the
canonical version:

```yaml
- name: Check PR template is current
  run: ./scripts/sync-pr-template.sh --check
```

Run it from a checkout of the `.github` repository, or vendor the script and
point `--base` at the workspace root.

## Conventions this enables

- Every PR states its intent, test evidence, blast radius and rollback plan.
- Breaking changes, security impact and migration risk are surfaced before review.
- Reviewer effort is proportional to risk rather than to diff size.
- Commit provenance is verifiable, so review approvals attach to a real identity.
