---
name: Renovate PRs
description: List every open pull request authored by the renovate bot across all Gitea repos the user can see
---

## Purpose

Report all open Renovate pull requests across the user's Gitea repositories, excluding the `Archived` organization.

## Workflow

Use the `gitea` tools inside a single `execute` call.

1. Get the user's organizations with `tools.gitea.get_user_orgs({ per_page: 100 })`. Use each org's `username` (or `name`) and drop `Archived`.
2. Collect repositories:
   - `tools.gitea.list_my_repos({ per_page: 100 })`, skipping any `full_name` that starts with `Archived/`.
   - `tools.gitea.list_org_repos({ org, per_page: 100 })` for each remaining org.
   - Key the repositories by `full_name` to deduplicate.
3. For each repository, call `tools.gitea.list_pull_requests({ owner, repo, state: "open", per_page: 50 })`, where `owner` and `repo` come from splitting `full_name` on `/`. Wrap each call in `try`/`catch` and skip failures: many repos return "not found" because pull requests are disabled.
4. Keep PRs whose `user` field equals `renovate`. The `user` field is a plain string, not an object.
5. Sort by repo, then PR number.

## Output

Show a table with the columns Repo, PR, Title, and Opened (the date part of `created_at`), with a link to each PR's `html_url`. Then give the total count.

If there are no matches, say so.

## Notes

- Do not print the full API responses; summarize them.
- Report how many repositories were checked and how many were skipped because of errors.
