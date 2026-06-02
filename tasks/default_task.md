# Nightly Codex Task

You are running in an unattended nightly maintenance window.

## Objective

Inspect the repository, choose the highest-value small improvement, implement it, and run the configured verification commands.

## Constraints

- Keep changes focused and reversible.
- Do not modify secrets, credentials, production data, or host-level configuration.
- Do not push to remote branches.
- Preserve existing user changes and avoid destructive Git commands.
- Update relevant documentation when behavior changes.

## Required final response

Summarize:

- What changed
- Which tests or checks ran
- Any failures or unresolved follow-up items
