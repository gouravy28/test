#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This file includes functions shared by the each repository's publish scripts.

set -o errexit
set -o nounset
set -o pipefail

# sync_repo() cherry picks the latest changes in k8s.io/kubernetes/${filter} to the
# local copy of the repository to be published.
#
# prerequisites
# 1. we are in the root of the repository to be published
# 2. we are on the branch to be published (let's call it "target-branch")
# overall flow
# 1. fetch the current level of k8s.io/kubernetes
# 2. check out the $src_branch of k8s.io/kubernetes as branch kube-sync
# 3. rewrite the history of branch kube-sync to *only* include code in $subdirectory
# 4. locate all commits between the last time we sync'ed and now
# 5. switch back to the "target-branch"
# 6. for each commit, cherry-pick it (which will keep authorship) into "target-branch"
# 7. update metadata files indicating which commits we've sync'ed to
sync_repo() {
    # subdirectory in k8s.io/kubernetes, e.g., staging/src/k8s.io/apimachinery
    local subdirectory="${1}"
    local src_branch="${2}"
    local kubernetes_remote="${3:-https://github.com/kubernetes/kubernetes.git}"
    readonly filter src_branch

    local currBranch=$(git rev-parse --abbrev-ref HEAD)
    local previousKubeSHA=$(cat kubernetes-sha)
    
    git remote add upstream-kube "${kubernetes_remote}" || true
    git fetch upstream-kube
    git branch -D kube-sync || true
    git checkout upstream-kube/"${src_branch}" -b kube-sync
    git reset --hard upstream-kube/"${src_branch}"
    
    # this command rewrites git history to *only* include $subdirectory 
    git filter-branch -f --msg-filter 'awk 1 && echo && echo "Kubernetes-commit: ${GIT_COMMIT}"' \
        --subdirectory-filter "${subdirectory}" HEAD

    local newKubeSHA=$(git log kube-sync -1 | tail -n 1 | sed "s/Kubernetes-commit: //g")

    local previousBranchSHA=$(git log --grep "Kubernetes-commit: ${previousKubeSHA}" --format='%H')
    local commits=$(git log --no-merges --format='%H' --reverse ${previousBranchSHA}..HEAD)

    git checkout ${currBranch}

    # we must reset Godeps.json to what it looked like BEFORE the last vendor sync so that any
    # new Godep.json changes from k8s.io/kubernetes will apply cleanly.  Since its always auto-generated
    # it doesn't matter that we're removing it
    lastResyncCommit=$(git rev-list -n 1 --grep "sync: resync vendor folder" HEAD)
    cleanGodepJsonCommit=$(git rev-list -n 1 ${lastResyncCommit}^)
    git checkout ${cleanGodepJsonCommit} Godeps/Godeps.json
    if git diff --cached --exit-code &>/dev/null; then
        echo "no need to reset Godeps.json!"
    else
        git -c user.name="Kubernetes Publisher" -c user.email="k8s-publish-robot@users.noreply.github.com" commit -m "sync: reset Godeps.json" -- Godeps/Godeps.json
    fi

    echo "commits to be cherry-picked:"
    echo "${commits}"
    echo ""
    
    while read commitSHA; do
        if [[ -z "${commitSHA}" ]]; then
            continue
        fi
    	echo "working ${commitSHA}"
    	git -c user.name="Kubernetes Publisher" -c user.email="k8s-publish-robot@users.noreply.github.com" cherry-pick ${commitSHA}
    done <<< "${commits}"
    
    # track the k8s.io/kubernetes commit SHA so we can always determine which level of kube this repo matches
    # track the filtered branch commit SHA so that we can determine which commits need to be picked
    echo ${newKubeSHA} > kubernetes-sha
    if git diff --exit-code &>/dev/null; then
        echo "SHAs haven't changed!"
        return
    fi
    git -c user.name="Kubernetes Publisher" -c user.email="k8s-publish-robot@users.noreply.github.com" commit -m "sync(k8s.io/kubernetes) ${newKubeSHA}" -- kubernetes-sha
}

# deduplicate_commits reset branch to origin/branch if they are the same.
# This function assumes the work directory is the repo that needs to deduplication.
deduplicate_commits() {
    local branch="${1}"
    if git diff origin/"${branch}" "${branch}" --exit-code &>/dev/null; then
        if [ "$(git rev-parse --abbrev-ref HEAD)" = "${branch}" ]; then
            git reset --hard origin/"${branch}"
        else
            git branch -f "${branch}" origin/"${branch}"
        fi
    fi
}

# To avoid repeated godep restore, repositories should share the GOPATH.
# This function should be run after the Godeps.json are updated with the latest
# revisions of k8s.io/* dependencies.
# This function assumes to be called at the root of the repository that's going to be published.
# This function assumes the branch that need update is checked out.
# This function assumes it's the last step in the publishing process that's going to generate commits.
restore_vendor() {
    # deps are expected to be separated by ",", e.g., "client-go,apimachinery".
    # We will expand it to "repo:commit,repo:commit..." when a release branch of a
    # k8s.io repo needs to track a specific revision of other k8s.io/* repos.
    local deps="${1:-""}"
    IFS=',' read -a deps <<< "${DEPS}"
    dep_count=${#deps[@]}
    for (( i=0; i<${dep_count}; i++ )); do
        pushd ../"${deps[i]}"
            # currently we assume the repo depends on the master branch of dep.
            git checkout master
        popd
    done

    local is_library="${2}"
    # At this step, currently only client-go's Godeps.json contains entries for
    # k8s.io repos, with commit hash of the first commit in the master branch.
    godep restore
    # need to remove the Godeps folder, otherwise godep won't save source code to vendor/
    rm -rf ./Godeps
    godep save ./...
    if [ "${is_library}" = "true" ]; then
        echo "remove k8s.io/* and glog from vendor/"
        # glog uses global variables, it panics when multiple copies are compiled.
        rm -rf ./vendor/github.com/golang/glog
        # this ensures users who get the repository via `go get` won't end up with
        # multiple copies of k8s.io/ repos. The only copy will be the one in the
        # GOPATH.
        # Godeps.json has a complete, up-to-date list of dependencies, so
        # Godeps.json will be the ground truth for users using godep/glide/dep.
        rm -rf ./vendor/k8s.io
    fi
    git add --all
    # check if there are new contents 
    if git diff --cached --exit-code &>/dev/null; then
        echo "vendor hasn't changed!"
        return
    fi
    git -c user.name="Kubernetes Publisher" -c user.email="k8s-publish-robot@users.noreply.github.com" commit -m "sync: resync vendor folder"

    # Here is the last chance to generate/reverse commits. Otherwise dependent repo's Godeps.json will contain stale/invalid commit hashes.
    # deduplicate commits. 
    deduplicate_commits "$(git rev-parse --abbrev-ref HEAD)"
}

# set up github token in ~/.netrc
set_github_token() {
    mv ~/.netrc ~/.netrc.bak || true
    echo "machine github.com login ${1}" > ~/.netrc
}

cleanup_github_token() {
    rm -rf ~/.netrc
    mv ~/.netrc.bak ~/.netrc || true
}

# updates commit hash of k8s.io/${1}
update_godeps_json() {
    local repo=${1}
    local godeps_json="./Godeps/Godeps.json"
    local old_revs=""
    # TODO: pass in the new_rev if we want to depend on a specific revision.
    local new_rev=$(cd ../${repo}; git rev-parse master)

    # TODO: simplify the following lines
    while read path rev; do
        if [[ "${path}" == "k8s.io/${repo}"* ]]; then
            old_revs+="${rev}"$'\n'
        fi
    done < <(jq '.Deps|.[]|.ImportPath + " " + .Rev' -r < "${godeps_json}")
    old_revs=$(echo "${old_revs%%$'\n'}" | sort | uniq)
    while read old_rev; do
        if [[ -z "${old_rev}" ]]; then
            continue
        fi
        sed -i "s|${old_rev}|${new_rev}|g" "${godeps_json}"
    done <<< "${old_revs}"
}
