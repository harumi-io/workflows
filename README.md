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
