#!/usr/bin/env bash
set -euo pipefail

# Diskly release script — semantic version bump, build, tag, GitHub release.
#
# Usage:
#   ./release.sh                  # interactive prompt
#   ./release.sh patch            # semantic bump
#   ./release.sh --version 0.1    # explicit version

APP="Diskly"
PROJECT="Diskly.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SHARE_ZIP="$APP-share.zip"

err()  { echo "error: $*" >&2; exit 1; }
info() { echo "▸ $*"; }

current_version() { grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= *//;s/;.*//'; }
current_build()   { grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | sed 's/.*= *//;s/;.*//'; }

bump_version() {
  local ver="$1" type="$2" major minor patch
  IFS='.' read -r major minor patch <<< "$ver"
  minor="${minor:-0}"
  case "$type" in
    major) major=$((major+1)); minor=0; patch=0 ;;
    minor) minor=$((minor+1)); patch=0 ;;
    patch) patch=$(( ${patch:-0} + 1 )) ;;
  esac
  if [[ -n "${patch:-}" && "$patch" != "0" ]]; then
    echo "$major.$minor.$patch"
  else
    echo "$major.$minor"
  fi
}

# --- Pre-flight ---
command -v gh >/dev/null 2>&1 || err "gh CLI not found (brew install gh)"
gh auth status >/dev/null 2>&1 || err "gh not authenticated (gh auth login)"
[[ -f "$PBXPROJ" ]] || err "no $PBXPROJ — run from project root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || err "not a git repo"

if ! git diff --quiet || ! git diff --cached --quiet; then
  err "uncommitted changes — commit or stash first"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  echo "warning: on branch '$BRANCH' (not main)" >&2
fi

# --- Read current ---
CUR_VER=$(current_version)
CUR_BUILD=$(current_build)
NEW_BUILD=$((CUR_BUILD + 1))

# --- Determine new version ---
BUMP="${1:-}"
NEW_VER=""

if [[ -n "$BUMP" ]]; then
  case "$BUMP" in
    major|minor|patch) NEW_VER=$(bump_version "$CUR_VER" "$BUMP") ;;
    --version)
      NEW_VER="${2:?--version requires a value (e.g. 0.1)}"
      NEW_VER="${NEW_VER#v}"
      ;;
    *) err "usage: $0 [major|minor|patch|--version X.Y.Z]" ;;
  esac
else
  echo "Current: v$CUR_VER (build $CUR_BUILD)"
  echo
  echo "  1) major   → $(bump_version "$CUR_VER" major)"
  echo "  2) minor   → $(bump_version "$CUR_VER" minor)"
  echo "  3) patch   → $(bump_version "$CUR_VER" patch)"
  echo "  4) explicit"
  echo
  read -rp "Choose [1-4]: " choice
  case "$choice" in
    1) NEW_VER=$(bump_version "$CUR_VER" major) ;;
    2) NEW_VER=$(bump_version "$CUR_VER" minor) ;;
    3) NEW_VER=$(bump_version "$CUR_VER" patch) ;;
    4) read -rp "Version: " NEW_VER; [[ -n "$NEW_VER" ]] || err "no version given" ;;
    *) err "invalid choice" ;;
  esac
fi

TAG="v$NEW_VER"
git rev-parse "$TAG" >/dev/null 2>&1 && err "tag $TAG already exists"

echo
echo "  $CUR_VER → $NEW_VER   (build $CUR_BUILD → $NEW_BUILD)"
echo
read -rp "Proceed? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }

# --- 1. Bump version + build number ---
info "Setting version $NEW_VER (build $NEW_BUILD)"
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $NEW_VER;/" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" "$PBXPROJ"

# --- 2. Build + zip (ad-hoc signed, no notarization) ---
info "Building Release"
BUILD_LOG=$(mktemp)
if ! make share > "$BUILD_LOG" 2>&1; then
  tail -30 "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  err "build failed"
fi
rm -f "$BUILD_LOG"
[[ -f "$SHARE_ZIP" ]] || err "build finished but $SHARE_ZIP not found"

RELEASE_ZIP="$APP-v$NEW_VER.zip"
mv "$SHARE_ZIP" "$RELEASE_ZIP"
info "Built $RELEASE_ZIP"

# --- 3. Commit + tag ---
info "Committing"
git add "$PBXPROJ"
git commit -m "release: v$NEW_VER (build $NEW_BUILD)"
git tag "$TAG"

# --- 4. Push ---
info "Pushing"
git push
git push origin "$TAG"

# --- 5. GitHub release ---
info "Creating GitHub release"
gh release create "$TAG" "$RELEASE_ZIP" --title "v$NEW_VER" --generate-notes

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
info "Done → https://github.com/$REPO/releases/tag/$TAG"
