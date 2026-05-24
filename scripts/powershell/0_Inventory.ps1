# Copyright (c) 2026 Microsoft
# Contributors: Vamsi Cherukuri, Pinaki Ghatak
# MIT License
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ADO2GH Step 0: Generate Inventory Report
#
# Description:
#   This script generates an inventory report of Azure DevOps repositories at the
#   organization level using the gh ado2gh CLI extension. This report is used to
#   identify repositories for migration planning.
#
# Prerequisites:
#   - ADO_PAT environment variable set with full access scope
#   - migration-config.json exists with proper configuration
#
# Order of operations:
# [1/3] Validate ADO PAT tokens
# [2/3] Load configuration from migration-config.json
#       - Reads adoOrganization from config.scripts.inventory.adoOrg
# [3/3] Generate inventory report using gh ado2gh inventory-report
#       - Creates CSV files in current directory
# [4/4] Add GitHub organization columns to repos.csv
#       - Adds ghorg and ghrepo columns
#
# Usage:
#   .\0_Inventory.ps1
#   .\0_Inventory.ps1 -ConfigPath "custom-config.json"
#
# Output Files:
#   - orgs.csv (list of ADO organizations)
#   - team-projects.csv (list of team projects)
#   - repos.csv (list of repositories - used by subsequent scripts)
#   - pipelines.csv (list of pipelines)

param(
    [string]$AdoOrg = "",  # Optional override
    [string]$AdoPat = "",  # Optional override
    [string]$GithubPat = "",  # Optional override
    [string]$GithubBoardsPat = ""  # Optional override

)

# Import helper module
$scriptPath = $PSScriptRoot

$ConfigPath = "$scriptPath\migration-config.json" 
#$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module "$scriptPath\MigrationHelpers.psm1" -Force -ErrorAction Stop

Write-LogMessage -Message "Starting Inventory Report Generation" -Level "Info"

#1 . Set environment variables for PAT tokens (if provided as parameters)

#Add ADOOrg assingment from parameter if provided
if (-not [string]::IsNullOrWhiteSpace($AdoOrg)) {
    Write-LogMessage -Message "ADO Organization provided as parameter: $AdoOrg" -Level "Info"
}
else {
    Write-LogMessage -Message "No ADO Organization provided as parameter, will read from config file" -Level "Info"
}


if (-not [string]::IsNullOrWhiteSpace($AdoPat)) {
    $env:ADO_PAT = $AdoPat
    [Environment]::SetEnvironmentVariable("ADO_PAT", $AdoPat, "Process")
    Write-LogMessage -Message "ADO_PAT environment variable set from parameter" -Level "Info"

    $env:AZURE_DEVOPS_EXT_PAT = $AdoPat
    [Environment]::SetEnvironmentVariable("AZURE_DEVOPS_EXT_PAT", $AdoPat, "Process")
    Write-LogMessage -Message "AZURE_DEVOPS_EXT_PAT environment variable set from parameter" -Level "Info"
}

if (-not [string]::IsNullOrWhiteSpace($GithubPat)) {
    $env:GH_PAT = $GithubPat
    [Environment]::SetEnvironmentVariable("GH_PAT", $GithubPat, "Process")
    Write-LogMessage -Message "GH_PAT environment variable set from parameter" -Level "Info"
}

if (-not [string]::IsNullOrWhiteSpace($GithubBoardsPat)) {
    $env:GH_BoardsPAT = $GithubBoardsPat
    [Environment]::SetEnvironmentVariable("GH_BoardsPAT", $GithubBoardsPat, "Process")
    Write-LogMessage -Message "GH_BoardsPAT environment variable set from parameter" -Level "Info"
}

# 2. Validate PAT tokens
Write-LogMessage -Message "[1/4] Checking existence of PAT tokens..." -Level "Info"
if (!(Test-RequiredPATs)) { exit 1 }

# 3. Load configuration
Write-LogMessage -Message "[2/4] Loading configuration..." -Level "Info"
$config = Get-MigrationConfig -ConfigPath $ConfigPath
if (!$config) { exit 1 }

if (-not [string]::IsNullOrWhiteSpace($AdoOrg)) {
    Write-LogMessage -Message "ADO Organization provided as parameter: $AdoOrg" -Level "Info"
}
else {
    $AdoOrg = $config.scripts.inventory.adoOrg
    Write-LogMessage -Message "ADO Organization: $AdoOrg" -Level "Info"
}

# 4. Generate inventory report
Write-LogMessage -Message "[3/4] Generating inventory report..." -Level "Info"
Write-LogMessage -Message "This may take several minutes depending on organization size..." -Level "Info"

Write-LogMessage -Message "Logging in to Azure DevOps..." -Level "Info"
$env:AZURE_DEVOPS_EXT_PAT | az devops login --organization https://dev.azure.com/$AdoOrg
gh ado2gh inventory-report --ado-org $AdoOrg

# Check command result
if ($LASTEXITCODE -ne 0) {
    Write-LogMessage -Message "Inventory report generation failed" -Level "Error"
    exit $LASTEXITCODE
}


Write-LogMessage -Message "Inventory report generated successfully!" -Level "Success"

# Add GitHub organization columns to repos.csv and pipelines.csv
Write-LogMessage -Message "[4/4] Adding GitHub organization columns to inventory CSV files..." -Level "Info"

try {
    $repoCsvPath = Join-Path (Get-Location) "repos.csv"
    $pipelinesCsvPath = Join-Path (Get-Location) "pipelines.csv"
    Set-GitHubColumnsToReposCSV -RepoCSVPath $repoCsvPath -OutputPath $repoCsvPath -ConfigPath $ConfigPath
    Set-GitHubColumnsToPipelinesCSV -PipelinesCSVPath $pipelinesCsvPath -OutputPath $pipelinesCsvPath -ConfigPath $ConfigPath
}
catch {
    Write-LogMessage -Message "Failed to add GitHub columns to inventory CSV files: $_" -Level "Error"
    exit 1
}

Write-LogMessage -Message "Inventory Report Complete" -Level "Success"
Write-LogMessage -Message "Output Files:" -Level "Info"
Write-LogMessage -Message "- orgs.csv (ADO organizations)" -Level "Info"
Write-LogMessage -Message "- team-projects.csv (Team projects)" -Level "Info"
Write-LogMessage -Message "- repos.csv (Repositories - used by migration scripts)" -Level "Info"
Write-LogMessage -Message "- pipelines.csv (Pipelines)" -Level "Info"

Write-LogMessage -Message "These files are now uploaded to artifacts in Azure Pipelines" -Level "Success"
