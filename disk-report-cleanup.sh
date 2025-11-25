#!/usr/bin/env bash
set -euo pipefail

# disk-console-report-fixed.sh
# Prints a disk-usage report to console only (no files).
# Avoids "Broken pipe" noise from sort/head.
# Usage:
#   ./disk-console-report-fixed.sh
#   ./disk-console-report-fixed.sh --path / --top 50 --depth 20
#   ./disk-console-report-fixed.sh --clean-caches --prune-docker --yes
#
# Flags:
#  --path PATH         path to inspect (default /)
#  --top N             how many top items to show (default 25)
#  --depth D           max-depth for du (default 20)
#  --clean-caches      show candidate caches and optionally clean
#  --prune-docker      show docker prune candidate and optionally prune
#  --aggressive        include aggressive runner/toolcache deletions (dangerous)
#  --yes               actually perform deletions (otherwise dry-run)
#  --help              print this help

PATH_TO_CHECK="/"
TOP_N=25
DEPTH=20
CLEAN_CACHES=0
PRUNE_DOCKER=0
AGGRESSIVE=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) PATH_TO_CHECK="$2"; shift 2;;
    --top) TOP_N="$2"; shift 2;;
    --depth) DEPTH="$2"; shift 2;;
    --clean-caches) CLEAN_CACHES=1; shift;;
    --prune-docker) PRUNE_DOCKER=1; shift;;
    --aggressive) AGGRESSIVE=1; shift;;
    --yes) ASSUME_YES=1; shift;;
    --help) awk 'NR>1{print} /# disk-console-report-fixed.sh/ {exit}' "$0" ; exit 0;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

timestamp() { date -u +"%Y-%m-%d %H:%M:%SZ"; }

printf "\n=== Disk console report (NO FILES) ===\nTime: %s\nInspecting: %s  (top %s, du max-depth=%s)\n\n" "$(timestamp)" "$PATH_TO_CHECK" "$TOP_N" "$DEPTH"

# Show filesystem usage for the path (df on the mount containing path)
df -h "$PATH_TO_CHECK" || df -h

printf "\n--- Top %s directories (du --max-depth=%s) under %s ---\n" "$TOP_N" "$DEPTH" "$PATH_TO_CHECK"
# Use du with user-specified depth. Suppress errors and avoid broken-pipe noise by redirecting sort stderr.
# Keep pipeline robust: redirect sort/numfmt stderr and allow non-zero exit without killing script.
sudo du -xh --max-depth="$DEPTH" "$PATH_TO_CHECK" 2>/dev/null \
  | sort -hr 2>/dev/null \
  | head -n "$TOP_N" \
  | awk '{printf "%8s  %s\n",$1,$2}' 2>/dev/null || true

printf "\n--- Top %s files under %s ---\n" "$TOP_N" "$PATH_TO_CHECK"
# Avoid broken-pipe by disabling pipefail for this pipeline (encapsulated in a subshell).
# This ensures `head` can close early without causing an error that aborts the script, while keeping stderr quiet.
(
  set +o pipefail
  sudo find "$PATH_TO_CHECK" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
    | sort -nr 2>/dev/null \
    | head -n "$TOP_N" \
    | numfmt --field=1 --to=iec --suffix=B 2>/dev/null \
    | awk -F"\t" '{printf "%10s\t%s\n",$1,$2}' 2>/dev/null
) || true

printf "\n--- Top %s items (files + dirs) under %s (du --max-depth=%s) ---\n" "$TOP_N" "$PATH_TO_CHECK" "$DEPTH"
(
  set +o pipefail
  sudo du -ahx --max-depth="$DEPTH" "$PATH_TO_CHECK" 2>/dev/null \
    | sort -hr 2>/dev/null \
    | head -n "$TOP_N" \
    | awk '{printf "%8s  %s\n",$1,$2}' 2>/dev/null
) || true

# Candidate cleanup dry-run printer
print_candidate() {
  local desc="$1"; shift
  local paths=( "$@" )
  printf "\n>>> Candidate cleanup: %s\n" "$desc"
  local any=0
  for p in "${paths[@]}"; do
    if [ -e "$p" ]; then
      # Using sudo du -sh; this writes only to stdout
      sudo du -sh "$p" 2>/dev/null | awk -v path="$p" '{printf "  - %s  -> %s\n", path, $1}'
      any=1
    else
      printf "  - %s  -> not present\n" "$p"
    fi
  done
  if [ "$any" -eq 0 ]; then
    printf "  (nothing present)\n"
  fi
}

# Show and optionally perform cache cleanup
if [ "$CLEAN_CACHES" -eq 1 ]; then
  print_candidate "APT caches" "/var/cache/apt/archives" "/var/lib/apt/lists"
  print_candidate "pip cache (common locations)" "$HOME/.cache/pip" "/root/.cache/pip"
  print_candidate "npm/yarn caches" "$HOME/.npm" "$HOME/.cache/yarn" "/home/runner/.npm"
  print_candidate "runner caches (common)" "/home/runner/.cache" "/home/runner/.npm" "/home/runner/.local/share/Trash"
  printf "\nTo actually remove these, re-run with --yes (and optional --aggressive).\n"
fi

if [ "$CLEAN_CACHES" -eq 1 ] && [ "$ASSUME_YES" -eq 1 ]; then
  printf "\n=== Performing cache cleanup (non-interactive) ===\n"
  if command -v apt-get >/dev/null 2>&1; then
    printf "Cleaning apt caches (apt-get clean + rm lists/archives)...\n"
    sudo apt-get clean -y || true
    sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* 2>/dev/null || true
  fi
  printf "Removing pip caches (if present)...\n"
  sudo rm -rf "$HOME/.cache/pip" /root/.cache/pip 2>/dev/null || true
  if command -v npm >/dev/null 2>&1; then
    printf "Cleaning npm cache (npm cache clean --force)...\n"
    npm cache clean --force 2>/dev/null || sudo rm -rf "$HOME/.npm" /home/runner/.npm 2>/dev/null || true
  else
    sudo rm -rf "$HOME/.npm" /home/runner/.npm 2>/dev/null || true
  fi
  if command -v yarn >/dev/null 2>&1; then
    yarn cache clean 2>/dev/null || true
  fi
fi

if [ "$PRUNE_DOCKER" -eq 1 ]; then
  printf "\n>>> Docker prune candidate:\n"
  if command -v docker >/dev/null 2>&1; then
    sudo docker system df || true
    if [ "$ASSUME_YES" -eq 1 ]; then
      printf "\nPruning docker (docker system prune -a --volumes -f)...\n"
      sudo docker system prune -a --volumes -f || true
    else
      printf "\nTo actually prune docker, re-run with --yes\n"
    fi
  else
    printf "  Docker not present\n"
  fi
fi

if [ "$AGGRESSIVE" -eq 1 ]; then
  print_candidate "Aggressive runner/tool caches (dangerous)" "/home/runner/.cache" "/opt/hostedtoolcache" "/home/runner/.nuget" "/usr/share/dotnet"
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf "\nRemoving aggressive caches (this may lengthen future runs)...\n"
    sudo rm -rf /home/runner/.cache /home/runner/.npm /home/runner/.cache/pip /home/runner/.nuget 2>/dev/null || true
    # /opt/hostedtoolcache is commented out by default — uncomment if you truly want it gone:
    # sudo rm -rf /opt/hostedtoolcache || true
  else
    printf "\nTo actually remove aggressive caches, re-run with --yes\n"
  fi
fi

printf "\nFinal df -h for %s:\n" "$PATH_TO_CHECK"
df -h "$PATH_TO_CHECK" || df -h

printf "\n=== END ===\n"
