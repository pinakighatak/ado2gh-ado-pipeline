#!/usr/bin/env bash
# Disable ADO repositories after successful migration to GitHub
# Usage: ./6_disable_repo.sh [--csv path/to/disable_repo.csv]

set -o pipefail

CSV_PATH="disable_repo.csv"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      CSV_PATH="$2"; shift 2;;
    *)
      echo "[ERROR] Unknown option: $1"; exit 1;;
  esac
done

# Normalize CRLF if present (Windows-generated CSV)
sed -i 's/\r$//' "${CSV_PATH}" 2>/dev/null || true

# Validate CSV exists
if [[ ! -f "${CSV_PATH}" ]]; then
  echo "[ERROR] CSV file not found: ${CSV_PATH}"
  exit 1
fi

# Count repos (excluding header)
TOTAL_REPOS=$(($(wc -l < "${CSV_PATH}") - 1))
if [[ ${TOTAL_REPOS} -lt 1 ]]; then
  echo "[ERROR] No repositories found in ${CSV_PATH}"
  exit 1
fi

echo "=========================================="
echo "DISABLE ADO REPOSITORIES"
echo "=========================================="
echo "CSV File: ${CSV_PATH}"
echo "Repositories to disable: ${TOTAL_REPOS}"
echo "=========================================="
echo ""

SUCCESS=0
FAILED=0
LINE_NUM=0

while IFS=',' read -r org teamproject repo; do
  ((LINE_NUM++))
  
  # Skip header
  [[ ${LINE_NUM} -eq 1 ]] && continue
  
  # Skip empty lines
  [[ -z "${org}" || -z "${teamproject}" || -z "${repo}" ]] && continue
  
  echo "[INFO] Disabling: ${org}/${teamproject}/${repo}"
  
  if gh ado2gh disable-ado-repo \
    --ado-org "${org}" \
    --ado-team-project "${teamproject}" \
    --ado-repo "${repo}"; then
    echo "[SUCCESS] Disabled: ${repo}"
    ((SUCCESS++))
  else
    echo "[FAILED] Could not disable: ${repo}"
    ((FAILED++))
  fi
  
  echo ""
done < "${CSV_PATH}"

echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total: ${TOTAL_REPOS} | Disabled: ${SUCCESS} | Failed: ${FAILED}"
echo "=========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
