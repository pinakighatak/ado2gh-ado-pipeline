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
# 1. PAT Token(s) Validation
# ========================================

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
    Whether GitHub Boards PAT is required. Default is $true.

.EXAMPLE
    if (!(Test-RequiredPATs)) { exit 1 }

.EXAMPLE
    if (!(Test-RequiredPATs -ADORequired $false)) { exit 1 }  # Only GitHub PAT needed
#>
function Test-RequiredPATs {
    param(
        [bool]$ADORequired = $true,
        [bool]$GitHubRequired = $true
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
# 2. Configuration File Loading
# ========================================

<#
.SYNOPSIS
    Loads and parses the migration configuration JSON file.

.DESCRIPTION
    Reads the migration-config.json file, parses it, and returns the configuration object.
    Provides consistent error handling and messaging across all scripts.

.PARAMETER ConfigPath
    Path to the configuration JSON file. Default is "migration-config.json".

.EXAMPLE
    $config = Get-MigrationConfig -ConfigPath $ConfigPath
    if (!$config) { exit 1 }

.EXAMPLE
    $config = Get-MigrationConfig
    $adoOrg = $config.adoOrganization
#>
function Get-MigrationConfig {
    param(
        [string]$ConfigPath = "migration-config.json"
    )
    
    if (-not (Test-Path $ConfigPath)) {
        Write-LogMessage -Message "Configuration file not found: $ConfigPath" -Level "Error"
        return $null
    }
    
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        Write-LogMessage -Message "Configuration loaded successfully" -Level "Success"
        return $config
    }
    catch {
        Write-LogMessage -Message "Failed to load configuration: $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

# ========================================
# 3. State File Discovery
# ========================================

<#
.SYNOPSIS
    Finds the most recent migration state file or validates a specified file.

.DESCRIPTION
    Auto-discovers the latest migration state file when not specified or when set to "auto".
    Provides consistent state file handling across validation, rewiring, and disable scripts.

.PARAMETER StateFile
    Path to a specific state file, or "auto" to discover latest, or empty to discover.

.PARAMETER Pattern
    File pattern to search for. Default is "migration-state-*.json".

.EXAMPLE
    $StateFile = Get-LatestStateFile -StateFile $StateFile
    if (!$StateFile) { exit 1 }

.EXAMPLE
    $StateFile = Get-LatestStateFile -StateFile "" -Pattern "migration-state-comprehensive-*.json"
#>
function Get-LatestStateFile {
    param(
        [string]$StateFile = "",
        [string]$Pattern = "migration-state-*.json"
    )
    
    # If a specific file is provided and it's not "auto", validate and return it
    if (![string]::IsNullOrEmpty($StateFile) -and $StateFile -ne "auto") {
        if (Test-Path $StateFile) {
            return $StateFile
        }
        else {
            Write-LogMessage -Message "Specified state file not found: $StateFile" -Level "Error"
            return $null
        }
    }
    
    # Auto-discover the most recent state file
    $stateFiles = Get-ChildItem -Path "." -Filter $Pattern -ErrorAction SilentlyContinue | 
    Sort-Object LastWriteTime -Descending
    
    if ($stateFiles.Count -eq 0) {
        Write-LogMessage -Message "No migration state files found matching pattern: $Pattern" -Level "Error"
        Write-LogMessage -Message "Please run 2_migrate_repo.ps1 first or specify -StateFile parameter" -Level "Warning"
        return $null
    }
    
    $discoveredFile = $stateFiles[0].Name
    Write-LogMessage -Message "Auto-discovered state file: $discoveredFile" -Level "Info"
    
    return $discoveredFile
}

# ========================================
# 4. Service Connection Queries
# ========================================

<#
.SYNOPSIS
    Queries Azure DevOps service connections (endpoints) for a project.

.DESCRIPTION
    Retrieves GitHub/GitHub Enterprise service connections from an ADO project.
    Provides consistent service connection querying for pipeline rewiring and boards integration.

.PARAMETER AdoOrg
    Azure DevOps organization name.

.PARAMETER ProjectName
    Azure DevOps project name.

.PARAMETER ConnectionTypes
    Array of connection types to filter. Default is @('github', 'githubenterprise').

.EXAMPLE
    $connections = Get-ProjectServiceConnections -AdoOrg $ADO_ORG -ProjectName $projectName
    if ($connections -and $connections.Count -gt 0) { ... }

.EXAMPLE
    $connections = Get-ProjectServiceConnections -AdoOrg $org -ProjectName $proj -ConnectionTypes @('github')
#>
function Get-ProjectServiceConnections {
    param(
        [Parameter(Mandatory)]
        [string]$AdoOrg,
        
        [Parameter(Mandatory)]
        [string]$ProjectName,
        
        [string[]]$ConnectionTypes = @('github', 'githubenterprise')
    )
    
    try {
        # Build the type filter for the query
        $typeFilter = ($ConnectionTypes | ForEach-Object { "type=='$_'" }) -join ' || '
        
        $connections = az devops service-endpoint list `
            --org "https://dev.azure.com/$AdoOrg" `
            --project "$ProjectName" `
            --query "[?$($typeFilter)].{name:name, id:id, type:type, isReady:isReady, url:url}" `
            -o json 2>$null | ConvertFrom-Json
        
        return $connections
    }
    catch {
        Write-LogMessage -Message "Failed to query service connections for project '$ProjectName': $($_.Exception.Message)" -Level "Error"
        return $null
    }
}

# ========================================
# 5. Repository Mapping
# ========================================

<#
.SYNOPSIS
    Creates a standardized repository mapping from ADO to GitHub.

.DESCRIPTION
    Builds a hashtable mapping ADO repositories to GitHub repositories using a consistent structure.
    Key format: "TeamProject|RepositoryName"

.PARAMETER Repositories
    Array of repository objects with ADO and GitHub properties.

.EXAMPLE
    $mapping = New-RepositoryMapping -Repositories $REPOSITORIES
    $githubRepo = $mapping["MyProject|MyRepo"].GitHubRepo

.EXAMPLE
    $mapping = New-RepositoryMapping -Repositories $migrationState.MigratedRepositories
    foreach ($key in $mapping.Keys) {
        Write-Host "$key -> $($mapping[$key].GitHubRepo)"
    }
#>
function New-RepositoryMapping {
    param(
        [Parameter(Mandatory)]
        [object[]]$Repositories
    )
    
    $mapping = @{}
    
    foreach ($repo in $Repositories) {
        $key = "$($repo.AdoTeamProject)|$($repo.AdoRepository)"
        
        $mapping[$key] = @{
            AdoOrganization    = $repo.AdoOrganization
            AdoTeamProject     = $repo.AdoTeamProject
            AdoRepository      = $repo.AdoRepository
            GitHubOrganization = $repo.GitHubOrganization
            GitHubRepository   = $repo.GitHubRepository
        }
    }
    
    return $mapping
}

# ========================================
# 6. GitHub Columns Augmentation
# ========================================

<#
.SYNOPSIS
    Adds GitHub organization and repository columns to repos.csv

.DESCRIPTION
    Reads the repos.csv file and adds two new columns:
    - ghorg: The GitHub organization from migration-config.json
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

        # Read the migration config to get GitHub organization
        Write-LogMessage -Message "Reading migration configuration..." -Level "Info"
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $githubOrg = $config.githubOrganization

        if ([string]::IsNullOrWhiteSpace($githubOrg)) {
            throw "GitHub organization not found in migration-config.json"
        }

        Write-LogMessage -Message "GitHub Organization: $githubOrg" -Level "Info"

        # Read the repos CSV
        $repos = Import-Csv -Path $RepoCSVPath

        if ($repos.Count -eq 0) {
            throw "No repositories found in repos.csv"
        }

        Write-LogMessage -Message "Processing $($repos.Count) repositories..." -Level "Info"

        # Add the new columns
        $updatedRepos = $repos | ForEach-Object {
            $_ | Add-Member -MemberType NoteProperty -Name "ghorg" -Value $githubOrg -Force
            $_ | Add-Member -MemberType NoteProperty -Name "ghrepo" -Value $_.repo -Force
            $_ | Add-Member -MemberType NoteProperty -Name "ghrepo_visibility" -Value "private" -Force
            $_
        }

        # Determine output path
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = $RepoCSVPath
        }

        # Keep only the migration columns in the saved CSV.
        $outputRepos = $updatedRepos | Select-Object -Property org, teamproject, repo, ghorg, ghrepo, ghrepo_visibility

        # Export the updated CSV
        $outputRepos | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-LogMessage -Message "Output written to: $OutputPath" -Level "Info"
        Write-LogMessage -Message "Added ghorg, ghrepo, and ghrepo_visibility columns to repos.csv" -Level Success
        Write-LogMessage -Message "Default mapping applied:"
        Write-LogMessage -Message "ghorg: $githubOrg (from migration-config.json)"
        Write-LogMessage -Message "ghrepo: Same as ADO repository name"
        Write-LogMessage -Message "If you need different GitHub repository names, edit the 'ghrepo' column in $OutputPath before proceeding with the migration." -Level Info
        return $outputRepos
    }
    catch {
        Write-LogMessage -Message "Failed to update repos.csv: $_" -Level Error
        throw
    }
}

# ========================================
# 7. GitHub Columns Augmentation For Pipelines
# ========================================

<#
.SYNOPSIS
    Adds GitHub organization and repository columns to pipelines.csv

.DESCRIPTION
    Reads the pipelines.csv file and ensures it contains the pipeline migration columns:
    - serviceConnection: Existing Azure DevOps service connection identifier
    - ghorg: The GitHub organization from migration-config.json
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
                Write-Host "   pipelines.csv not found at default; using $altPipelines" -ForegroundColor DarkYellow
                $PipelinesCSVPath = $altPipelines
            }
            else {
                throw "pipelines.csv file not found at: $PipelinesCSVPath or $altPipelines"
            }
        }

        if (-not (Test-Path $ConfigPath)) {
            $altConfig = Join-Path (Get-Location) (Split-Path $ConfigPath -Leaf)
            if (Test-Path $altConfig) {
                Write-Host "   migration-config.json not found at default; using $altConfig" -ForegroundColor DarkYellow
                $ConfigPath = $altConfig
            }
            else {
                throw "migration-config.json file not found at: $ConfigPath or $altConfig"
            }
        }

        Write-Host "   Reading migration configuration..." -ForegroundColor Gray
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $githubOrg = $config.githubOrganization

        if ([string]::IsNullOrWhiteSpace($githubOrg)) {
            throw "GitHub organization not found in migration-config.json"
        }

        Write-Host "   GitHub Organization: $githubOrg" -ForegroundColor Gray
        Write-Host "   Pipelines CSV Path: $PipelinesCSVPath" -ForegroundColor Gray
        $pipelines = Import-Csv -Path $PipelinesCSVPath

        if ($pipelines.Count -eq 0) {
            throw "No pipelines found in pipelines.csv"
        }

        Write-Host "   Processing $($pipelines.Count) pipelines..." -ForegroundColor Gray

        $updatedPipelines = $pipelines | ForEach-Object {
            $_ | Add-Member -MemberType NoteProperty -Name "serviceConnection" -Value $_.serviceConnection -Force
            $_ | Add-Member -MemberType NoteProperty -Name "ghorg" -Value $githubOrg -Force
            $_ | Add-Member -MemberType NoteProperty -Name "ghrepo" -Value $_.repo -Force
            $_
        }

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = $PipelinesCSVPath
        }

        $outputPipelines = $updatedPipelines | Select-Object -Property org, teamproject, repo, pipeline, serviceConnection, ghorg, ghrepo

        $outputPipelines | Export-Csv -Path $OutputPath -NoTypeInformation -Force
        Write-LogMessage -Message "Output written to: $OutputPath"
        Write-LogMessage -Message "Added serviceConnection, ghorg, and ghrepo columns to pipelines.csv" -Level Success
        Write-LogMessage -Message "ghorg: $githubOrg (from migration-config.json)"
        Write-LogMessage -Message "ghrepo: Same as ADO repository name"
        Write-LogMessage -Message "If you need different GitHub repository names, edit the 'ghrepo' column in $OutputPath before proceeding with pipeline rewiring." -Level Info
        return $outputPipelines
    }
    catch {
        Write-LogMessage -Message "Failed to update pipelines.csv: $_" -Level Error
        throw
    }
}

# ========================================
# 8. Environment Variable Swap
# ========================================

<#
.SYNOPSIS
    Swaps two string values and assigns them to GH_PAT and GH_BoardsPAT environment variables.

.DESCRIPTION
    Takes two string variables, swaps their values, and assigns them to the environment variables
    GH_PAT and GH_BoardsPAT. Displays the swapped values on the console.

.PARAMETER FirstValue
    The first string value to swap.

.PARAMETER SecondValue
    The second string value to swap.

.EXAMPLE
    Set-EnvVarsSwap -FirstValue "token1" -SecondValue "token2"
    # Assigns token2 to GH_PAT and token1 to GH_BoardsPAT
#>
function Set-EnvVarsSwap {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FirstValue,

        [Parameter(Mandatory = $true)]
        [string]$SecondValue
    )

    try {
        # Swap the values
        $temp = $FirstValue
        $FirstValue = $SecondValue
        $SecondValue = $temp

        # Validate string lengths
        if ($FirstValue.Length -ne 40 -or $SecondValue.Length -ne 40) {
            throw "Environment variable values must be exactly 40 characters"
        }

        # Assign to environment variables both ways
        $env:GH_PAT = $FirstValue
        $env:GH_BoardsPAT = $SecondValue
        [Environment]::SetEnvironmentVariable('GH_PAT', $FirstValue, 'Process')
        [Environment]::SetEnvironmentVariable('GH_BoardsPAT', $SecondValue, 'Process')

        # Verify the values were set correctly
        if ($env:GH_PAT.Length -ne 40 -or $env:GH_BoardsPAT.Length -ne 40) {
            throw "Failed to set environment variables with correct lengths (40 characters required)"
        }
    }
    catch {
        Write-Host "❌ Failed to swap environment variables: $_" -ForegroundColor Red
        throw
    }
}


# ========================================
# Module Exports
# ========================================

Export-ModuleMember -Function @(
    'Write-LogMessage',    
    'Test-RequiredPATs',
    'Get-MigrationConfig',
    'Get-LatestStateFile',
    'Get-ProjectServiceConnections',
    'New-RepositoryMapping',
    'Set-GitHubColumnsToReposCSV',
    'Set-GitHubColumnsToPipelinesCSV',
    'Set-EnvVarsSwap'
)
