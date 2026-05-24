# Copyright (c) 2026 Microsoft
# Contributors: Pinaki Ghatak
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

<#
.SYNOPSIS
    Generates Azure DevOps inventory CSV files used by the migration workflow.

.DESCRIPTION
    Runs the gh ado2gh inventory-report command for the target Azure DevOps
    organization, then enriches the generated repos.csv and pipelines.csv files
    with GitHub-specific columns required by the migration and rewiring stages.

    Parameter values are treated as overrides. When a parameter is omitted, the
    script falls back to the corresponding environment variable.

.PARAMETER AdoOrg
    Azure DevOps organization name. Overrides the ADO_ORG environment variable.

.PARAMETER GhOrg
    GitHub organization name. Overrides the GH_ORG environment variable.

.PARAMETER AdoPat
    Azure DevOps personal access token. Also applied to AZURE_DEVOPS_EXT_PAT.

.PARAMETER GithubPat
    GitHub personal access token. Overrides the GH_PAT environment variable.

.PARAMETER GithubBoardsPat
    GitHub token used for Boards integration. Overrides the GH_BoardsPAT environment variable.

.PARAMETER ConfigPath
    Path to the migration configuration file. Defaults to migration-config.json in this script directory.

.EXAMPLE
    .\0_Inventory.ps1

.EXAMPLE
    .\0_Inventory.ps1 -AdoOrg "contoso" -GhOrg "contoso-org" -ConfigPath ".\migration-config.json"
#>
[CmdletBinding()]
param(
    [string]$AdoOrg = "",
    [string]$GhOrg = "",
    [string]$AdoPat = "",
    [string]$GithubPat = "",
    [string]$GithubBoardsPat = ""
)

# Import helper module
$scriptPath = $PSScriptRoot
$ConfigPath = Join-Path $scriptPath 'migration-config.json'
Import-Module (Join-Path $scriptPath 'MigrationHelpers.psm1') -Force -ErrorAction Stop

# Apply parameter overrides only when values are provided.
$environmentOverrides = @(
    @{ ParameterName = 'AdoOrg'; ParameterValue = $AdoOrg; EnvironmentVariableName = 'ADO_ORG' },
    @{ ParameterName = 'GhOrg'; ParameterValue = $GhOrg; EnvironmentVariableName = 'GH_ORG' },
    @{ ParameterName = 'AdoPat'; ParameterValue = $AdoPat; EnvironmentVariableName = 'ADO_PAT' },
    @{ ParameterName = 'AdoPat'; ParameterValue = $AdoPat; EnvironmentVariableName = 'AZURE_DEVOPS_EXT_PAT' },
    @{ ParameterName = 'GithubPat'; ParameterValue = $GithubPat; EnvironmentVariableName = 'GH_PAT' },
    @{ ParameterName = 'GithubBoardsPat'; ParameterValue = $GithubBoardsPat; EnvironmentVariableName = 'GH_BoardsPAT' }
)

foreach ($override in $environmentOverrides) {
    if ([string]::IsNullOrWhiteSpace($override.ParameterValue)) {
        continue
    }

    Set-Item -Path "Env:$($override.EnvironmentVariableName)" -Value $override.ParameterValue
    Write-LogMessage -Message "$($override.EnvironmentVariableName) environment variable set from parameter override" -Level "Info"
}


# 1. Validate PAT tokens
Write-LogMessage -Message "[1/4] Checking existence of PAT tokens..." -Level "Info"
if (!(Test-RequiredPATs -GitHubBoardsRequired $true)) { exit 1 }
Write-LogMessage -Message "GH_ORG environment variable detected: $($env:GH_ORG)" -Level "Info"

# 2. Validate configuration path
Write-LogMessage -Message "[2/4] Validating configuration path..." -Level "Info"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-LogMessage -Message "Configuration file not found: $ConfigPath" -Level "Error"
    exit 1
}

$resolvedAdoOrg = $env:ADO_ORG


# 3. Generate inventory report
Write-LogMessage -Message "[3/4] Generating inventory report..." -Level "Info"
Write-LogMessage -Message "This may take several minutes depending on organization size..." -Level "Info"
gh ado2gh inventory-report --ado-org $resolvedAdoOrg

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
