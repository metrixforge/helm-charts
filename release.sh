#!/usr/bin/env bash
#
# Release a new uni-exporter chart version.
#
#   ./release.sh <appVersion> [chartVersion]
#   ./release.sh 1.0.39              # chart version patch-bumps automatically
#   ./release.sh 1.0.39 1.3.0        # explicit chart version (template changes)
#
# A fresh `helm install` resolves the image as `image.tag | default .Chart.AppVersion`,
# so appVersion IS what a new customer gets. Leaving it behind the fleet is not a
# cosmetic drift: chart 1.2.0 shipped appVersion 1.0.27 while the fleet ran 1.0.38,
# which meant every new onboarding started eleven patches back.
#
# This script does NOT push. It stages both branches and prints the commands.
set -euo pipefail

CHART_DIR="charts/uni-exporter"
REPO_URL="https://metrixforge.github.io/helm-charts"
APP="${1:?usage: release.sh <appVersion> [chartVersion]}"
cd "$(dirname "$0")"

cur_chart=$(awk '/^version:/{print $2}' "$CHART_DIR/Chart.yaml")
if [ $# -ge 2 ]; then
  CHART="$2"
else
  CHART=$(echo "$cur_chart" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
fi

echo "==> uni-exporter  chart $cur_chart -> $CHART   appVersion -> $APP"

# 🔴 Never publish a chart pinning an image that does not exist. A chart is
# public the moment it lands on gh-pages, and a customer hitting ImagePullBackOff
# on their first install is the worst possible first impression.
echo "==> verifying felexa/uni-exporter:$APP exists and is multi-arch"
archs=$(curl -fsS "https://hub.docker.com/v2/repositories/felexa/uni-exporter/tags/$APP" \
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
rendered=$(helm template t "$CHART_DIR" --set-string credentials.appId=x --set-string credentials.appSecret=y \
           | grep -oE 'image: "[^"]+"' | sed 's/image: "//; s/"$//' | sort -u | head -1)
echo "==> renders as: $rendered"
want="docker.io/felexa/uni-exporter:$APP"
[ "$rendered" = "$want" ] || { echo "FATAL: renders as '$rendered', expected '$want'"; exit 1; }

tmp=$(mktemp -d); helm package "$CHART_DIR" -d "$tmp" >/dev/null
tgz="$tmp/uni-exporter-$CHART.tgz"
echo "==> packaged $(basename "$tgz")"

# A STABLE path, not mktemp. The first run of this script put the worktree under
# /private/var/folders/.../tmp.XXXX; the operator pushed `main` and the second
# command — against an unreadable temp path — was lost. main is only source;
# gh-pages is what customers actually install from, so losing that half publishes
# nothing while looking done.
wt=".gh-pages"
if [ ! -d "$wt/.git" ]; then
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

    git commit -am "chart: uni-exporter $CHART — appVersion $APP" && git push origin main
    git -C .gh-pages commit -am "publish uni-exporter $CHART (appVersion $APP)" && git -C .gh-pages push origin gh-pages

    Then verify (this is the check that matters):
    helm repo update && helm search repo metrixforge --versions | head -3
MSG
