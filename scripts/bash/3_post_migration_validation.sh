#!/usr/bin/env bash
set -euo pipefail

# Log file with timestamp
LOG_FILE="validation-log-$(date +%Y%m%d).txt"

# Track validation results
VALIDATION_FAILURES=0
VALIDATION_SUCCESSES=0

# Write log entry to file and stdout
write_log() {
    local message="$1"
    echo "$message" | tee -a "$LOG_FILE"
}

# Helper: validate JSON quickly
is_json() {
    jq -e . >/dev/null 2>&1
}

urlencode() {
    jq -rn --arg s "$1" '$s|@uri'
}

# Validate migration between ADO and GitHub
validate_migration() {
    local ado_org="$1"
    local ado_team_project="$2"
    local ado_repo="$3"          # repo name (we will resolve to repo_id)
    local github_org="$4"
    local github_repo="$5"
    local has_validation_errors=0

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validating migration: $github_repo"

    # --- GitHub branches ---
    local gh_branches
    gh_branches=$(gh api "/repos/$github_org/$github_repo/branches" --paginate 2>/dev/null) || {
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Failed to fetch GitHub branches for $github_org/$github_repo"
        echo "##[error]Failed to fetch GitHub branches for $github_org/$github_repo"
        VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
        return 1
    }

    if ! echo "$gh_branches" | is_json; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: GitHub branch response is not JSON. Starts: $(echo "$gh_branches" | head -c 120)"
        return 1
    fi

    local gh_branch_array=()
    mapfile -t gh_branch_array < <(echo "$gh_branches" | jq -r '.[].name')

    # --- ADO auth ---
    if [ -z "${ADO_PAT:-}" ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: ADO_PAT environment variable is not set"
        return 1
    fi

    local base64_auth
    base64_auth=$(printf ":%s" "$ADO_PAT" | base64 -w 0 2>/dev/null || printf ":%s" "$ADO_PAT" | base64)

    # --- Encode project; resolve repo ID in that project ---
    local encoded_project
    encoded_project=$(urlencode "$ado_team_project")

    local repo_list_url="https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories?api-version=7.1"
    local repo_list_resp
    repo_list_resp=$(curl -s -H "Authorization: Basic $base64_auth" -H "Accept: application/json" "$repo_list_url")

    if ! echo "$repo_list_resp" | is_json; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: ADO repos list is not JSON. Starts: $(echo "$repo_list_resp" | head -c 120)"
        return 1
    fi

    local repo_id
    repo_id=$(echo "$repo_list_resp" | jq -r --arg name "$ado_repo" '.value[] | select(.name == $name) | .id')
    if [ -z "$repo_id" ] || [ "$repo_id" = "null" ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Repo '$ado_repo' not found in project '$ado_team_project'"
        return 1
    fi

    # --- ADO branches using repo_id (refs?filter=heads) ---
    local ado_branch_url="https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/refs?filter=heads/&api-version=7.1"
    local ado_branch_response
    ado_branch_response=$(curl -s -H "Authorization: Basic $base64_auth" -H "Accept: application/json" "$ado_branch_url")

    if ! echo "$ado_branch_response" | is_json; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: ADO branch response is not JSON. Starts: $(echo "$ado_branch_response" | head -c 120)"
        return 1
    fi

    local error_message
    error_message=$(echo "$ado_branch_response" | jq -r '.message // empty')
    if [ -n "$error_message" ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR from ADO API: $error_message"
        return 1
    fi
    local ado_branch_array=()
    mapfile -t ado_branch_array < <(echo "$ado_branch_response" | jq -r '.value[].name' | sed 's|^refs/heads/||')

    # --- Compare branch counts ---
    local gh_branch_count=${#gh_branch_array[@]}
    local ado_branch_count=${#ado_branch_array[@]}
    local branch_count_status="❌ Not Matching"
    if [ "$gh_branch_count" -eq "$ado_branch_count" ]; then
        branch_count_status="✅ Matching"
    else
        has_validation_errors=1
    fi

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch Count: ADO=$ado_branch_count | GitHub=$gh_branch_count | $branch_count_status"

    # --- Compare branch names ---
    local missing_in_gh=()
    local missing_in_ado=()
    local ado_set=" ${ado_branch_array[*]} "
    local gh_set=" ${gh_branch_array[*]} "

    for ado_branch in "${ado_branch_array[@]}"; do
        [[ "$gh_set" != *" $ado_branch "* ]] && missing_in_gh+=("$ado_branch")
    done
    for gh_branch in "${gh_branch_array[@]}"; do
        [[ "$ado_set" != *" $gh_branch "* ]] && missing_in_ado+=("$gh_branch")
    done

    if [ ${#missing_in_gh[@]} -gt 0 ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branches missing in GitHub: ${missing_in_gh[*]}"
        has_validation_errors=1
    fi
    if [ ${#missing_in_ado[@]} -gt 0 ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branches missing in ADO: ${missing_in_ado[*]}"
        has_validation_errors=1
    fi

    # --- Validate commit counts and latest commit IDs ---
    for branch_name in "${gh_branch_array[@]}"; do
        local exists_in_ado=0
        for ado_branch in "${ado_branch_array[@]}"; do
            if [ "$branch_name" = "$ado_branch" ]; then
                exists_in_ado=1
                break
            fi
        done
        [ $exists_in_ado -eq 0 ] && continue

        # GitHub commits (paginate)
        local gh_commit_count=0
        local gh_latest_sha=""
        local page=1
        local per_page=100

        while true; do
            encodedGhBranchName=$(printf '%s' "$branch_name" | jq -sRr @uri)
            local gh_commits
            gh_commits=$(gh api "/repos/$github_org/$github_repo/commits?sha=$encodedGhBranchName&page=$page&per_page=$per_page" 2>/dev/null) || break
            if ! echo "$gh_commits" | is_json; then
                write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Non-JSON GitHub commits for '$branch_name' (page $page). Starts: $(echo "$gh_commits" | head -c 120)"
                break
            fi

            local commit_batch_count
            commit_batch_count=$(echo "$gh_commits" | jq -r 'length')
            [ -z "$commit_batch_count" ] && commit_batch_count=0

            if [ $page -eq 1 ] && [ "$commit_batch_count" -gt 0 ]; then
                gh_latest_sha=$(echo "$gh_commits" | jq -r '.[0].sha // empty')
            fi
            gh_commit_count=$((gh_commit_count + commit_batch_count))
            page=$((page + 1))
            [ "$commit_batch_count" -lt "$per_page" ] && break
        done

        # ADO commits (paginate via $top/$skip)
        local ado_commit_count=0
        local ado_latest_sha=""
        local skip=0
        local batch_size=1000
        local encoded_branch
        encoded_branch=$(urlencode "$branch_name")

        while true; do
            local ado_url="https://dev.azure.com/$ado_org/$encoded_project/_apis/git/repositories/$repo_id/commits?\$top=$batch_size&\$skip=$skip&searchCriteria.itemVersion.version=$encoded_branch&searchCriteria.itemVersion.versionType=branch&api-version=7.1"
            local ado_response
            ado_response=$(curl -s -H "Authorization: Basic $base64_auth" -H "Accept: application/json" "$ado_url")

            if ! echo "$ado_response" | is_json; then
                write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Non-JSON ADO commits for '$branch_name' (skip=$skip). Starts: $(echo "$ado_response" | head -c 120)"
                break
            fi

            local ado_err
            ado_err=$(echo "$ado_response" | jq -r '.message // empty')
            if [ -n "$ado_err" ]; then
                write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR from ADO API for '$branch_name': $ado_err"
                break
            fi

            local batch_count
            batch_count=$(echo "$ado_response" | jq -r '.value | length')
            [ -z "$batch_count" ] && batch_count=0

            if [ $skip -eq 0 ] && [ "$batch_count" -gt 0 ]; then
                ado_latest_sha=$(echo "$ado_response" | jq -r '.value[0].commitId // empty')
            fi

            ado_commit_count=$((ado_commit_count + batch_count))
            skip=$((skip + batch_size))
            [ "$batch_count" -lt "$batch_size" ] && break
        done

        # Match status
        local commit_count_status="❌ Not Matching"
        local sha_status="❌ Not Matching"
        if [ "$gh_commit_count" -eq "$ado_commit_count" ]; then
            commit_count_status="✅ Matching"
        else
            has_validation_errors=1
        fi
        if [ -n "$gh_latest_sha" ] && [ "$gh_latest_sha" = "$ado_latest_sha" ]; then
            sha_status="✅ Matching"
        else
            has_validation_errors=1
        fi

        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch '$branch_name': ADO Commits=$ado_commit_count | GitHub Commits=$gh_commit_count | $commit_count_status"
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Branch '$branch_name': ADO SHA=$ado_latest_sha | GitHub SHA=$gh_latest_sha | $sha_status"
    done

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Validation complete for $github_repo"
    
    # Return based on validation results
    if [ $has_validation_errors -eq 1 ]; then
        return 1
    else
        return 0
    fi
}

# --- CSV parsing with quoted fields ---
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  # Return: org(0), teamproject(1), repo(2), github_org(3), github_repo(4), visibility(5), status(6)
  echo "${fields[0]}" "${fields[1]}" "${fields[2]}" "${fields[3]}" "${fields[4]}" "${fields[5]}" "${fields[6]}"
}

# --- Batch validation from CSV ---
validate_from_csv() {
    local csv_path="${1:-repos_with_status.csv}"

    if [ ! -f "$csv_path" ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: CSV file not found: $csv_path"
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Make sure Stage 3 (Migration) completed successfully and published repos_with_status.csv"
        return 1
    fi
    
    # Check if any repos succeeded migration
    local success_count
    success_count=$(tail -n +2 "$csv_path" | grep -c ",Success$" || true)
    if [ "$success_count" -eq 0 ]; then
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: No successfully migrated repositories found in $csv_path"
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] All repositories failed migration. Skipping validation."
        echo "##[warning]No successfully migrated repositories to validate - skipping validation stage"
        echo "Skipping validation as all repositories failed migration"
        exit 0
    fi
    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Found $success_count successfully migrated repositories to validate"

    # Use process substitution to avoid subshell issue with while loop
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        read -r org teamproject repo github_org github_repo gh_repo_visibility migration_status < <(parse_csv_line "$line")
        
        # Skip repositories that failed migration
        if [ "$migration_status" != "Success" ]; then
            write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ⏭️  Skipping $repo (Migration Status: $migration_status)"
            continue
        fi
        
        write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Processing: $repo -> $github_repo"
        
        if validate_migration "$org" "$teamproject" "$repo" "$github_org" "$github_repo"; then
            VALIDATION_SUCCESSES=$((VALIDATION_SUCCESSES + 1))
            write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ✅ Validation succeeded: $github_repo"
        else
            VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
            write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ❌ Validation failed: $github_repo"
        fi
    done < <(tail -n +2 "$csv_path")

    write_log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] All validations from CSV completed"
}

# Execute batch validation
validate_from_csv "repos_with_status.csv"

# Report validation summary
if [ $VALIDATION_FAILURES -gt 0 ]; then
    echo "##[warning]Post-migration validation completed with $VALIDATION_FAILURES failures"
    echo "##vso[task.logissue type=warning]Validation failed: $VALIDATION_FAILURES repositories had validation errors"
    
    # Add partial success indicator when there are both successes and failures
    if [ $VALIDATION_SUCCESSES -gt 0 ]; then
        echo "##[warning]⚠️ Stage completed with PARTIAL SUCCESS: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"
    fi
fi

echo "##vso[task.logissue type=warning]Post-migration validation completed: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"

# --- Exit with appropriate status ---
# Fail if no repositories were processed at all

if [ $VALIDATION_SUCCESSES -eq 0 ] && [ $VALIDATION_FAILURES -eq 0 ]; then
    echo "##[error]❌ No repositories were validated - all migrations may have failed"
    echo "##vso[task.logissue type=error]Validation failed: No repositories to validate"
    exit 1
fi

# --- Handle validation results ---

if [ $VALIDATION_FAILURES -eq 0 ]; then
    # All successful
    echo "##[section]✅ All $VALIDATION_SUCCESSES repositories validated successfully"
    exit 0
    
elif [ $VALIDATION_SUCCESSES -eq 0 ]; then
    # All failed validation - but continue pipeline anyway
    echo "##[warning]⚠️ All $VALIDATION_FAILURES repositories failed validation"
    echo "##vso[task.logissue type=warning]Validation failed: All repositories had validation errors, but continuing pipeline"
    echo "##vso[task.complete result=SucceededWithIssues]All validations failed but continuing pipeline"
    exit 0
    
else
    # Partial success - some succeeded, some failed
    echo "##[warning]⚠️ Validation completed with PARTIAL SUCCESS: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"
    echo "##vso[task.logissue type=warning]Partial success: $VALIDATION_SUCCESSES succeeded, $VALIDATION_FAILURES failed"
    
    # Set task result to SucceededWithIssues and exit successfully
    echo "##vso[task.complete result=SucceededWithIssues]Validation completed with partial success"
    exit 0
fi