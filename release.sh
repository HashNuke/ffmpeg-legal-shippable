#!/usr/bin/env bash
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

usage() {
  cat <<'EOF'
Usage:
  ./release.sh <release-tag>

Example:
  ./release.sh 8.0.1-202603021130

What it does:
  1) Tags the current commit with <release-tag>
  2) Pushes the tag to origin
  3) Creates a GitHub Release and uploads matching dist/*.tar.gz assets

Notes:
  - Expects artifacts already built under dist/ with names like:
      dist/ffmpeg-<release-tag>-macos-universal.tar.gz
  - Uploads ONLY .tar.gz files (no raw binaries, no .sha256).
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    usage
    exit 0
  fi

  local TAG="$1"

  need git
  need gh

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree is not clean. Commit or stash changes before releasing." >&2
    exit 1
  fi

  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag already exists: $TAG" >&2
    exit 1
  fi

  shopt -s nullglob
  local ASSETS=(dist/ffmpeg-"$TAG"-*.tar.gz dist/*"$TAG"*.tar.gz)
  shopt -u nullglob

  if [[ "${#ASSETS[@]}" -eq 0 ]]; then
    echo "No .tar.gz assets found for tag '$TAG' under dist/." >&2
    echo "Expected something like: dist/ffmpeg-$TAG-macos-universal.tar.gz" >&2
    exit 1
  fi

  echo "Tagging commit..."
  git tag -a "$TAG" -m "$TAG"

  echo "Pushing tag to origin..."
  git push origin "$TAG"

  echo "Creating GitHub Release and uploading assets:"
  printf '  - %s\n' "${ASSETS[@]}"

  gh release create "$TAG" "${ASSETS[@]}" --title "$TAG" --generate-notes

  echo "Release created: $TAG"
}

main "$@"

