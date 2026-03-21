#!/bin/bash
set -e

# ============================================================================
# Portable Job Applications — Sync from Private Repo
#
# Syncs clean source from bot_army_job_applications (private) to
# portable_job_applications (public mirror), stripping personal data.
#
# Usage:
#   ./sync.sh                 # Sync from ../bot_army_job_applications
#   ./sync.sh /path/to/repo   # Sync from custom path
#
# What gets stripped:
#   - priv/repo/migrations/*  (keep portable/ only)
#   - Any future personal seed data
#   - Personal configs (none currently)
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_REPO="$SCRIPT_DIR"
PRIVATE_REPO="${1:-../bot_army_job_applications}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}Portable Job Applications — Sync${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""

# Verify paths
if [ ! -d "$PRIVATE_REPO/.git" ]; then
  echo -e "${RED}✗ Error: Private repo not found at $PRIVATE_REPO${NC}"
  exit 1
fi

if [ ! -d "$PORTABLE_REPO/.git" ]; then
  echo -e "${RED}✗ Error: Portable repo not found at $PORTABLE_REPO${NC}"
  exit 1
fi

echo "Private repo: $PRIVATE_REPO"
echo "Portable repo: $PORTABLE_REPO"
echo ""

# Step 1: Get latest from private repo
echo -e "${YELLOW}Step 1: Fetching latest from private repo...${NC}"
cd "$PRIVATE_REPO"
git fetch origin main 2>/dev/null || true
git checkout main 2>/dev/null || true
PRIVATE_COMMIT=$(git rev-parse --short HEAD)
echo "Private repo at commit: $PRIVATE_COMMIT"
echo ""

# Step 2: Create temp directory for sync
echo -e "${YELLOW}Step 2: Preparing sync...${NC}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Temp directory: $TEMP_DIR"
cp -r "$PRIVATE_REPO"/* "$TEMP_DIR/" 2>/dev/null || true
cp -r "$PRIVATE_REPO"/.[^.]* "$TEMP_DIR/" 2>/dev/null || true
echo ""

# Step 3: Strip personal migrations
echo -e "${YELLOW}Step 3: Stripping personal data...${NC}"

# Remove main migrations directory, keep portable only
if [ -d "$TEMP_DIR/priv/repo/migrations" ]; then
  echo "  - Removing priv/repo/migrations/ (keeping portable/)"
  PORTABLE_MIGRATIONS=$(find "$TEMP_DIR/priv/repo/migrations/portable" -type f 2>/dev/null | wc -l)
  rm -rf "$TEMP_DIR/priv/repo/migrations"/*
  mkdir -p "$TEMP_DIR/priv/repo/migrations"

  # Restore portable migrations
  if [ -d "$PRIVATE_REPO/priv/repo/migrations/portable" ]; then
    cp -r "$PRIVATE_REPO/priv/repo/migrations/portable"/* "$TEMP_DIR/priv/repo/migrations/" 2>/dev/null || true
    echo "    ✓ Restored $PORTABLE_MIGRATIONS portable migrations"
  fi
fi

# Remove priv/repo/seeds if it exists (personal seed data)
if [ -d "$TEMP_DIR/priv/repo/seeds" ]; then
  echo "  - Removing priv/repo/seeds/ (personal data)"
  rm -rf "$TEMP_DIR/priv/repo/seeds"
fi

echo ""

# Step 4: Copy to portable repo
echo -e "${YELLOW}Step 4: Updating portable repository...${NC}"
cd "$PORTABLE_REPO"

# Clear old files but keep .git
find . -mindepth 1 -not -name '.git' -not -name 'sync.sh' -delete

# Copy cleaned files
cp -r "$TEMP_DIR"/* . 2>/dev/null || true
cp -r "$TEMP_DIR"/.[^.]* . 2>/dev/null || true

echo "  ✓ Files synced"
echo ""

# Step 5: Commit if there are changes
echo -e "${YELLOW}Step 5: Committing changes...${NC}"

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit (already in sync)"
else
  git add -A

  COMMIT_MSG="Sync from bot_army_job_applications@$PRIVATE_COMMIT

Auto-synced portable version:
- Stripped personal migrations
- Kept portable/migrations/ only
- Ready for public distribution

Private commit: $PRIVATE_COMMIT
Synced at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  git commit -m "$COMMIT_MSG"
  COMMIT_HASH=$(git rev-parse --short HEAD)
  echo -e "  ${GREEN}✓ Committed as $COMMIT_HASH${NC}"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Sync complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo "  git log --oneline -5          # View recent commits"
echo "  git push origin main          # Push to public mirror"
echo ""
