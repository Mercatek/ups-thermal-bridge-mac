#!/bin/bash
#
# Commit all changes and push to GitHub. Auth is handled by the GitHub CLI /
# macOS Keychain (set up once) — no credentials are stored in or read by this
# script.
#
# Usage:  ./publish.sh "your commit message"
#
set -e
cd "$(dirname "$0")"
git add -A
if git diff --cached --quiet; then
  echo "Nothing to commit."
else
  git commit -m "${1:-Update}"
fi
git push
echo "Published to GitHub."
