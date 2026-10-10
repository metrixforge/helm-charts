#!/usr/bin/env bash
#
# Release a new chart version.
#
#   ./release.sh <chart> <appVersion> [chartVersion]
#   ./release.sh uni-exporter 1.0.39          # chart version patch-bumps automatically
#   ./release.sh uni-security 1.0.8 1.0.0     # explicit chart version (template changes)
#
# 🔴 The chart NAME is a parameter because this was hardcoded to uni-exporter in
# five places — the directory, the Docker Hub repository it verifies, the
# rendered-image assertion and two log lines. A second chart could not be
# released without editing the script, which is exactly the state in which a
# chart gets published by hand and skips every check below.
#
# A fresh `helm install` resolves the image as `image.tag | default .Chart.AppVersion`,
# so appVersion IS what a new customer gets. Leaving it behind the fleet is not a
# cosmetic drift: chart 1.2.0 shipped appVersion 1.0.27 while the fleet ran 1.0.38,
# which meant every new onboarding started eleven patches back.
#
# This script does NOT push. It stages both branches and prints the commands.
set -euo pipefail

REPO_URL="https://metrixforge.github.io/helm-charts"
NAME="${1:?usage: release.sh <chart> <appVersion> [chartVersion]}"
APP="${2:?usage: release.sh <chart> <appVersion> [chartVersion]}"
cd "$(dirname "$0")"
CHART_DIR="charts/$NAME"
[ -f "$CHART_DIR/Chart.yaml" ] || { echo "FATAL: no chart at $CHART_DIR"; exit 1; }
# Read the image repository FROM the chart rather than assuming it. The one
# defect this script already exists to prevent was a chart pointing at an image
# repository that did not exist, so the repository is not a thing to hardcode
# twice and hope they agree.
IMAGE_REPO=$(awk '/^image:/{inblock=1; next} /^[^ #]/{inblock=0} inblock && $1=="repository:"{print $2; exit}' "$CHART_DIR/values.yaml")
[ -n "$IMAGE_REPO" ] || { echo "FATAL: could not read image.repository from $CHART_DIR/values.yaml"; exit 1; }

cur_chart=$(awk '/^version:/{print $2}' "$CHART_DIR/Chart.yaml")
if [ $# -ge 3 ]; then
  CHART="$3"
else
  CHART=$(echo "$cur_chart" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
fi

echo "==> $NAME  chart $cur_chart -> $CHART   appVersion -> $APP"

# 🔴 Never publish a chart pinning an image that does not exist. A chart is
# public the moment it lands on gh-pages, and a customer hitting ImagePullBackOff
# on their first install is the worst possible first impression.
echo "==> verifying $IMAGE_REPO:$APP exists and is multi-arch"
archs=$(curl -fsS "https://hub.docker.com/v2/repositories/$IMAGE_REPO/tags/$APP" \
        | python3 -c "import sys,json;print(' '.join(sorted({i['architecture'] for i in json.load(sys.stdin)['images']})))") \
  || { echo "FATAL: tag $APP not found on Docker Hub"; exit 1; }
echo "    archs: $archs"
case "$archs" in
  *amd64*) ;; *) echo "FATAL: no amd64 leg"; exit 1 ;;
esac
case "$archs" in
  *arm64*) ;; *) echo "FATAL: no arm64 leg — the fleet is mixed-arch"; exit 1 ;;
esac

sed -i.bak -E "s/^version: .*/version: $CHART/; s/^appVersion: .*/appVersion: \"$APP\"/" "$CHART_DIR/Chart.yaml"
rm -f "$CHART_DIR/Chart.yaml.bak"
helm lint "$CHART_DIR" >/dev/null && echo "==> lint ok"

# Render once with defaults and assert the image really resolves to the new tag —
# cheap insurance against a values.yaml change silently overriding appVersion.
# Assert on the FULL rendered reference — registry, repository AND tag. Checking
# only the tag is exactly what let the chart sit for a month pointing at an image
# repository that did not exist: the tag was always right, the repository was
# always wrong, and nobody had installed from the public repo to find out.
# 🔴 `sort -u | head -1` used to pick ONE image here. With a single container
# that was the right one by luck; add a sidecar, an init container or a second
# workload whose image sorts earlier and the assertion starts checking an image
# this script was never asked about — while the chart's own image goes
# unverified. Assert membership in the full rendered set instead.
rendered=$(helm template t "$CHART_DIR" --set-string credentials.appId=x --set-string credentials.appSecret=y \
           | grep -oE 'image: "[^"]+"' | sed 's/image: "//; s/"$//' | sort -u)
[ -n "$rendered" ] || { echo "FATAL: chart rendered no image at all"; exit 1; }
echo "==> renders as: $(echo "$rendered" | tr '\n' ' ')"
want="docker.io/$IMAGE_REPO:$APP"
echo "$rendered" | grep -qxF "$want" \
  || { echo "FATAL: '$want' is not among the rendered images"; exit 1; }

tmp=$(mktemp -d); helm package "$CHART_DIR" -d "$tmp" >/dev/null
tgz="$tmp/$NAME-$CHART.tgz"
echo "==> packaged $(basename "$tgz")"

# A STABLE path, not mktemp. The first run of this script put the worktree under
# /private/var/folders/.../tmp.XXXX; the operator pushed `main` and the second
# command — against an unreadable temp path — was lost. main is only source;
# gh-pages is what customers actually install from, so losing that half publishes
# nothing while looking done.
wt=".gh-pages"
# 🔴 This guard used to be `[ ! -d "$wt/.git" ]`. In a LINKED worktree .git is a
# FILE holding a gitdir: pointer, never a directory, so the test was true on
# every run after the first and `git worktree add` died with "already exists" —
# after packaging, before staging gh-pages. The script therefore worked exactly
# once per clone and then failed at the only step that reaches customers, which
# is the same outcome the comment above is about. Ask git, not the filesystem.
if git worktree list --porcelain | grep -qxF "worktree $PWD/$wt"; then
  on=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  [ "$on" = "gh-pages" ] || { echo "FATAL: $wt is a worktree but on '$on', not gh-pages"; exit 1; }
  echo "==> reusing existing $wt worktree"
elif [ -e "$wt" ]; then
  echo "FATAL: $wt exists but is not a git worktree — remove it and re-run"; exit 1
else
  git worktree add -q "$wt" gh-pages
fi
grep -qxF "$wt/" .gitignore 2>/dev/null || echo "$wt/" >> .gitignore
cp "$tgz" "$wt/"
( cd "$wt" && helm repo index . --url "$REPO_URL" --merge index.yaml >/dev/null && git add -A )
echo "==> gh-pages staged:"
( cd "$wt" && git status --short | sed 's/^/    /' )
git add "$CHART_DIR/Chart.yaml"

cat <<MSG

==> NOTHING PUSHED. Both halves are required:
      main     — chart source. Changes nothing for customers on its own.
      gh-pages — index.yaml + the .tgz. THIS is what \`helm install\` reads.

    git commit -am "chart: $NAME $CHART — appVersion $APP" && git push origin main
    git -C .gh-pages commit -am "publish $NAME $CHART (appVersion $APP)" && git -C .gh-pages push origin gh-pages

    Then verify (this is the check that matters):
    helm repo update && helm search repo metrixforge --versions | head -3
MSG
