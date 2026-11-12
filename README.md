# harumi-io/workflows

Public reusable GitHub Actions workflows shared across Harumi repositories.

This repo is public on purpose: GitHub forbids a public repository from calling a reusable workflow
in a private one, and `harumi-cli` is public. Nothing here is secret. Credentials come from the
caller's OIDC token and `secrets`.

## Claude Code review

`.github/workflows/claude-code-review.yml` runs a Claude review on a pull request. A caller supplies
its own review prompt (which should differ per repo) and nothing else unless it needs to.

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

jobs:
  code-review:
    permissions:
      contents: read
      pull-requests: write
      id-token: write
    uses: harumi-io/workflows/.github/workflows/claude-code-review.yml@v1
    with:
      prompt_full: |
        ...
      prompt_simple: |
        ...
```

Pin a tag (`@v1`), never `@main`: a bad edit here would otherwise reach every repo at once. Bump
the pin per repo like a dependency upgrade. Inputs and their defaults are documented in the workflow.

`bash scripts/check-review-prompt.sh` checks the prompt and diff-scoping step; CI runs it.

### Changing it

A backwards-compatible change moves the tag: `git tag -f v1 && git push -f origin v1`. A breaking
change (an input renamed or removed, a new required input) cuts `v2` and callers move deliberately.

## Undraft when green

`.github/workflows/undraft-when-green.yml` marks a draft PR ready for review once the caller's CI has
passed, which starts the review bot and the board sync. Call it as the last job of a repo's main CI
workflow, after the job that gates the rest:

```yaml
undraft:
  needs: [verify]
  if: github.event_name == 'pull_request' && github.event.pull_request.draft
  permissions: {}
  uses: harumi-io/workflows/.github/workflows/undraft-when-green.yml@v1
  secrets:
    token: ${{ secrets.UNDRAFT_TOKEN }}
```

It is opt-in: a PR is only undrafted when it carries the `ready-when-green` label, so a draft goes
ready when its author says the work is complete, not on its first green push. Add the label before
the final push, or add it later and re-run just the `undraft` job (the label is read from the live PR).

`UNDRAFT_TOKEN` is a fine-grained PAT (Pull requests: write, Contents: write, Metadata: read), not
`GITHUB_TOKEN`: a ready event made with `GITHUB_TOKEN` starts no other workflow, so the review bot
would never run. GitHub also refuses the ready mutation without Contents write. The job only
undrafts PRs authored by the token's owner, from a branch in the same repo, skips when a newer
commit has landed, and does nothing (with a notice) when the secret is missing, so it never fails CI.
