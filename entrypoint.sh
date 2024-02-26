#!/bin/bash
set -eu
readonly GIT_REPO_REGEX="^(https|git)(:\/\/|@)([^\/:]+)[\/:]([^\/:]+)\/(.+)(.git)*$"
readonly BRANCH_TO_BRANCH_MODE="branch-to-branch"
readonly RELEASE_FOLLOWING_MODE="release-following"
readonly ROOT_DIR=$(dirname ${0})
readonly SCRIPT=$(basename ${0})

NOT_VERBOSE_GIT="--quiet"
MODE=""
UPSTREAM_REPO_URL=""
UPSTREAM_BRANCH=""
DOWNSTREAM_REPO_URL=""
DOWNSTREAM_BRANCH=""
GITHUB_TOKEN=""
MERGE_STRATEGY=""
DOWNSTREAM_REPO=""
GITHUB_ACTOR=${GITHUB_ACTOR:-""}
SPAWN_LOGS="false"


function usage () {
  cat << EOF
  entrypoint.sh
    -h or --help                      Print this message
    -m or --mode <mode>               Required. Synchronization mode, with only values allowed for mode being: ${RELEASE_FOLLOWING_MODE} or ${BRANCH_TO_BRANCH_MODE}.
    -u or --upstream-repo-url  <url>  Required. Upstream repo url.
    -d or --downstream-repo-url <url> Required. Downstream repo url.
    -t or --token <value>             Required. GITHUB token value.
  
  If the mode supplied value is '${BRANCH_TO_BRANCH_MODE}' then these arguments apply:
    -U or --upstream-branch <name>    Required. Upstream branch name.
    -D or --downstream-branch <name>  Optional. Dowstream branch name. If not supplied it will default to the value of upstream-branch

  If the mode supplied value is '${RELEASE_FOLLOWING_MODE}' then these arguments apply:
    -U or --upstream-branch <name>    Required. In this case a pattern for the upstream release branches can be proviced. It should follow the same rules as the arguments to 'grep -E'
    -D or --downstream-branch <name>  Optional. Dowstream branch name. If not supplied it will default to the value of upstream-branch

  Optional arguments:
    -v or --verbose                   Increase the verbosity of git commands
    -S or --merge-strategy            Strategy to use when merging upstream branch content. The only valid argument values are: 'rebase' or 'merge' with 'rebase' being the default. 
    --spawn-logs true|false           Create a merge commit marker file when the merge strategy is set to merge. Default is false.
EOF
  exit 2
}

function dump_vars () {
  echo "Running with these values:"
  echo "    MODE='${MODE}'"
  echo "    UPSTREAM_REPO_URL='${UPSTREAM_REPO_URL}'"
  echo "    UPSTREAM_BRANCH='${UPSTREAM_BRANCH}'"
  echo "    DOWNSTREAM_REPO_URL='${DOWNSTREAM_REPO_URL}'"
  echo "    DOWNSTREAM_BRANCH='${DOWNSTREAM_BRANCH}'"
  echo "    GITHUB_TOKEN=*******"
  echo "    MERGE_STRATEGY='${MERGE_STRATEGY}'"
  echo "    SPAWN_LOGS='${SPAWN_LOGS}'"
}

function validate_b2b_mode_args () {
  [[ -z "${UPSTREAM_REPO_URL}" ]] && echo "Missing upstream repo value" && exit 1
  [[ -z "${DOWNSTREAM_REPO_URL}" ]] && echo "Missing DOWNSTREAM_REPO_URL" && exit 1
  [[ -z "${UPSTREAM_BRANCH}" ]] && echo "Missing UPSTREAM_BRANCH" && exit 1
  [[ -z "${GITHUB_TOKEN}" ]] && echo "Missing GITHUB_TOKEN" && exit 1
  [[ -z "${DOWNSTREAM_BRANCH}" ]] && echo "Missing DOWNSTREAM_BRANCH, defaulting it to ${UPSTREAM_BRANCH}" && DOWNSTREAM_BRANCH=${UPSTREAM_BRANCH}
  [[ -z "${MERGE_STRATEGY}" ]] && echo "MERGE_STRATEGY not set, defaulting to 'rebase' strategy" && MERGE_STRATEGY="rebase"
  if [[ ${DOWNSTREAM_REPO_URL} =~ ${GIT_REPO_REGEX} ]]; then    
    DOWNSTREAM_REPO="${BASH_REMATCH[4]}/${BASH_REMATCH[5]}"
    if [[ -z "${GITHUB_ACTOR}" ]]; then
      GITHUB_ACTOR=${BASH_REMATCH[4]}
    fi
  else 
    echo "${DOWNSTREAM_REPO_URL} does not seem to be a valid GitHub repo url"
    exit 1
  fi
}

function validate_rf_mode_args () {
  [[ -z "${UPSTREAM_REPO_URL}" ]] && echo "Missing upstream repo value" && exit 1
  [[ -z "${DOWNSTREAM_REPO_URL}" ]] && echo "Missing DOWNSTREAM_REPO_URL" && exit 1
  [[ -z "${UPSTREAM_BRANCH}" ]] && echo "Missing UPSTREAM_BRANCH" && exit 1
  [[ -z "${DOWNSTREAM_BRANCH}" ]] && echo "Missing DOWNSTREAM_BRANCH" && exit 1
  [[ -z "${MERGE_STRATEGY}" ]] && echo "MERGE_STRATEGY not set, defaulting to 'rebase' strategy" && MERGE_STRATEGY="rebase"
  if [[ ${DOWNSTREAM_REPO_URL} =~ ${GIT_REPO_REGEX} ]]; then    
    DOWNSTREAM_REPO="${BASH_REMATCH[4]}/${BASH_REMATCH[5]}"
    if [[ -z "${GITHUB_ACTOR}" ]]; then
      GITHUB_ACTOR=${BASH_REMATCH[4]}
    fi
  else 
    echo "${DOWNSTREAM_REPO_URL} does not seem to be a valid GitHub repo url"
    exit 1
  fi
}

function repo_setup () {
  mkdir -pv work
  [[ $? -gt 0 ]] && echo "Failed to create work directory" && exit 1

  git clone "https://github.com/${DOWNSTREAM_REPO}" work
  cd work || { echo "Missing work dir" && exit 2 ; }

  git config user.name "${GITHUB_ACTOR}"
  git config user.email "${GITHUB_ACTOR}@users.noreply.github.com"
  git config --local user.password ${GITHUB_TOKEN}
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${DOWNSTREAM_REPO}"
  
  git remote add upstream "$UPSTREAM_REPO_URL"
  git fetch ${NOT_VERBOSE_GIT} --tags upstream
  echo "Done."
}

function do_b2b_synch() {
  echo "Executing branch to branch repository sync..."
  local dowstream_branch_exists=`git ls-remote --heads origin refs/heads/${DOWNSTREAM_BRANCH} | wc -l`
  # If the branch exists in origin
  if [[ ${dowstream_branch_exists} -eq 1 ]]; then
    echo "origin/${DOWNSTREAM_BRANCH} branch exists"
    git checkout ${NOT_VERBOSE_GIT} ${DOWNSTREAM_BRANCH}
    apply_merge_strategy ${UPSTREAM_BRANCH} ${DOWNSTREAM_BRANCH}
  else 
    echo ${DOWNSTREAM_BRANCH} branch does not exist
    # create new branch with ${DOWNSTREA_BRANCH} name tracking the ${UPSTREAM_BRANCH}
    # this allows for a maping upstream branches to a known branch
    git checkout ${NOT_VERBOSE_GIT} -b ${DOWNSTREAM_BRANCH} remotes/upstream/${UPSTREAM_BRANCH}
  fi
  echo "Pushing changes to origin..."
  git push ${NOT_VERBOSE_GIT} -u --follow-tags origin ${DOWNSTREAM_BRANCH}
  echo "Done."
}
function apply_merge_strategy() {
  local upstream_branch=${1}
  local dowstream_branch=${2}

  if [[ ${MERGE_STRATEGY} == "rebase" ]]; then 
    git checkout ${dowstream_branch}
    echo "Rebasing upstream/${upstream_branch} unto ${dowstream_branch}"
    git rebase ${NOT_VERBOSE_GIT} upstream/${upstream_branch}
  elif [[ ${MERGE_STRATEGY} == "merge" ]]; then
    git checkout ${dowstream_branch}
    echo "Merging upstream/${upstream_branch} unto ${dowstream_branch}"
    do_merge
  else
    echo "Unknown merge strategy: $MERGE_STRATEGY"
    exit 1
  fi
}

function do_merge() {
  case ${SPAWN_LOGS} in
   (true)    echo -n "sync-upstream-repo keeping CI alive."\
             "UNIX Time: " >> sync-upstream-repo
             date +"%s" >> sync-upstream-repo
             git add sync-upstream-repo
             git commit sync-upstream-repo -m "Syncing upstream";;
   (false)   echo "Not spawning time logs"
  esac
  local merge_result=$(git merge --ff-only upstream/${UPSTREAM_BRANCH})
  if [[ $merge_result == "" ]]; then
      exit 1
  elif [[ $merge_result != *"Already up to date."* ]]; then
      git commit -m "Merged upstream"
  fi
}

function cleanup() {
  echo "Cleaning up..."
  cd ..
  rm -rf work
  echo "Done."
}
function do_rf_synch() {
  echo "Execute release branch synch..."
  
  # get the current upstream release ref
  local current_upstream_release=`git ls-remote --heads --refs upstream | grep -E ${UPSTREAM_BRANCH} | awk '{gsub("refs/heads/","", $2); print $2,$1}' | sort -rn | head -n 1`
  if [[ "${current_upstream_release}" == "" ]]; then
    echo "No upstream branch matching `${UPSTREAM_BRANCH}` was found"
    exit 1
  fi
  echo "Found current upstream release: ${current_upstream_release}"
  local current_upstream_release_branch=`echo ${current_upstream_release} | awk '{print $1}'`
 
  # get origin/release ref
  local origin_release=`git ls-remote --heads --refs origin refs/heads/${DOWNSTREAM_BRANCH} | awk '{gsub("refs/heads/","", $2); print $2, $1}'`
  if [[ "${origin_release}" == ""  ]]; then
    echo "There's no origin/${DOWNSTREAM_BRANCH} branch. Creating it locally."
    git checkout -b ${DOWNSTREAM_BRANCH} remotes/upstream/${current_upstream_release_branch}
    git push ${NOT_VERBOSE_GIT} -u --follow-tags origin ${DOWNSTREAM_BRANCH}
    echo "Done."
    return
  fi 
  local origin_release_commit=`echo ${origin_release} | awk '{print $2}'`
  local origin_release_branch=`echo ${origin_release} | awk '{print $1}'`
  echo "Found commit '${origin_release_commit}' on branch '${origin_release_branch}'"
  echo "Looking for commit on branches..."
  git branch -a --contains ${origin_release_commit}
  
  # get the upstream release for the current origin/release commit
  local previous_upstream_release_branch=`git branch -a --contains ${origin_release_commit} | grep -E remotes/upstream/${UPSTREAM_BRANCH} | awk '{gsub("remotes/upstream/","", $1); print $1}'`
  echo "Found previous upstream release branch: ${previous_upstream_release_branch} for commit ${origin_release_commit}"
  if [[ "${previous_upstream_release_branch}" == "${current_upstream_release_branch}" ]]; then
      echo "No release branch change..."
      git checkout ${NOT_VERBOSE_GIT} ${DOWNSTREAM_BRANCH}
      apply_merge_strategy ${current_upstream_release_branch} ${DOWNSTREAM_BRANCH}
      git push ${NOT_VERBOSE_GIT} -u --follow-tags origin ${DOWNSTREAM_BRANCH}
  else
    echo "A release branch change has been detected"
    git checkout ${NOT_VERBOSE_GIT} ${DOWNSTREAM_BRANCH}
    #Rename the local release branch
    git branch -m ${DOWNSTREAM_BRANCH} ${previous_upstream_release_branch}
    #To rename the origin release branch
    #Delete the remote release branch 
    git push ${NOT_VERBOSE_GIT} origin --delete ${DOWNSTREAM_BRANCH}
    git push ${NOT_VERBOSE_GIT} origin -u ${previous_upstream_release_branch}
    # Recreate the new release branch tracking the upstream release brach
    git checkout ${NOT_VERBOSE_GIT} -b ${DOWNSTREAM_BRANCH} remotes/upstream/${current_upstream_release_branch}
    git push ${NOT_VERBOSE_GIT} -u --follow-tags origin ${DOWNSTREAM_BRANCH} 
  fi
  echo "Done."
}

if [ ${#} -eq 0 ]; then
    usage
fi

params="$(getopt -o hm:u:d:U:D:t:vS: --long help,mode:,upstream-repo-url:,downstream-repo-url:,upstream-branch:,downstream-branch:,token:,verbose,merge-strategy:,spawn-logs: --name "$(basename "$0")" -- "$@")"
eval set -- "$params"
unset params

while true; do
    case "$1" in
        -m|--mode)
            shift
            MODE=${1}
            ;;
        -u|--upstream-repo-url)
            shift
            UPSTREAM_REPO_URL=${1}
            ;;
        -d|--downstream-repo-url)
            shift
            DOWNSTREAM_REPO_URL=${1}
            ;;
        -U|--upstream-branch)
            shift
            UPSTREAM_BRANCH=${1}
            ;;
        -D|--downstream-branch)
            shift
            DOWNSTREAM_BRANCH=${1}
            ;;
        -t|--token)
            shift
            GITHUB_TOKEN=${1}
            ;;
        -S|--merge-strategy)
            shift
            MERGE_STRATEGY=${1}
            ;;   
        -h|--help)
            usage
            ;;
        -v|--verbose)
            NOT_VERBOSE_GIT=""
            ;;
        --spawn-logs)
            shift
            SPAWN_LOGS=${1}
            ;;
        --)
            shift
            break
            ;;
    esac

    shift
done

[[ -z "${MODE} " ]] && echo "Missing run mode" && exit 1


case ${MODE} in
  ${RELEASE_FOLLOWING_MODE})
    dump_vars
    validate_rf_mode_args
    repo_setup
    do_rf_synch
    cleanup
    ;;
  ${BRANCH_TO_BRANCH_MODE})
    dump_vars
    validate_b2b_mode_args
    repo_setup
    do_b2b_synch
    cleanup
    ;;
  *)
    echo "Supplied value for mode ('${MODE}') is invalid."
    exit 1
    ;;
esac
