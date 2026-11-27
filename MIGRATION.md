# Migrating from GitHub

The plan: mirror every repository to the forge, port the Actions workflows, move your remotes, and keep GitHub as a read-only mirror fed by the forge. Do it in that order, and keep GitHub authoritative until the last step so every earlier step is reversible.

Placeholders below are in `[BRACKETS]`. Tokens go in environment variables, never on a command line you will paste into a ticket.

## 0. Inventory what git does not carry

`git clone --mirror` moves commits, branches and tags. It does not move the rest. List what you rely on before you start:

| On GitHub | Moves with the mirror? | What to do |
|---|---|---|
| Commits, branches, tags | Yes | `mirror-from-github.sh` |
| Git LFS objects | Only with `--lfs` | Pass `--lfs`; needs `git-lfs` |
| Issues, pull requests, labels, milestones, releases, wiki | **No** | Use Forgejo's built-in migration (New Migration, GitHub) for the repositories where you want them |
| Actions workflows | They are files in the repo, so yes | Port them (step 3) |
| Actions secrets and variables | **No**, and GitHub will not export them | Re-enter them in the forge, per repository or organisation |
| Branch protection and required reviews | No | Recreate in the forge. Note that on GitHub Free, private repositories cannot enforce branch protection at all, which is a reason some teams move |
| Webhooks, deploy keys, GitHub Apps | No | Recreate. Anything that calls back into GitHub needs a new endpoint |
| Packages, Pages | No | Out of scope for this kit |
| Teams and permissions | No | Recreate as Forgejo organisations and teams |

Count what you have:

```bash
gh repo list [ORG] --limit 1000 --json name,isPrivate,isArchived,isFork --jq 'length'
gh repo list [ORG] --limit 1000 --json name,isArchived --jq '[.[]|select(.isArchived)]|length'
```

## 1. Prepare the forge

1. Stand up the forge (`make aws`, `make azure` or `make local`) and sign in as the administrator.
2. Create an access token for the migration: **Settings, Applications**, with `write:repository` and `write:organization`. Export it, with the username that owns it:

   ```bash
   export FORGE_USER=[FORGE_ADMIN_USERNAME]
   export FORGE_TOKEN=[FORGE_ACCESS_TOKEN]
   ```
3. Create a GitHub token that can **read** the repositories (a fine-grained, read-only token is enough):

   ```bash
   export GITHUB_TOKEN=[GITHUB_READ_ONLY_TOKEN]
   ```

## 2. Mirror every repository

Dry run first. It lists what it would create and touches nothing:

```bash
scripts/mirror-from-github.sh --github [ORG] --forge-url https://[FORGE_HOST] --dry-run
```

Then for real:

```bash
scripts/mirror-from-github.sh --github [ORG] --forge-url https://[FORGE_HOST] --lfs
```

What it does for each repository: creates the forge repository if it is missing (private if the source is private; the forge organisation is created if absent), `git clone --mirror`, then `git push --mirror`. An existing local mirror is refreshed with `git remote update --prune`. Archived repositories are skipped unless you pass `--include-archived`. The summary line and a non-zero exit tell you if any repository failed.

**Re-running is safe by default: the script refuses to destroy work that exists only on the forge.** Before it pushes a repository it reads the forge's refs and compares them with GitHub's. It pushes only if every forge ref also exists on GitHub and the forge's commit is the same as, or an ancestor of, GitHub's tip. Otherwise that repository is **refused**: nothing is pushed to it, each offending ref is logged as `REFUSED <repo>: <ref> <reason>`, the summary lists the repository, and the exit code is 3 (1 if any repository failed outright). The reasons are `only-on-forge` (a branch or tag GitHub does not have), `forge-commit-unknown-to-github` (a commit made on the forge), and `...-not-ancestor-of-github-...` (GitHub's history was rewritten, or a tag was moved, so a push would rewind the forge). `refs/pull/*` is ignored because the forge owns it. The other repositories in the run still proceed. Resolve a refusal by hand: push the forge-only work to GitHub, or decide to discard it and re-run that repository with `--overwrite-forge`.

Two options change what a run does:

- `--only-existing` mirrors only repositories that already exist on the forge. It never creates a repository or an organisation, and a GitHub repository with no forge counterpart is logged as not on the forge and counted in the summary, not treated as an error. Use it for a scheduled refresh, so that a new GitHub repository does not appear on the forge until a human has decided it should.
- `--overwrite-forge` restores the old behaviour: `git push --mirror` unconditionally, so a commit, branch or tag that exists only on the forge is **deleted**. Use it for the one-off initial load or an explicit reset, never from a timer.

A failure to list GitHub's repositories (an expired token, a rate limit, an error on a later page) now stops the run with a non-zero exit instead of mirroring whatever came back before the error. The script still mirrors every repository in the organisation unless you pass `--only-existing`.

Two behaviours to know:

- GitHub's `refs/pull/*` refs are deleted from the local mirror before pushing, because the forge owns that namespace itself.
- Forks are mirrored as ordinary repositories. They keep their commit history but not their GitHub fork relationship.

**Check the result.** Do not trust the log:

```bash
# for every repository, the default branch tip should be identical on both sides
git ls-remote https://github.com/[ORG]/[REPO].git HEAD
git ls-remote https://[FORGE_HOST]/[ORG]/[REPO].git HEAD
```

Run it over the whole list with a small loop and diff the output. Also compare the repository counts from step 0 with the forge's admin page.

To bring issues, pull requests, releases and the wiki across, use **New Migration, GitHub** in the forge UI for the repositories that need them. Do that **instead of** the mirror script for those repositories, not after it: the migration creates the repository itself.

## 3. Port the Actions workflows

Forgejo Actions runs GitHub-Actions-compatible YAML, so most workflows need little or no change. "Most" is not "all". Find the risky ones first:

```bash
grep -rEn 'upload-artifact@v4|download-artifact@v4|id-token:|environment:|workflow_run|merge_group|self-hosted|macos-|windows-|runs-on:.*matrix' .github/workflows
```

| Construct | What to expect |
|---|---|
| `runs-on: ubuntu-latest` | Works if the runner has that label. The kit registers `docker` and `ubuntu-latest`, both mapped to a Node-capable Debian image. A job that expects the full GitHub-hosted Ubuntu image (many preinstalled tools) will not find them; install what you need in a step, or point a label at a richer image. |
| `runs-on: macos-*` or `windows-*` | No runner for these. Out of scope for this kit. |
| `uses: actions/checkout@v4` and other popular actions | Resolved against the forge's default actions mirror. Pin a different source with a full URL, for example `uses: https://github.com/[OWNER]/[ACTION]@[REF]`. |
| `actions/upload-artifact@v4`, `download-artifact@v4` | Depend on GitHub's artifact service and are known not to work on Forgejo. Use `@v3`, or an equivalent action maintained for Forgejo, and check your Forgejo version's notes. |
| OIDC (`id-token: write`) to a cloud | Not available. Use a secret, or a runner with an attached identity. |
| `${{ secrets.GITHUB_TOKEN }}` | Exists and is scoped to the forge, not to GitHub. It cannot call the GitHub API. |
| `environment:`, deployment protection, required reviewers | Treat as unsupported until you have tested them on your version. |
| Reusable workflows and composite actions | Work, using full URLs for cross-repository references. |
| `actions/cache` | Works when the runner's built-in cache server is enabled in `config.yml`. |
| Docker service containers, container jobs | Work through the Docker-in-Docker sidecar. |

**Where to put the files.** Copy `.github/workflows` to `.forgejo/workflows`. Forgejo reads `.forgejo/workflows` first; check your version's documentation on whether it also falls back to `.github/workflows`. Keeping the two directories separate means GitHub does not start running forge-targeted workflows, and the forge does not double-run GitHub-targeted ones, during the transition.

Then prove one real workflow on a non-critical repository before porting the rest. The kit's own `.forgejo/workflows/ci.yml` is a ready-made smoke test: push the kit to your forge and watch it run.

## 4. Cut over the remotes

Pick a quiet window and announce it. Then:

1. **Freeze** pushes to GitHub (a message in the channel is enough for a small team; on a plan with branch protection, lock the default branches).
2. **Final sync.** Re-run `mirror-from-github.sh` and re-check the heads. Nothing may land on GitHub after this.
3. **Move each working copy.** Developers run, in each clone:

   ```bash
   git remote rename origin github
   git remote add origin ssh://git@[FORGE_HOST]:2222/[ORG]/[REPO].git
   git fetch origin
   git branch -u origin/[DEFAULT_BRANCH] [DEFAULT_BRANCH]
   ```

   Add their SSH public key to their forge account first. If you want a belt-and-braces period where every push also reaches GitHub from the client, give `origin` two push URLs (`git remote set-url --add --push origin [URL]` once for each). Prefer the server-side mirror in step 5 for the long run; client-side dual pushes drift the moment one person forgets.
4. **Repoint automation**: CI triggers, deploy keys, package-publish jobs, bots, and anything that clones from GitHub by URL.
5. **Re-enter the secrets** workflows need, in the forge.

## 5. Keep GitHub as a mirror

Let the forge push to GitHub, so GitHub stays a current read-only copy for people and tools that still look there. In each repository, **Settings, Repository, Mirror settings, Push mirror**, or by API:

```bash
curl -fsS -X POST "https://[FORGE_HOST]/api/v1/repos/[ORG]/[REPO]/push_mirrors" \
  -H "Authorization: token $FORGE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"remote_address":"https://github.com/[ORG]/[REPO].git","remote_username":"[GITHUB_USERNAME]","remote_password":"[GITHUB_WRITE_TOKEN]","interval":"8h0m0s","sync_on_commit":true}'
```

Use a dedicated GitHub token with write access to only these repositories. **A push mirror force-overwrites the GitHub side.** Anything pushed to GitHub directly after this point will be destroyed by the next sync, so make the GitHub repositories read-only for humans (archive them, or restrict write access) the moment you enable mirroring.

Turn off GitHub Actions on the mirrored repositories so the mirror does not also run CI.

## 6. Rollback

Until step 5, GitHub is still complete and authoritative. To go back: `git remote rename github origin` in each clone, re-enable pushes, and delete or ignore the forge copies. After step 5, the forge has become the source of truth, and going back means reversing the mirror direction (a push mirror from the forge is how you would repopulate GitHub), so decide with that in mind.

## 7. After the move

- Run the first [restore drill](RUNBOOK.md#restore-drill) with all repositories present, and compare the repository count in the drill output with the forge.
- Put the monthly restore drill and the upgrade check in a calendar.
- Delete the migration tokens from both sides when you are done.
- Keep `.work/mirrors` (the local bare mirrors from step 2) until you have seen a restore drill pass. It is an extra copy of everything, and it is not encrypted.
