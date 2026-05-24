#!/usr/bin/env bash
set -euo pipefail

# Trap errors for debugging
trap 'echo "ERROR at line $LINENO: Command failed with exit code $?"' ERR

if [ -z "${ADO_PAT:-}" ]; then
    echo -e "\033[31m[ERROR] ADO_PAT environment variable is not set. Please set your Azure DevOps Personal Access Token.\033[0m"
    exit 1
fi

# Declare arrays for validation results and flags for REST API failures
active_pr_summary=()
running_build_summary=()
running_build_links=()
running_release_summary=()
build_check_failed=false
release_check_failed=false
pr_check_failed=false

# Read CSV file
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
csv_path="$script_dir/repos.csv"
if [ ! -f "$csv_path" ]; then
    echo "CSV file $csv_path not found. Exiting..."
    exit 1
else
    echo -e "\nReading input from file: '$csv_path'"
fi

# Test ADO PAT token with the first organization
test_org=$(tail -n +2 "$csv_path" | head -n 1 | cut -d',' -f1 | sed 's/^"//;s/"$//')
test_uri="https://dev.azure.com/$test_org/_apis/projects?api-version=7.1"

statusCode=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ADO_PAT" -X GET $test_uri)
if [ "$statusCode" -ne 200 ]; then
    echo -e "\033[31m✗ ADO PAT token authentication failed. Please verify your ADO_PAT environment variable is set correctly.\033[0m"
    exit 1
fi


urlencode() {
    jq -rn --arg s "$1" '$s|@uri'
}

# Helper: validate JSON quickly
is_json() {
    jq -e . >/dev/null 2>&1
}

echo -e "\nScanning repositories for active pull requests..."

# Get active pull requests
line_num=0
while IFS= read -r line || [ -n "$line" ]; do
    : $((line_num++))
    
    # Skip header line
    if [ $line_num -eq 1 ]; then
        continue
    fi
    
    # Skip empty lines
    if [ -z "$line" ]; then
        continue
    fi
    
    # Simple extraction: just get first 3 fields (org, teamproject, repo)
    # This avoids complex parsing of quoted fields with commas
    ado_org=$(echo "$line" | cut -d',' -f1 | sed 's/^"//;s/"$//')
    ado_project=$(echo "$line" | cut -d',' -f2 | sed 's/^"//;s/"$//')
    selected_repo_name=$(echo "$line" | cut -d',' -f3 | sed 's/^"//;s/"$//')
    
    # Skip if any required field is empty
    if [ -z "$ado_org" ] || [ -z "$ado_project" ] || [ -z "$selected_repo_name" ]; then
        continue
    fi
		
        enc_ado_org="$(urlencode "$ado_org")"
        enc_ado_project="$(urlencode "$ado_project")"
        enc_selected_repo_name="$(urlencode "$selected_repo_name")"
        
        # Get repository ID
        repo_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/git/repositories/${enc_selected_repo_name}?api-version=7.1"
        repo_response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$repo_uri" 2>&1)
        
        # Extract HTTP status and body
        http_status=$(echo "$repo_response" | grep -oP 'HTTP_STATUS:\K\d+' || echo "000")
        repo_body=$(echo "$repo_response" | sed 's/HTTP_STATUS:[0-9]*$//')
        
        if [ "$http_status" -eq 200 ] && [ -n "$repo_body" ]; then
            # Validate JSON response
            if ! echo "$repo_body" | is_json; then
                pr_check_failed=true
                echo -e "\033[31m[ERROR] Repository API returned non-JSON response for '$selected_repo_name' in project '$ado_project' (HTTP $http_status).\033[0m"
                continue
            fi
            
            repo_id=$(echo "$repo_body" | jq -r '.id // empty' 2>/dev/null)
            repo_name=$(echo "$repo_body" | jq -r '.name // empty' 2>/dev/null)
            
            if [ -n "$repo_id" ] && [ "$repo_id" != "null" ]; then
                # Get active pull requests using repository ID
                pr_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/git/repositories/${repo_id}/pullrequests?searchCriteria.status=active&api-version=7.1"
                pr_response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$pr_uri" 2>&1)
                
                # Extract HTTP status and body
                pr_http_status=$(echo "$pr_response" | grep -oP 'HTTP_STATUS:\K\d+' || echo "000")
                pr_body=$(echo "$pr_response" | sed 's/HTTP_STATUS:[0-9]*$//')
                
                if [ "$pr_http_status" -eq 200 ] && [ -n "$pr_body" ]; then
                    # Validate JSON response
                    if ! echo "$pr_body" | is_json; then
                        pr_check_failed=true
                        echo -e "\033[31m[ERROR] PR API returned non-JSON response for repository '$selected_repo_name' in project '$ado_project' (HTTP $pr_http_status).\033[0m"
                        continue
                    fi
                    
                    # Parse PR response and add to summary
                    pr_count=$(echo "$pr_body" | jq -r '.count // 0' 2>/dev/null)
                    if [ "$pr_count" -gt 0 ]; then
                        # Use process substitution to avoid subshell issue
                        while IFS='|' read -r title status prId; do
                            if [ -n "$title" ] && [ "$title" != "null" ]; then
                                prUrl="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_git/$enc_selected_repo_name/pullrequest/$prId"
                                active_pr_summary+=("$ado_project|$repo_name|$title|$status|$prUrl")
                            fi
                        done < <(echo "$pr_body" | jq -r '.value[]? | "\(.title)|\(.status)|\(.pullRequestId)"' 2>/dev/null)
                    fi
                else
                    pr_check_failed=true
                    echo -e "\033[31m[ERROR] Failed to get PRs for repository '$selected_repo_name' in project '$ado_project' (HTTP $pr_http_status).\033[0m"
                    if [ "$pr_http_status" -ne 200 ] && [ -n "$pr_body" ]; then
                        error_msg=$(echo "$pr_body" | jq -r '.message // .Message // empty' 2>/dev/null)
                        [ -n "$error_msg" ] && echo -e "\033[33m[API Response] $error_msg\033[0m"
                    fi
                fi
            else
                pr_check_failed=true
                echo -e "\033[31m[ERROR] Repository '$selected_repo_name' not found in project '$ado_project'.\033[0m"
                echo -e "\033[33m[INFO] Verify repository name matches exactly (case-sensitive).\033[0m"
            fi
        else
            pr_check_failed=true
            echo -e "\033[31m[ERROR] Failed to lookup repository '$selected_repo_name' in project '$ado_project' (HTTP $http_status).\033[0m"
            if [ "$http_status" -ne 200 ] && [ -n "$repo_body" ]; then
                error_msg=$(echo "$repo_body" | jq -r '.message // .Message // empty' 2>/dev/null)
                [ -n "$error_msg" ] && echo -e "\033[31m[ERROR] API Response: $error_msg\033[0m"
            fi
        fi
done < "$csv_path"

# Get unique projects
unique_projects=()
line_num=0
while IFS= read -r line || [ -n "$line" ]; do
    : $((line_num++))
    
    # Skip header line
    if [ $line_num -eq 1 ]; then
        continue
    fi
    
    # Skip empty lines
    if [ -z "$line" ]; then
        continue
    fi
    
    # Simple extraction: just get first 2 fields
    ado_org=$(echo "$line" | cut -d',' -f1 | sed 's/^"//;s/"$//')
    ado_project=$(echo "$line" | cut -d',' -f2 | sed 's/^"//;s/"$//')
    
    # Skip if empty
    if [ -z "$ado_org" ] || [ -z "$ado_project" ]; then
        continue
    fi
    
    project_combo="$ado_org|$ado_project"
    
    # Check if already exists
    if [[ ! " ${unique_projects[*]} " =~ " ${project_combo} " ]]; then
        unique_projects+=("$project_combo")
    fi
done < "$csv_path"

echo -e "\nScanning projects for active running build and release pipelines..."

for project in "${unique_projects[@]}"; do
    IFS='|' read -r ado_org ado_project <<< "$project"
	
    enc_ado_org="$(urlencode "$ado_org")"
    enc_ado_project="$(urlencode "$ado_project")"
    
    # Check active build pipelines
    builds_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/build/builds?api-version=7.1"
    builds_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$builds_uri" 2>/dev/null) || true
    
    if [ -n "$builds_response" ]; then
        # Validate JSON response
        if ! echo "$builds_response" | is_json; then
            build_check_failed=true
            echo -e "\033[31m[ERROR] Builds API returned non-JSON response for project '$ado_project'.\033[0m"
            continue
        fi
        
        # Parse builds and filter for running/queued ones
        # Build parsing section
        while IFS='|' read -r pipeline_name status runUrl; do
        if [[ -n "$pipeline_name" && "$pipeline_name" != "null" ]]; then
           running_build_summary+=("$ado_project|$pipeline_name|$status")
           running_build_links+=("$runUrl")
       fi
       done < <(echo "$builds_response" | jq -r '.value[]? | select(.status == "inProgress" or .status == "notStarted") | "\(.definition.name)|In Progress/Queued|\(._links.web.href)" ' 2>/dev/null)

    else
        build_check_failed=true
        echo -e "\033[31m[ERROR] Failed to retrieve builds for project '$ado_project'.\033[0m"
    fi
    
    # Check active release pipelines
    releases_uri="https://vsrm.dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/release/releases?api-version=7.1"
    releases_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$releases_uri" 2>/dev/null) || true
    
    if [ -n "$releases_response" ]; then
        # Validate JSON response
        if ! echo "$releases_response" | is_json; then
            release_check_failed=true
            echo -e "\033[31m[ERROR] Releases API returned non-JSON response for project '$ado_project'.\033[0m"
            continue
        fi
        
        # Get release IDs
        while read -r release_id; do
            if [ -n "$release_id" ] && [ "$release_id" != "null" ]; then
                release_details_uri="https://vsrm.dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/release/releases/${release_id}?api-version=7.1"
                release_details=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$release_details_uri" 2>/dev/null) || true
                
                if [ -n "$release_details" ]; then
                    # Validate JSON response
                    if ! echo "$release_details" | is_json; then
                        release_check_failed=true
                        echo -e "\033[31m[ERROR] Release details API returned non-JSON response for release ID $release_id in project '$ado_project'.\033[0m"
                        continue
                    fi
                    
                    # Check if any environments are in progress
                    running_envs=$(echo "$release_details" | jq -r '.environments[]? | select(.status == "inProgress") | "\(.name): \(.status)"' 2>/dev/null)
                    if [ -n "$running_envs" ]; then
                        release_name=$(echo "$release_details" | jq -r '.name // ""' 2>/dev/null)
                        env_statuses=$(echo "$running_envs" | tr '\n' ',' | sed 's/,$//')
                        releaseUrl=$(echo "$release_details" | jq -r '._links.web.href // ""' 2>/dev/null)
                        running_release_summary+=("$ado_project|$release_name|In Progress ($env_statuses)|$releaseUrl")
                    fi
                else
                    release_check_failed=true
                    echo -e "\033[31m[ERROR] Failed to retrieve release ID $release_id.\033[0m"
                fi
            fi
        done < <(echo "$releases_response" | jq -r '.value[]?.id' 2>/dev/null)
    else
        release_check_failed=true
        echo -e "\033[31m[ERROR] Failed to retrieve release list for project '$ado_project'.\033[0m"
    fi
done

# Final Summary
echo -e "\nPre-Migration Validation Summary"
echo "================================"

if [ "$pr_check_failed" != true ]; then
    if [ ${#active_pr_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Active Pull Request(s):\033[0m"
        for entry in "${active_pr_summary[@]}"; do
            IFS='|' read -r project repository title status prUrl <<< "$entry"
            echo "Project: $project | Repository: $repository | Title: $title | Status: $status"
            echo "PR URL: $prUrl"
            echo ""
        done
    else
        echo -e "\n\033[32mPull Request Summary --> No Active Pull Requests\033[0m"
    fi
fi

if [ "$build_check_failed" != true ]; then
    if [ ${#running_build_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Running Build Pipeline(s):\033[0m"

    for idx in "${!running_build_summary[@]}"; do
        IFS='|' read -r project pipeline status <<< "${running_build_summary[$idx]}"
        IFS='|' read -r runUrl <<< "${running_build_links[$idx]}"

        echo "Project: $project | Pipeline: $pipeline | Status: $status"
        echo "Run URL: $runUrl"
        echo ""
    done
    else
        echo -e "\n\033[32mBuild Pipeline Summary --> No Active Running Builds\033[0m"
    fi
fi

if [ "$release_check_failed" != true ]; then
    if [ ${#running_release_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Running Release Pipeline(s):\033[0m"
        for entry in "${running_release_summary[@]}"; do
        IFS='|' read -r project name status releaseUrl <<< "$entry"
        echo "Project: $project | Release Name: $name | Status: $status"
        echo "Release URL: $releaseUrl"
        echo ""
        done
    else
        echo -e "\n\033[32mRelease Pipeline Summary --> No Active Running Releases\033[0m"
    fi
fi


# ---- PowerShell-style final roll-up (4 outcomes) ----
hasActiveItems=false
if [ ${#active_pr_summary[@]} -gt 0 ] || [ ${#running_build_summary[@]} -gt 0 ] || [ ${#running_release_summary[@]} -gt 0 ]; then
    hasActiveItems=true
fi

hasFailures=false
if [ "$pr_check_failed" = true ] || [ "$build_check_failed" = true ] || [ "$release_check_failed" = true ]; then
    hasFailures=true
fi

if [ "$hasFailures" = true ] && [ "$hasActiveItems" = false ]; then
    # Failures only (no active PR/build/release)
    echo -e "\n\033[31mValidation checks could not be completed due to API failures. Please review errors before proceeding.\033[0m\n"
    echo "##[error]Validation checks failed due to API errors"
    echo "##vso[task.logissue type=error]Migration readiness check failed: API errors prevented validation"
    echo "##vso[task.complete result=Failed;]Readiness check completed with API failures"
    exit 1
elif [ "$hasFailures" = true ] && [ "$hasActiveItems" = true ]; then
    # Failures + active items
    echo -e "\n\033[33mActive items detected, but some validation checks failed. Review warnings and errors before proceeding.\033[0m\n"
    echo "##[warning]Active items detected with some validation failures"
    echo "##vso[task.logissue type=warning]Active PRs/pipelines found and some checks failed"
    exit 0  # Allow manual review via approval gate
elif [ "$hasFailures" = false ] && [ "$hasActiveItems" = true ]; then
    # Active items only (no failures)
    echo -e "\n\033[33mActive Pull request or pipelines found. Continue with migration if you have reviewed and are comfortable proceeding.\033[0m\n"
    echo "##[warning]Active pull requests or pipelines detected"
    echo "##vso[task.logissue type=warning]Active PRs/pipelines found - review before proceeding"
    exit 0  # Allow manual review via approval gate
else
    # Clean: no failures, no active items
    echo -e "\n\033[32mNo active pull requests or pipelines detected. You can proceed with migration.\033[0m\n"
    echo "##vso[task.logissue type=warning]Migration readiness check passed - no active items detected"
    exit 0
fi
