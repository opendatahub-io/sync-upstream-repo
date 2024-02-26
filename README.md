# Sync Upstream Repo Fork

This is a Github Action used to merge changes from remote.  

This is forked from [dabreadman/sync-upstream-repo](https://github.com/dabreadman/sync-upstream-repo) which in turn was forked from [mheene](https://github.com/mheene/sync-upstream-repo).

The changes in this fork are:

1. Allow the use of `rebase` to merge upstream changes into the target fork repo and branch.
2. Use of the RHEL Ubi images instead of alpine
3. Added explicit logging messages
4. Pushing and pulling of tags from upstream repo to downstream repo

## Use case

- Preserve a repo while keeping up-to-date (rather than to clone it).
- Have a branch in sync with upstream, and pull changes into dev branch.

## Usage

```YAML
name: Sync Upstream

env:
  # Required, the mode the action will run on. There only two mode supported:
  # "branch-to-branch"  : all the commits from the upstream branch will be synched into the downstream branch using the defined merge strategy
  # "release-following" : detects if a newer branch matching the pattern defined in UPSTREAM_BRANCH is created and renames the current DOWNSTREAM_BRANCH
  #                       to the previous branch name and continues to synch the commits from the new upstream branch to DOWNSTREAM_BRANCH
  MODE: branch-to-branch
  # Required, URL to upstream repository (fork base)
  UPSTREAM_REPO_URL:  https://github.com/openvinotoolkit/model_server.git
  # Required, the name of the upstream branch to pull changes from
  UPSTREAM_BRANCH: main
  # Required, URL to the fork where to upstream changes are to be synched
  DOWNSTREAM_REPO_URL: https://github.com/z103cb/openvino_model_server.git
  # Optional, downstream repository branch name. If not provided it will default to
  # the value of UPSTREAM_BRANCH
  DOWNSTREAM_BRANCH: main
  # Optional, create log commits in the branch. The values allowed are "true" or "false", with 
  # "false being the default"
  SPWAN_LOGS: "true"
  # Optional, merge strategy. The values allowed are either "rebase" or "merge", with "rebase"
  # being the default 
  MERGE_STRATEGY: "rebase"

# This runs every day on 1801 UTC
on:
  schedule:
    - cron: '1 18 * * *'
  # Allows manual workflow run (must in default branch to work)
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: GitHub Sync to Upstream Repository
        uses: z103db/sync-upstream-repo@v2.1.0
        with: 
          mode: ${{ env.MODE }}
          upstream_repo_url: ${{ env.UPSTREAM_REPO_URL }}
          upstream_branch: ${{ env.UPSTREAM_BRANCH }}
          downstream_repo_url: ${{ env.DOwNSTREAM_REPO_URL }}
          downstream_branch: ${{ env.DOWNSTREAM_BRANCH }}
          # Defaults to `secrets.GITHUB_TOKEN` if not specified
          token: ${{ secret.GHA_TOKEN }}
          merge_strategy: ${{ env.MERGE_STRATEGY}}
          spawn_logs: ${{ env.SPAWN_ARGS }} 
```

This action syncs the downstream repo with the upstream repo every day at the time specified in the schedule. The synch process rebases the content of the specified branch in the downstream repo with the content of the upstream repo and branch. You can pass additional arguments to the rebase commands using the REBASE_ARGS  
Do note GitHub Action scheduled workflow usually face delay as it is pushed onto a queue, the delay is usually within 1 hour long.

## Development

In [`action.yml`](action.yml), we define `inputs`.  We then pass these arguments into [`Dockerfile`](Dockerfile), which then passed onto [`entrypoint.sh`](entrypoint.sh).

`entrypoint.sh` does the heavy-lifting,

- Set up variables.
- Set up git config.
- Clone downstream repository.
- Fetch upstream repository.
- Attempt rebase if behind, and push to downstream.
