#!/bin/bash
set -u

UPSTREAM_REPO_URL="https://github.com/openvinotoolkit/model_server.git"
DOWNSTREAM_REPO_URL=""
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
DOCKER_ENGINE=${DOCKER_ENGINE:-"podman"}

function usage () {
  cat << EOF
  entrypoint.sh
    -h          Print this message
    -u <url>    Optional. Upstream repo url defaults to 'https://github.com/openvinotoolkit/model_server.git'
    -d <url>    Required. Downstream repo url.
    -t <value>  Optional. GITHUB token value, if not supplied the environment variable GITHUB_TOKEN value is used.
EOF
  exit 2
}

function dump_vars () {
  echo "Running with these values:"
  echo "    UPSTREAM_REPO_URL='${UPSTREAM_REPO_URL}'"
  echo "    DOWNSTREAM_REPO_URL='${DOWNSTREAM_REPO_URL}'"
  echo "    GITHUB_TOKEN=*******"
}

if [ ${#} -eq 0 ]; then
    usage
fi

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

while getopts "h?u:d:t:" opt; do
  case "$opt" in
    h|\?)
      usage
      ;;
    u)  UPSTREAM_REPO_URL=${OPTARG}
      ;;
    d)  DOWNSTREAM_REPO_URL=${OPTARG}
      ;;
    t)  GITHUB_TOKEN=${OPTARG}
      ;;
  esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

dump_vars
[[ -z "${UPSTREAM_REPO_URL}" ]] && echo "Missing upstream repo value" && exit 1
[[ -z "${DOWNSTREAM_REPO_URL}" ]] && echo "Missing DOWNSTREAM_REPO_URL" && exit 1
[[ -z "${GITHUB_TOKEN}" ]] && echo "Missing GITHUB_TOKEN" && exit 1
 

${DOCKER_ENGINE} build -t sync-upstream-repo:latest -f Dockerfile .
function before_all () {
    rm -rf test 
    mkdir -p test
    [[ $? -gt 0 ]] && echo "Failed to create test directory" && exit 1

    git clone --quiet ${DOWNSTREAM_REPO_URL} test
    cd test || { echo "Missing test dir" && exit 2 ; }
    
    #clean up some branches from origin
    git push origin --delete release
    git push origin --delete releases/2023/2

    #dump all the branches that exist in the repo
    git branch -a -v
}

function after_all () {
  cd ..
  rm -rf test
}

#do command line arguments testing
${DOCKER_ENGINE} run sync-upstream-repo:latest -h
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

${DOCKER_ENGINE} run sync-upstream-repo:latest --help
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

${DOCKER_ENGINE} run sync-upstream-repo:latest -m foobar
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

${DOCKER_ENGINE} run sync-upstream-repo:latest --mode fo0bar
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

before_all

# test branch 2 branch synching
${DOCKER_ENGINE} run sync-upstream-repo:latest -m branch-to-branch \
                                     -u ${UPSTREAM_REPO_URL} \
                                     -d ${DOWNSTREAM_REPO_URL} \
                                     -U main \
                                     -D main \
                                     -S rebase \
                                     -t ${GITHUB_TOKEN}
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1

# test branch 2 branch with a non existing downstream branch
# this test also sets up the next test case 
# as releases/2023/2 is an older release branch

${DOCKER_ENGINE} run sync-upstream-repo:latest  --mode branch-to-branch \
                                                --upstream-repo-url ${UPSTREAM_REPO_URL} \
                                                --downstream-repo-url ${DOWNSTREAM_REPO_URL} \
                                                --upstream-branch releases/2023/2 \
                                                --downstream-branch release \
                                                --token ${GITHUB_TOKEN}
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1

#validate that a release branch now exists in origin
git fetch origin
(git branch -a -v | grep release) || { echo "Missing release branch" && exit 2 ; }



# test release following branch, this should detect that there is a newer releases/2023/3 branch
${DOCKER_ENGINE} run sync-upstream-repo:latest  --mode release-following \
                                                --upstream-repo-url ${UPSTREAM_REPO_URL} \
                                                --upstream-branch 'releases/20*' \
                                                --downstream-repo-url ${DOWNSTREAM_REPO_URL} \
                                                --downstream-branch release \
                                                --token ${GITHUB_TOKEN}
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1
git fetch origin
git branch -a -v
(git branch -a -v | grep release) || { echo "Missing release branch" && exit 2 ; }
(git branch -a -v | grep releases/2023/2) || { echo "Missing releases/2023/2 branch" && exit 2 ;}

# get the current origin release commit
origin_release_commit=`git ls-remote --heads --refs origin refs/heads/release | awk '{gsub("refs/heads/","", $2); print $1}'`
# get the current origin releases/2023/2 commit
origin_release_2023_2_commit=`git ls-remote --heads --refs origin refs/heads/releases/2023/2 | awk '{gsub("refs/heads/","", $2); print $1}'`
[[ "${origin_release_commit}" != "${origin_release_2023_2_commit}" ]] || { echo "The release commits should be different. Got origin_release_commit=${origin_release_commit}, ${origin_release_2023_2_commit}" && exit 2 ;}


# artificially setup a difference in release heads by backing out 2 commits
# this should demonstrate that the of the release branch has occurred
git switch -c release origin/release
#get the 
old_release_commit=`git rev-parse HEAD`
git reset --hard 551f7ea0
git push -f origin
${DOCKER_ENGINE} run sync-upstream-repo:latest  --mode release-following \
                                                --upstream-repo-url ${UPSTREAM_REPO_URL} \
                                                --upstream-branch 'releases/20*' \
                                                --downstream-repo-url ${DOWNSTREAM_REPO_URL} \
                                                --downstream-branch release \
                                                --token ${GITHUB_TOKEN} \
                                                --merge-strategy rebase 
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1
git fetch origin
git pull --rebase
git branch -a -v
# get the current origin release commit
origin_release_commit=`git ls-remote --heads --refs origin refs/heads/release | awk '{gsub("refs/heads/","", $2); print $1}'`
[[ "${origin_release_commit}" == "${old_release_commit}" ]] || { echo "The release commits should not different. Got origin_release_commit=${origin_release_commit}, ${old_release_commit}" && exit 2 ;}

after_all
