#!/bin/bash
# Upload the 12 .gz chunks to draft release rootfs-20261120, one at a time.
# Verifies each asset's size via the API after upload; retries a chunk up
# to 3 times. Safe to re-run: --clobber replaces a same-name asset.
set -u
cd ~/workspace/opencode-inbuilt/rootfs-build
REPO=spyboi-dev/opencode-ios
TAG=rootfs-20261120
REL_ID=453414533
LOG=upload-chunks.log
: > "$LOG"
echo "started $(date -u +%FT%TZ)" | tee -a "$LOG"
for i in $(seq -w 0 11); do
  f="opencode-debian-trixie-arm64.ext4.gz.part$i"
  want=$(stat -c%s "$f")
  ok=0
  for attempt in 1 2 3; do
    echo "[$f] attempt $attempt size $want" | tee -a "$LOG"
    if timeout 600 gh release upload "$TAG" "$f" --repo "$REPO" --clobber >>"$LOG" 2>&1; then
      got=$(gh api "repos/$REPO/releases/$REL_ID" --jq ".assets[] | select(.name==\"$f\") | .size" 2>/dev/null | head -1)
      if [ "$got" = "$want" ]; then
        echo "[$f] OK size $got" | tee -a "$LOG"
        ok=1; break
      else
        echo "[$f] size mismatch after upload: got=$got want=$want" | tee -a "$LOG"
      fi
    else
      echo "[$f] upload command failed (attempt $attempt)" | tee -a "$LOG"
    fi
    sleep 10
  done
  [ "$ok" = 1 ] || echo "[$f] FAILED after 3 attempts" | tee -a "$LOG"
done
echo "--- final asset list ---" | tee -a "$LOG"
gh api "repos/$REPO/releases/$REL_ID" --jq '.assets[] | "\(.name) \(.size)"' 2>&1 | tee -a "$LOG"
echo "finished $(date -u +%FT%TZ)" | tee -a "$LOG"
