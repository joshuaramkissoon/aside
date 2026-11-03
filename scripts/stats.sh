#!/usr/bin/env bash
# How Aside is doing: DMG downloads per release (GitHub counts every download), stars and repo traffic.
# Site visitors and referrers are in Vercel: project "aside" → Analytics.
set -euo pipefail
REPO="joshuaramkissoon/aside"

echo "Downloads"
gh api "repos/$REPO/releases" --paginate \
  --jq '.[] | "  \(.tag_name)  \([.assets[].download_count] | add // 0)"'
gh api "repos/$REPO/releases" --paginate --jq '[.[].assets[].download_count] | add // 0' \
  | awk '{print "  total   " $1}'

echo "Repo"
gh api "repos/$REPO" --jq '"  stars \(.stargazers_count)  forks \(.forks_count)  watchers \(.subscribers_count)"'
gh api "repos/$REPO/traffic/views" --jq '"  views (14 days)   \(.count), \(.uniques) unique"'
gh api "repos/$REPO/traffic/popular/referrers" --jq '.[] | "  from \(.referrer): \(.count) views, \(.uniques) unique"'
