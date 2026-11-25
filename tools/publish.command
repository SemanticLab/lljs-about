#!/bin/bash
# Publish the working copy from macOS Terminal using the owner's GitHub CLI and SSH access.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=SemanticLab/lljs-about
remote="git@github.com:${repo}.git"
branch=$(gh api "repos/$repo" --jq '.default_branch // "main"')
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [[ ! -e .git ]]; then
  # Keep the remote history and any files already in the repository.
  git clone "$remote" "$scratch/checkout"
  rsync -a --ignore-existing --exclude='/.git' "$scratch/checkout/" ./
  mv "$scratch/checkout/.git" .git
fi
if [[ $(git remote get-url origin) != "$remote" ]]; then
  echo "Expected origin to be $remote. Check this working copy." >&2
  exit 1
fi
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git symbolic-ref HEAD "refs/heads/$branch"
fi
if [[ $(git branch --show-current) != "$branch" ]]; then
  echo "Run this from the repository's default branch ($branch)." >&2
  exit 1
fi

enable_pages() {
  local mode
  if mode=$(gh api "repos/$repo/pages" --jq .build_type 2>/dev/null); then
    if [[ $mode != workflow ]]; then
      gh api --method PUT "repos/$repo/pages" -f build_type=workflow --silent
    fi
  else
    gh api --method POST "repos/$repo/pages" -f build_type=workflow --silent
  fi
}

git fetch origin
remote_commit=$(git rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)
if [[ -n $remote_commit ]]; then
  git merge --ff-only "$remote_commit"
  enable_pages
fi
files=(.github/workflows/pages.yml .nojekyll LICENSE index.html home assets about-linked-data
       links-resources models recommendations updates tools/capture-site.command
       tools/unpack_capture.py tools/publish.command)
git add -- "${files[@]}"
if ! git diff --cached --quiet -- "${files[@]}"; then
  git commit --only -m "Publish the Linking Lost Jazz Shrines static site" -- "${files[@]}"
fi
commit=$(git rev-parse HEAD)
git push -u origin "HEAD:refs/heads/$branch"

event=push
previous_run=0
if [[ -z $remote_commit || $remote_commit == "$commit" ]]; then
  # Empty repositories may need a default branch before Pages can be enabled.
  enable_pages
  event=workflow_dispatch
  previous_run=$(gh run list --repo "$repo" --event "$event" --commit "$commit" \
    --workflow pages.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null || echo 0)
  gh workflow run pages.yml --repo "$repo" --ref "$branch"
fi

echo "Waiting for the Pages workflow for ${commit}..."
for ((attempt=0; attempt<60; attempt++)); do
  run=$(gh run list --repo "$repo" --workflow pages.yml --event "$event" --commit "$commit" \
    --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
  if [[ -n $run && $run != "$previous_run" ]]; then
    gh run watch "$run" --repo "$repo" --exit-status
    url=$(gh api "repos/$repo/pages" --jq .html_url)
    echo "Published $url"
    exit 0
  fi
  sleep 2
done
echo "Pushed $commit. Check the workflow at https://github.com/$repo/actions/workflows/pages.yml" >&2
exit 1
