#!/bin/bash
# Publishes website/ to the gh-pages branch, which GitHub Pages serves at
# https://samir-bujawdeh.github.io/RetroDrop/
# Commit your website changes on main first, then run: scripts/publish-site.sh
set -euo pipefail
cd "$(dirname "$0")/.."
git diff --quiet -- website && git diff --cached --quiet -- website || {
  echo "Commit your changes in website/ first."; exit 1; }
touch website/.nojekyll 2>/dev/null || true  # serve files as-is, no Jekyll processing
git push origin "$(git subtree split --prefix website main)":refs/heads/gh-pages --force
echo "Published. Live in a minute or so at https://samir-bujawdeh.github.io/RetroDrop/"
