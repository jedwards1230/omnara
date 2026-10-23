# omnara (patched fork)

This is a fork of [omnara-ai/omnara](https://github.com/omnara-ai/omnara) that
carries **one patch** on top of upstream's `cluster-vX.Y.Z` releases and
publishes container images built from it. Everything else is upstream's code,
under upstream's Apache-2.0 license (see `LICENSE` on any code branch).

You are looking at the `homelab` branch, the fork's default branch. It holds
only this README and the CI that builds the images; it shares no history with
upstream.

## The patch

`OMNARA_OUTBOUND_ALLOWED_CIDRS`: an operator-only, comma-separated list of
CIDRs that Omnara's outbound SSRF guard admits for **model-provider and MCP
calls only** (model resolution and discovery, the MCP clients and MCP OAuth).
It is read from the environment of the API and the worker, is empty by default
(no behavior change), and fails startup on a malformed value. It refuses
`0.0.0.0/0`, `::/0`, and any prefix overlapping link-local/metadata, multicast
or unspecified addresses. Web fetch, search, event webhooks, the chat
integrations, client-metadata fetches, email and sandbox-provider APIs stay
fully guarded. It exists for self-hosters whose model gateway or MCP gateway
resolves to a private address.

The patch is written to be upstreamable; once upstream ships an equivalent,
this fork has no reason to exist.

## Branches and tags

| Ref | What it is |
|---|---|
| `main` | Untouched mirror of upstream `main`. Never committed to. |
| `feat/outbound-allowed-cidrs` | An upstream `cluster-vX.Y.Z` tag plus **exactly one commit**: the patch. Source of truth for the patch. |
| `homelab` | Default branch: this README and `.github/`. |
| `homelab-vX.Y.Z-rN` (git tags) | Annotated tag on the exact patched commit an image set was built from. The message records the upstream tag and commit, the patch commit and the run. |
| other branches, `cluster-v*` tags | Copied from upstream when the fork was created; not maintained. Never push a `cluster-v*` tag here. |

## Images

Five images, one per target of upstream's `Dockerfile`, all built from the
same commit for `linux/amd64` and `linux/arm64`, public and anonymously
pullable:

```
ghcr.io/jedwards1230/omnara-web:vX.Y.Z-rN
ghcr.io/jedwards1230/omnara-api:vX.Y.Z-rN
ghcr.io/jedwards1230/omnara-worker:vX.Y.Z-rN
ghcr.io/jedwards1230/omnara-maintenance:vX.Y.Z-rN
ghcr.io/jedwards1230/omnara-migrations:vX.Y.Z-rN
```

- `vX.Y.Z` is the upstream release (`cluster-vX.Y.Z`); `N` starts at 1 for
  each upstream version and goes up only when the patch changes for that same
  version. There is deliberately **no** plain `vX.Y.Z` and **no** `latest` tag,
  so an image here can never be mistaken for an unpatched upstream build.
- Tags are immutable: CI never overwrites an existing image tag.
- Pin by the multi-arch index digest (`…:vX.Y.Z-rN@sha256:…`); each run's job
  summary lists all five.
- Each index carries OCI annotations (`source`, `revision` = the patched
  commit, `version`, `description`) and each image the matching labels plus
  `io.github.jedwards1230.omnara.upstream-tag`/`-commit` and `.patch-commit`.
  Builds carry SLSA provenance (`mode=max`) and an SBOM, and are signed with
  cosign keyless:

  ```sh
  cosign verify ghcr.io/jedwards1230/omnara-api:vX.Y.Z-rN \
    --certificate-identity https://github.com/jedwards1230/omnara/.github/workflows/upstream-sync.yaml@refs/heads/homelab \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```

## CI: `.github/workflows/upstream-sync.yaml`

Runs daily and on demand. Each run:

1. **Plan** (read-only): finds the highest upstream `cluster-vX.Y.Z` tag (or
   the `upstream_tag` input), checks that the patch ref is exactly one
   single-parent commit on top of an upstream release tag or an upstream `main`
   commit, and rebases it onto the target. If the patch is already based on the
   target, the commit is kept as is (same SHA, signature intact); otherwise CI
   makes a deterministic, unsigned rebased commit (author kept, committer
   `github-actions[bot]`). A conflict, or a patch that becomes empty, fails the
   run with an error annotation and a summary saying how to fix it.
2. **Revision**: compares the rebased commit's **tree** with the highest
   existing `homelab-vX.Y.Z-rN` tag for that version:
   - same tree and all five image tags present: up to date, nothing is built
     (the images are only re-verified);
   - same tree, images missing: **resume** that revision from its existing
     git tag commit, building only the missing images;
   - different tree, or no tag yet: mint `rN+1` (or `r1`).
3. **Gate**: `make verify` (upstream's fast repository gate) on the exact
   commit, with the toolchain setup of upstream's `ci.yaml`.
4. **Tag**: pushes the annotated git tag, before any image.
5. **Build**: the five images in parallel; each first checks that the git tag
   exists and points at the planned commit and that its image tag does not
   exist yet.
6. **Verify**: without credentials, pulls each tag's manifest index and checks
   that it lists `linux/amd64` and `linux/arm64`, records the planned commit,
   matches the digest built in the run, and that the tag is listed
   anonymously. The digests go to the job summary.

Nothing is published unless the rebase is clean and the gate is green. Runs
never overlap (no cancel-in-progress); a dry run never blocks a real one.

### Dispatch inputs

| Input | Default | Meaning |
|---|---|---|
| `upstream_tag` | empty | `cluster-vX.Y.Z` to build; empty means the highest upstream release tag. |
| `patch_ref` | `feat/outbound-allowed-cidrs` | Branch or tag in this fork whose tip is the patch commit. |
| `dry_run` | `false` | Plan, gate and build all five images with `push: false`; push nothing. |

```sh
gh workflow run upstream-sync.yaml -R jedwards1230/omnara                     # real sync
gh workflow run upstream-sync.yaml -R jedwards1230/omnara -f dry_run=true     # rehearsal
gh run watch -R jedwards1230/omnara
```

Re-running is always safe: an unchanged patch is a no-op and an interrupted
revision is resumed, never re-minted.

### Updating the patch

The patch branch must stay one commit on an upstream release tag:

```sh
git fetch upstream --tags
git switch feat/outbound-allowed-cidrs
# edit, then fold the change into the single commit
git commit --amend
make verify
git push --force-with-lease origin feat/outbound-allowed-cidrs
gh workflow run upstream-sync.yaml -R jedwards1230/omnara
```

A changed patch publishes as the next `-rN` of the current upstream version.

When a new upstream release makes the rebase conflict, the run fails with the
conflicting files listed. Rebase by hand and re-run:

```sh
git rebase --onto cluster-vX.Y.Z HEAD~1   # on the patch branch; resolve, make verify
git push --force-with-lease origin feat/outbound-allowed-cidrs
gh workflow run upstream-sync.yaml -R jedwards1230/omnara
```

### Known limits

- **Workflow-file commits and `GITHUB_TOKEN`.** GitHub rejects a push made with
  `GITHUB_TOKEN` that makes commits changing `.github/workflows/*` reachable in
  this repository for the first time, and a new upstream release usually
  contains such commits that this fork has not seen. The tag push happens
  before any image, so this fails the run with nothing published. Either keep
  `main` in sync with upstream (`gh repo sync jedwards1230/omnara --branch main`
  from an account that may write workflows), or add a fine-grained token for
  this repository with *Contents: read and write* and *Workflows: read and
  write* as the repository secret `HOMELAB_SYNC_TOKEN`; the tag job uses it when
  it is set. A tag pushed with that token does trigger `push` workflows in the
  tagged tree, but none of upstream's matches a `homelab-v*` tag, and they are
  disabled here anyway.
- **60-day schedule timeout.** GitHub disables scheduled workflows in public
  repositories after 60 days without repository activity. Every run re-enables
  the workflow through the API (`actions: write`), which resets that timer. If
  it was disabled anyway, re-enable it with
  `gh workflow enable upstream-sync.yaml -R jedwards1230/omnara`.
- **Package visibility.** Packages created by the workflow should inherit the
  repository's public visibility. If the verify job reports a private package,
  make it public in the package settings (this cannot be done with
  `GITHUB_TOKEN`) and re-run; the run then only re-verifies.
- **Queued runs.** GitHub keeps at most one pending run per concurrency group,
  so a dispatch queued behind a running sync can be superseded by a newer one.
  Re-dispatch it if that happens.

## Upstream workflows

Upstream's own workflows (CI, releases, live tests, PR automation) are
**disabled** in this fork: they publish to upstream's registries and release
channels, need upstream's secrets and labels, or only duplicate upstream's own
CI on mirrored commits. Only `upstream-sync.yaml` runs here.
