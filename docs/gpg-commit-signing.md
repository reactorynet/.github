# GPG commit signing

All Reactory commits must be cryptographically signed so that history on GitHub
is attributable and tamper-evident. This document is the runbook for getting a
workstation to that state.

- **Tooling:** [`scripts/gpg-setup.sh`](../scripts/gpg-setup.sh) — configures everything
- **Audit:** [`scripts/gpg-verify.sh`](../scripts/gpg-verify.sh) — proves it works
- **Ticket:** REACTORY-302016408

---

## 1. Install the toolchain

```bash
brew install gnupg pinentry-mac
```

`pinentry-mac` renders the passphrase dialog as a native macOS prompt, which is
what makes `gpg-agent` caching usable. Verify:

```bash
gpg --version          # 2.2+ expected
pinentry-mac --version
```

## 2. Configure signing

```bash
cd /path/to/.github
./scripts/gpg-setup.sh --name "Your Name" --email you@reactory.net
```

The script is idempotent: it reuses an existing secret key for the email if one
is present. What it does:

| Step | Effect |
| --- | --- |
| Key generation | `rsa4096`, cert+sign, no expiry |
| `~/.gnupg/gpg-agent.conf` | 8 h idle / 24 h max passphrase cache, `pinentry-program` set to `pinentry-mac` |
| Git (global) | `user.signingkey`, `commit.gpgsign=true`, `tag.gpgsign=true`, `gpg.program`, `gpg.format=openpgp` |
| Export | `~/.gnupg/reactory-signing-key-<FPR>.asc` |
| Registration | Uploads the public key to GitHub via `gh api user/gpg_keys` |

The passphrase is read from the terminal and streamed to `gpg` through a
`0600` temp file that is deleted on exit. It never appears in `argv`, shell
history, or a log.

### Options

| Flag | Purpose |
| --- | --- |
| `--algo ed25519` | Smaller, faster key (GitHub supports it) |
| `--existing 0xABCD…` | Adopt an existing secret key instead of creating one |
| `--no-upload` | Skip GitHub registration (air-gapped or manual review) |
| `--local` | Write git config to the current repo only, not `--global` |

## 3. Verify

```bash
./scripts/gpg-verify.sh
```

Expected output:

```
  ✓ gpg installed                    2.4.x
  ✓ pinentry-mac                     /opt/homebrew/bin/pinentry-mac
  ✓ secret key for you@reactory.net  1A2B3C4D5E6F...
  ✓ git user.signingkey              1A2B3C4D5E6F...
  ✓ git commit.gpgsign               true
  ✓ git gpg.program                  /opt/homebrew/bin/gpg
  ✓ sign + verify round trip         Good signature
  ✓ GitHub GPG keys                  1 registered
  ✓ GitHub verified email            you@reactory.net
```

The round-trip check creates a throwaway repository, commits with `-S`, and
requires `Good signature` from `git log --show-signature`. It is a real test,
not a config reading.

### Scoped audits

```bash
./scripts/gpg-verify.sh --repo /path/to/repo          # effective config for that repo
./scripts/gpg-verify.sh --repo . --no-remote          # offline / CI: skip GitHub checks
./scripts/gpg-verify.sh --json                        # machine-readable, for CI
```

With `--repo`, config resolution follows git's own precedence (local overrides
global), so a repo that pins its own `user.signingkey` is audited correctly.
The script exits non-zero on any ✗, which makes it usable as a CI gate.

## 4. Confirm on the remote

```bash
git commit --allow-empty -S -m "chore: verify commit signing"
git push
git log --show-signature -1     # Good signature
gh api repos/reactorynet/<repo>/commits/$(git rev-parse HEAD) -q '.commit.verification.verified'
```

`true` means GitHub verified the signature against a key registered to the
committing email. `false` with `reason: "unverified_email"` means the key is
registered but its UID email is not a verified email on the account.

---

## Why signatures

- **Attribution.** A signed commit proves the author holding the private key
  produced it, not merely that a `user.email` string was configured.
- **Review integrity.** Combined with branch protection, signed commits make
  history rewriting and impersonation detectable after the fact.
- **Release provenance.** Tags signed with the same key anchor release artifacts
  to a key the organisation controls.

## Per-repository enforcement

Once signing is live for the team, enable **Require signed commits** on the
protected branches of each repository:

```
Settings → Branches → Branch protection rules → <rule> → Require signed commits
```

Do this only after the rollout, otherwise unsigned PR branches block merges.
Signing is a *client-side* setting: it must be configured per workstation, it
cannot be imposed by the repository itself.

## Multi-machine and key hygiene

- **One key per developer**, exported and imported on each workstation. Never
  share a private key between people.
- Back up `~/.gnupg/` (private key + revocation certificate) somewhere encrypted.
- Generate a revocation certificate now and store it offline:
  ```bash
  gpg --output ~/secure/revoke-<FPR>.asc --gen-revoke <FPR>
  ```
- Rotate keys when a laptop is lost or a passphrase is compromised; revoke
  first, then publish the new key.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `gpg: signing failed: Inappropriate ioctl for device` | No TTY for the pinentry prompt | `export GPG_TTY=$(tty)` in `~/.zshrc` |
| Passphrase prompt never appears | `pinentry-program` missing or wrong | Re-run `gpg-setup.sh`, then `gpgconf --kill gpg-agent` |
| `gpg: skipped "…": No secret key` | `user.signingkey` set to a subkey or stale fingerprint | Set the primary key fingerprint: `git config --global user.signingkey <FPR>` |
| Commits show **Unverified** on GitHub | Key not uploaded, or UID email not verified on the account | Upload at <https://github.com/settings/gpg/new>; add and verify the email |
| Signing works locally but CI rejects | Branch protection requires signatures and the CI bot is unsigned | Use a signed bot commit, or exempt the service account |
| `gpg: can't connect to the agent` | Agent socket stale after an OS update | `gpgconf --kill gpg-agent && gpg-connect-agent /bye` |
| Existing commits show unverified | Signing was enabled after they were authored | Expected — only new commits are signed. Do not rewrite shared history to fix it. |
| `brew install` fails with "dependencies not built for the x86_64 CPU architecture" | Shell is running under Rosetta (`sysctl -n sysctl.proc_translated` returns `1`) while Homebrew bottles are arm64 | Run Homebrew natively: `arch -arm64 brew install gnupg pinentry-mac` |

## GitLab / other remotes

The commit signature is transport-agnostic; only key registration differs. For
GitLab: **Preferences → GPG Keys → Add new key** with the exported `.asc`, and
the key UID email must be a confirmed address on the account.
