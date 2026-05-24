# Copyright (c) 2026 Microsoft
# Contributors: Vamsi Cherukuri, Pinaki Ghatak
# 
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

# ADO2GH Migration Helper Functions
# 
# This module contains shared helper functions used across all migration scripts
# to eliminate code duplication and provide consistent behavior.
#
# Usage: Import-Module "$scriptPath\MigrationHelpers.psm1" -Force

# ========================================
# PAT Token(s) Validation
# ========================================

<#
.SYNOPSIS
    Writes standardized log output for local execution and Azure Pipelines.

.DESCRIPTION
    Centralizes logging behavior used by the migration scripts. When running inside
    Azure Pipelines, warning and error messages are also emitted using Azure DevOps
    logging commands so they are surfaced correctly in pipeline logs.

.PARAMETER Message
    The message text to write.

.PARAMETER Level
    The severity for the message. Defaults to Info.

.EXAMPLE
    Write-LogMessage -Message "Configuration loaded successfully" -Level Success

.EXAMPLE
    Write-LogMessage -Message "GH_PAT environment variable not set" -Level Error
#>
function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $isAzurePipeline = $env:TF_BUILD -eq 'True'

    switch ($Level) {
        'Warning' {
            if ($isAzurePipeline) {
                Write-Host "##vso[task.logissue type=warning]$Message"
                Write-Output "WARNING: $Message"
            }
            else {
                Write-Warning $Message
            }
        }
        'Error' {
            if ($isAzurePipeline) {
                Write-Host "##vso[task.logissue type=error]$Message"
                Write-Output "ERROR: $Message"
            }
            else {
                Write-Error $Message -ErrorAction Continue
            }
        }
        'Success' {
            Write-Output "SUCCESS: $Message"
        }
        default {
            Write-Output $Message
        }
    }
}

<#
.SYNOPSIS
    Validates required Personal Access Tokens (PATs) are set in environment variables.

.DESCRIPTION
    Checks if ADO_PAT and/or GH_PAT, and GH_BoardsPAT environment variables are set based on requirements.
    Used by all scripts to ensure authentication tokens are available before proceeding.

.PARAMETER ADORequired
    Whether Azure DevOps PAT is required. Default is $true.

.PARAMETER GitHubRequired
    Whether GitHub PAT is required. Default is $true.

.PARAMETER GitHubBoardsRequired
    Whether GitHub Boards PAT is required. Default is $false.

.EXAMPLE
    if (!(Test-RequiredPATs)) { exit 1 }

.EXAMPLE
    if (!(Test-RequiredPATs -ADORequired $false -GitHubBoardsRequired $true)) { exit 1 }
#>
function Test-RequiredPATs {
    [CmdletBinding()]
    param(
        [bool]$ADORequired = $true,
        [bool]$GitHubRequired = $true,
        [bool]$GitHubBoardsRequired = $true
    )
    
    $allValid = $true
    
    if ($ADORequired -and !$env:ADO_PAT) {
        Write-LogMessage -Message "ADO_PAT environment variable not set" -Level "Error"
        Write-LogMessage -Message "Please set your Azure DevOps PAT" -Level "Warning"
        $allValid = $false
    }
    
    if ($GitHubRequired -and !$env:GH_PAT) {
        Write-LogMessage -Message "GH_PAT environment variable not set" -Level "Error"
        Write-LogMessage -Message "Please set your GitHub PAT" -Level "Warning"
        $allValid = $false
    }
    
    if ($GitHubBoardsRequired -and !$env:GH_BoardsPAT) {
        Write-LogMessage -Message "GH_BoardsPAT environment variable not set" -Level "Error"
        Write-LogMessage -Message "Please set your GitHub Boards PAT as documented in README" -Level "Warning"
        $allValid = $false
    }
    if ($allValid) {
        Write-LogMessage -Message "PAT tokens set successfully" -Level "Success"
    }
    
    return $allValid
}

# ========================================
# GitHub Columns Augmentation
# ========================================

<#
.SYNOPSIS
    Adds GitHub organization and repository columns to repos.csv

.DESCRIPTION
    Reads the repos.csv file and adds two new columns:
    - ghorg: The GitHub organization from the GH_ORG environment variable
    - ghrepo: The repository name (same as the repo column value)
    Provides fallback path resolution if files are not found in the script directory.

.PARAMETER RepoCSVPath
    Path to the repos.csv file. Defaults to repos.csv in the scripts directory.

.PARAMETER ConfigPath
    Path to the migration-config.json file. Defaults to migration-config.json in the scripts directory.

.PARAMETER OutputPath
    Path where the modified CSV will be saved. If not specified, overwrites the original file.

.EXAMPLE
    Add-GitHubColumnsToReposCSV

.EXAMPLE
    Set-GitHubColumnsToReposCSV -RepoCSVPath ".\repos.csv" -ConfigPath ".\migration-config.json"
#>
function Set-GitHubColumnsToReposCSV {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepoCSVPath = (Join-Path $PSScriptRoot "repos.csv"),

        [Parameter()]
        [string]$ConfigPath = (Join-Path $PSScriptRoot "migration-config.json"),

        [Parameter()]
        [string]$OutputPath = $null
    )

    try {
        # Check if files exist (with fallback to current working directory)
        if (-not (Test-Path $RepoCSVPath)) {
            $altRepo = Join-Path (Get-Location) (Split-Path $RepoCSVPath -Leaf)
            if (Test-Path $altRepo) {
                Write-LogMessage -Message "repos.csv not found at default; using $altRepo" -Level "Error"
                $RepoCSVPath = $altRepo
            }
            else {
                throw "repos.csv file not found at: $RepoCSVPath or $altRepo"
            }
        }

        if (-not (Test-Path $ConfigPath)) {
            $altConfig = Join-Path (Get-Location) (Split-Path $ConfigPath -Leaf)
            if (Test-Path $altConfig) {
                Write-LogMessage -Message "migration-config.json not found at default; using $altConfig" -Level "Warning"
                $ConfigPath = $altConfig
            }
            else {
                throw "migration-config.json file not found at: $ConfigPath or $altConfig"
            }
        }

        # Read the GitHub organization from the environment
        Write-LogMessage -Message "Reading GH_ORG from environment..." -Level "Info"
        $githubOrg = $env:GH_ORG

        if ([string]::IsNullOrWhiteSpace($githubOrg)) {
            throw "GH_ORG environment variable not set"
        }

        Write-LogMessage -Message "GitHub Organization: $githubOrg" -Level "Info"

        # Read the repos CSV
        $repos = @(Import-Csv -Path $RepoCSVPath)

        if ($repos.Count -eq 0) {
            throw "No repositories found in repos.csv"
        }

        Write-LogMessage -Message "Processing $($repos.Count) repositories..." -Level "Info"

        # Build the output rows directly to avoid repeated object mutation.
        $outputRepos = foreach ($repo in $repos) {
            [pscustomobject]@{
                org                = $repo.org
                teamproject        = $repo.teamproject
                repo               = $repo.repo
                github_org         = $githubOrg
                github_repo        = $repo.repo
                gh_repo_visibility = 'private'
            }
        }

        # Determine output path
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = $RepoCSVPath
        }

        # Export the updated CSV
        $outputRepos | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-LogMessage -Message "Output written to: $OutputPath" -Level "Info"
        Write-LogMessage -Message "Restructured columns to repos.csv" -Level Success
        return $outputRepos
    }
    catch {
        Write-LogMessage -Message "Failed to update repos.csv: $_" -Level "Error"
        throw
    }
}

# ========================================
# GitHub Columns Augmentation For Pipelines
# ========================================

<#
.SYNOPSIS
    Adds GitHub organization and repository columns to pipelines.csv

.DESCRIPTION
    Reads the pipelines.csv file and ensures it contains the pipeline migration columns:
    - serviceConnection: Existing Azure DevOps service connection identifier
    - ghorg: The GitHub organization from the GH_ORG environment variable
    - ghrepo: The repository name (same as the repo column value)
    Provides fallback path resolution if files are not found in the script directory.

.PARAMETER PipelinesCSVPath
    Path to the pipelines.csv file. Defaults to pipelines.csv in the scripts directory.

.PARAMETER ConfigPath
    Path to the migration-config.json file. Defaults to migration-config.json in the scripts directory.

.PARAMETER OutputPath
    Path where the modified CSV will be saved. If not specified, overwrites the original file.

.EXAMPLE
    Set-GitHubColumnsToPipelinesCSV

.EXAMPLE
    Set-GitHubColumnsToPipelinesCSV -PipelinesCSVPath ".\pipelines.csv" -ConfigPath ".\migration-config.json"
#>
function Set-GitHubColumnsToPipelinesCSV {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PipelinesCSVPath = (Join-Path $PSScriptRoot "pipelines.csv"),

        [Parameter()]
        [string]$ConfigPath = (Join-Path $PSScriptRoot "migration-config.json"),

        [Parameter()]
        [string]$OutputPath = $null
    )

    try {
        if (-not (Test-Path $PipelinesCSVPath)) {
            $altPipelines = Join-Path (Get-Location) (Split-Path $PipelinesCSVPath -Leaf)
            if (Test-Path $altPipelines) {
                Write-LogMessage -Message "pipelines.csv not found at default; using $altPipelines" -Level "Warning"
                $PipelinesCSVPath = $altPipelines
            }
            else {
                throw "pipelines.csv file not found at: $PipelinesCSVPath or $altPipelines"
            }
        }

        if (-not (Test-Path $ConfigPath)) {
            $altConfig = Join-Path (Get-Location) (Split-Path $ConfigPath -Leaf)
            if (Test-Path $altConfig) {
                Write-LogMessage -Message "migration-config.json not found at default; using $altConfig" -Level "Warning"
                $ConfigPath = $altConfig
            }
            else {
                throw "migration-config.json file not found at: $ConfigPath or $altConfig"
            }
        }

        Write-LogMessage -Message "Reading GH_ORG from environment..." -Level "Info"
        $githubOrg = $env:GH_ORG

        if ([string]::IsNullOrWhiteSpace($githubOrg)) {
            throw "GH_ORG environment variable not set"
        }

        Write-LogMessage -Message "GitHub Organization: $githubOrg" -Level "Info"
        Write-LogMessage -Message "Pipelines CSV Path: $PipelinesCSVPath" -Level "Info"
        $pipelines = @(Import-Csv -Path $PipelinesCSVPath)

        # Check for at least one row in pipelines.csv

        if ($pipelines.Count -eq 0) {
            Write-LogMessage -Message "No pipelines found in pipelines.csv" -Level "Warning"
            return @()
        }
        else {
            Write-LogMessage -Message "Found $($pipelines.Count) pipelines in pipelines.csv" -Level "Info"
            Write-LogMessage -Message "Processing $($pipelines.Count) pipelines..." -Level "Info"
            $outputPipelines = foreach ($pipeline in $pipelines) {
                [pscustomobject]@{
                    org               = $pipeline.org
                    teamproject       = $pipeline.teamproject
                    repo              = $pipeline.repo
                    pipeline          = $pipeline.pipeline
                    url               = $pipeline.url
                    serviceConnection = $pipeline.serviceConnection
                    github_org        = $githubOrg
                    github_repo       = $pipeline.repo
                }
            }
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = $PipelinesCSVPath
            }
            $outputPipelines | Export-Csv -Path $OutputPath -NoTypeInformation -Force
            Write-LogMessage -Message "Output written to: $OutputPath" -Level "Info"
            Write-LogMessage -Message "If you need different GitHub repository names, edit the 'ghrepo' column in $OutputPath before proceeding with pipeline rewiring." -Level "Info"
            return $outputPipelines
        }
    }
    catch {
        Write-LogMessage -Message "Failed to update pipelines.csv: $_" -Level "Error"
    }
}


# ========================================
# Module Exports
# ========================================
Export-ModuleMember -Function *
