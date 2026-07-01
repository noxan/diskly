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
DIST_ZIP="$APP-dist.zip"

err()  { echo "error: $*" >&2; exit 1; }
info() { echo "▸ $*"; }

# Locate Sparkle's signing tools in the SPM checkout (populated by `make dist`).
sparkle_bin() {
  local f
  f=$(find ~/Library/Developer/Xcode/DerivedData/Diskly-* -type f \
        -path "*/Sparkle/bin/sign_update" 2>/dev/null | head -1)
  [[ -n "$f" ]] && dirname "$f"
}

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

# --- 2. Build + sign + notarize + staple ---
info "Building, signing, and notarizing Release"
BUILD_LOG=$(mktemp)
if ! make dist > "$BUILD_LOG" 2>&1; then
  tail -30 "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  err "build failed"
fi
rm -f "$BUILD_LOG"
[[ -f "$DIST_ZIP" ]] || err "build finished but $DIST_ZIP not found"

RELEASE_ZIP="$APP-v$NEW_VER.zip"
mv "$DIST_ZIP" "$RELEASE_ZIP"
info "Built $RELEASE_ZIP"

# --- 2b. Sign the update archive with Sparkle EdDSA ---
SPARKLE_BIN=$(sparkle_bin)
[[ -n "$SPARKLE_BIN" ]] || err "Sparkle tools not found — run 'xcodebuild -project Diskly.xcodeproj -resolvePackageDependencies' first"
info "Signing update archive with Sparkle EdDSA (allow keychain access if prompted)"
EDSIG=$("$SPARKLE_BIN/sign_update" -p "$RELEASE_ZIP" 2>/dev/null) \
  || err "Sparkle EdDSA signing failed (allow Keychain access when prompted)"
LENGTH=$(stat -f%z "$RELEASE_ZIP")
[[ -n "$EDSIG" ]] || err "Sparkle signing produced no signature"
info "EdDSA: ${EDSIG:0:24}…  ($LENGTH bytes)"

# --- 3. Generate changelog (LLM-assisted) ---
PREV_TAG="v$CUR_VER"
NOTES_FILE=$(mktemp)
TODAY=$(date +%Y-%m-%d)

# Collect commits since the last release tag, including full bodies so the
# LLM has context for grouping. Fall back to all history on the very first
# release (no previous tag exists yet).
if git rev-parse "$PREV_TAG" >/dev/null 2>&1; then
  COMMITS=$(git log --format='- %h %s%n%b' "$PREV_TAG"..HEAD)
else
  COMMITS=$(git log --format='- %h %s%n%b')
fi

if [[ -n "$COMMITS" ]]; then
  info "Drafting release notes with Claude Haiku"
  PROMPT="You are writing release notes for Diskly version $NEW_VER (released $TODAY).
Below is the git commit log since the previous release. Produce a keep-a-changelog
formatted markdown section, exactly this structure and nothing else:

## v$NEW_VER — $TODAY

### Added
- bullet items  (omit the section entirely if empty)

### Changed
- bullet items  (omit if empty)

### Fixed
- bullet items  (omit if empty)

Rules:
- Only output the markdown section above. No preamble, no code fences, no commentary.
- Use Conventional Commit prefixes (feat, fix, perf, refactor, docs, chore, release)
  to decide which section each change belongs in. feat/perf -> Added or Changed;
  fix -> Fixed; refactor -> Changed; docs/chore/release -> omit unless user-visible.
- Rephrase commit subjects as user-facing prose (imperative or past tense, lowercase
  start, no trailing period). Drop internal/jargon commits entirely.
- Merge closely related commits into single bullets. Prefer <=6 bullets per section.
- Strip the 'feat:'/'fix:' prefixes from the output bullets.

Commit log:

$COMMITS"

  if command -v claude >/dev/null 2>&1; then
    CLAUDE_LOG=$(mktemp)
    printf '%s' "$PROMPT" | claude --model haiku -p > "$NOTES_FILE" 2>"$CLAUDE_LOG" \
      || { tail -5 "$CLAUDE_LOG" >&2; rm -f "$CLAUDE_LOG"; err "claude failed to generate release notes"; }
    rm -f "$CLAUDE_LOG"
  else
    err "claude CLI not found (install Claude Code: npm i -g @anthropic-ai/claude-code)"
  fi

  # Sanitize: strip any stray code fences the model may have wrapped around output.
  perl -0777 -pi -e 's/^```[a-zA-Z]*\n//; s/\n```\s*$//' "$NOTES_FILE"
  [[ -s "$NOTES_FILE" ]] || err "claude returned empty release notes"
  info "Notes drafted ($(wc -l < "$NOTES_FILE") lines)"

  # Prepend section to CHANGELOG.md (preserve a top-level title if present).
  CHANGELOG="CHANGELOG.md"
  if [[ -f "$CHANGELOG" ]]; then
    tmp=$(mktemp)
    if head -1 "$CHANGELOG" | grep -q '^# '; then
      { head -1 "$CHANGELOG"; echo; cat "$NOTES_FILE"; echo; tail -n +2 "$CHANGELOG"; } > "$tmp"
    else
      { cat "$NOTES_FILE"; echo; cat "$CHANGELOG"; } > "$tmp"
    fi
    mv "$tmp" "$CHANGELOG"
  else
    { echo "# Changelog"; echo; cat "$NOTES_FILE"; echo; } > "$CHANGELOG"
  fi
  info "Updated $CHANGELOG"
else
  info "No new commits since $PREV_TAG — skipping changelog"
  echo "## v$NEW_VER — $TODAY" > "$NOTES_FILE"
  echo >> "$NOTES_FILE"
  echo "No changes since v$CUR_VER." >> "$NOTES_FILE"
fi

# --- 4. Commit + tag ---
info "Committing"
git add "$PBXPROJ" CHANGELOG.md 2>/dev/null || git add "$PBXPROJ"
git commit -m "release: v$NEW_VER (build $NEW_BUILD)"
git tag "$TAG"

# --- 5. Push ---
info "Pushing"
git push
git push origin "$TAG"

# --- 6. GitHub release ---
info "Creating GitHub release"
gh release create "$TAG" "$RELEASE_ZIP" --title "v$NEW_VER" --notes-file "$NOTES_FILE"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# --- 7. Generate + upload Sparkle appcast ---
# Single-item feed describing this release. Hosted at the stable URL
# …/releases/latest/download/appcast.xml (GitHub redirects "latest" to the
# newest release's assets), so SUFeedURL never needs to change between versions.
info "Generating appcast"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$RELEASE_ZIP"
PUBDATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
DEPLOY_TARGET=$(grep -m1 'MACOSX_DEPLOYMENT_TARGET' "$PBXPROJ" | sed 's/.*= *//;s/;.*//')

python3 - "$NEW_VER" "$NEW_BUILD" "$PUBDATE" "$DEPLOY_TARGET" \
        "$DOWNLOAD_URL" "$EDSIG" "$LENGTH" "$REPO" "$NOTES_FILE" <<'PYEOF' > appcast.xml
import sys, html
ver, build, pubdate, dep, url, sig, length, repo, notesfile = sys.argv[1:]
with open(notesfile) as f:
    notes = f.read().strip()
notes = notes.replace("]]>", "]]]]><![CDATA[>")
print(f'''<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Diskly</title>
    <link>https://github.com/{repo}/releases</link>
    <description>Most recent Diskly releases.</description>
    <language>en</language>
    <item>
      <title>Version {html.escape(ver)}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(ver)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{dep}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" sparkle:edSignature="{sig}" length="{length}" type="application/zip" />
    </item>
  </channel>
</rss>''')
PYEOF

gh release upload "$TAG" appcast.xml --clobber
rm -f "$NOTES_FILE"

info "Done → https://github.com/$REPO/releases/tag/$TAG"
info "Appcast → https://github.com/$REPO/releases/latest/download/appcast.xml"
