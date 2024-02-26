#!/bin/bash
set -u

podman build -t sync-upstream-repo:latest -f Dockerfile .
function before_all () {
    rm -rf test 
    mkdir -p test
    [[ $? -gt 0 ]] && echo "Failed to create test directory" && exit 1

    git clone --quiet https://github.com/z103cb/openvino_model_server.git test
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
podman run sync-upstream-repo:latest -h
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

podman run sync-upstream-repo:latest --help
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

podman run sync-upstream-repo:latest -m foobar
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

podman run sync-upstream-repo:latest --mode fo0bar
[[ $? -eq 0 ]] && echo "repo sync failed" && exit 1

before_all

# test branch 2 branch synching
podman run sync-upstream-repo:latest -m branch-to-branch \
                                     -u https://github.com/openvinotoolkit/model_server.git \
                                     -d https://github.com/z103cb/openvino_model_server.git \
                                     -U main \
                                     -D main \
                                     -S rebase \
                                     -t $GHA_ACTION
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1

# test branch 2 branch with a non existing downstream branch
# this test also sets up the next test case 
# as releases/2023/2 is an older release branch

podman run sync-upstream-repo:latest --mode branch-to-branch \
                                     --upstream-repo-url https://github.com/openvinotoolkit/model_server.git \
                                     --downstream-repo-url https://github.com/z103cb/openvino_model_server.git \
                                     --upstream-branch releases/2023/2 \
                                     --downstream-branch release \
                                     --token $GHA_ACTION
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1

#validate that a release branch now exists in origin
git fetch origin
(git branch -a -v | grep release) || { echo "Missing release branch" && exit 2 ; }



# test release following branch, this should detect that there is a newer releases/2023/3 branch
podman run sync-upstream-repo:latest --mode release-following \
                                     --upstream-repo-url https://github.com/openvinotoolkit/model_server.git \
                                     --upstream-branch 'releases/20*' \
                                     --downstream-repo-url https://github.com/z103cb/openvino_model_server.git \
                                     --downstream-branch release \
                                     --token $GHA_ACTION
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
podman run sync-upstream-repo:latest --mode release-following \
                                     --upstream-repo-url https://github.com/openvinotoolkit/model_server.git \
                                     --upstream-branch 'releases/20*' \
                                     --downstream-repo-url https://github.com/z103cb/openvino_model_server.git \
                                     --downstream-branch release \
                                     --token $GHA_ACTION \
                                     --merge-strategy rebase 
[[ $? -gt 0 ]] && echo "repo sync failed" && exit 1
git fetch origin
git pull --rebase
git branch -a -v
# get the current origin release commit
origin_release_commit=`git ls-remote --heads --refs origin refs/heads/release | awk '{gsub("refs/heads/","", $2); print $1}'`
[[ "${origin_release_commit}" == "${old_release_commit}" ]] || { echo "The release commits should not different. Got origin_release_commit=${origin_release_commit}, ${old_release_commit}" && exit 2 ;}

after_all
