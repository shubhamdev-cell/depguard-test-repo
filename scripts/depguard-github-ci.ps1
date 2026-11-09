param(
    [string]$ProjectId = "889fcfba-f91d-44ca-aa93-21e958de0cb6",
    [string]$ApiBase = "http://localhost:3001/api",
    [ValidateRange(0, 100)]
    [int]$MaxRiskScore = 70,
    [ValidateRange(0, 10000)]
    [int]$MaxCriticalIssues = 0,
    [ValidateRange(0, 10000)]
    [int]$MaxHighIssues = 5,
    [switch]$DryRun,
    [string]$SourcePath = ""
)

$ErrorActionPreference = "Stop"

$root = if ([string]::IsNullOrWhiteSpace($SourcePath)) { (Resolve-Path (Join-Path $PSScriptRoot "..")).Path } else { (Resolve-Path $SourcePath).Path }
$tempZip = Join-Path $env:TEMP "depguard-local-ci.zip"
$reportDirectory = Join-Path $root "reports"

$excludedDirs = @(
    "node_modules", ".git", ".next", ".nuxt",
    "dist", "build", "coverage", ".turbo", "reports",
    ".venv", "venv", "__pycache__", ".idea",
    ".cache", "vendor", "target"
)

function Test-ExcludedFile {
    param([string]$RelativePath)

    $parts = $RelativePath -split "[/\\]"

    foreach ($part in $parts) {
        if ($excludedDirs -contains $part) { return $true }

        if ($part -match '(?i)backup') { return $true }

        if ($part -match '^\.env' -and $part -ne '.env.example') {
            return $true
        }
    }

    if ($RelativePath -match '(?i)\.(zip|sql|log)$') {
        return $true
    }

    return $false
}

Write-Host "`n===== DEPGUARD LOCAL CI =====" -ForegroundColor Cyan
Write-Host "Project: $ProjectId"

if (Test-Path $tempZip) {
    Remove-Item $tempZip -Force
}

$files = Get-ChildItem $root -Recurse -File -Force |
    Where-Object {
        !$_.Attributes.ToString().Contains("ReparsePoint")
    }

$selectedFiles = @()

foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\','/')
    $relative = $relative.Replace('\','/')

    if (!(Test-ExcludedFile $relative)) {
        $selectedFiles += [PSCustomObject]@{
            File = $file
            Relative = $relative
        }
    }
}

if ($selectedFiles.Count -eq 0) {
    throw "No eligible project files found."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$archive = [System.IO.Compression.ZipFile]::Open(
    $tempZip,
    [System.IO.Compression.ZipArchiveMode]::Create
)

try {
    foreach ($item in $selectedFiles) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $item.File.FullName,
            $item.Relative,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

$zipSize = (Get-Item $tempZip).Length

Write-Host "`n===== PACKAGE SUMMARY =====" -ForegroundColor Green
Write-Host "Files included: $($selectedFiles.Count)"
Write-Host "ZIP size: $([math]::Round($zipSize / 1MB, 2)) MB"
Write-Host "ZIP path: $tempZip"

if ($zipSize -gt 25MB) {
    throw "ZIP exceeds the CI API 25 MB upload limit."
}

if ($DryRun) {
    Write-Host "`nDRY RUN PASSED. No API request was sent." -ForegroundColor Green
    return
}

$token = $env:DEPGUARD_CI_TOKEN

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Set DEPGUARD_CI_TOKEN environment variable before running without DryRun."
}

$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)

try {
    $client.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue(
            "Bearer", $token
        )

    $multipart = New-Object System.Net.Http.MultipartFormDataContent
    $stream = [System.IO.File]::OpenRead($tempZip)
    $fileContent = New-Object System.Net.Http.StreamContent($stream)
    $fileContent.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/zip")

    $multipart.Add($fileContent, "file", "depguard-project.zip")

    $scanUrl = "$ApiBase/ci/projects/$ProjectId/scan"

    Write-Host "`nUploading ZIP to DepGuard..." -ForegroundColor Cyan

    $uploadResponse = $client.PostAsync($scanUrl, $multipart).GetAwaiter().GetResult()
    $uploadBody = $uploadResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (!$uploadResponse.IsSuccessStatusCode) {
        throw "CI upload failed: HTTP $([int]$uploadResponse.StatusCode) $uploadBody"
    }

    $uploadData = ($uploadBody | ConvertFrom-Json).data
    $scanId = $uploadData.scanId

    if (!$scanId) {
        throw "CI API did not return a scan ID."
    }

    Write-Host "Scan queued: $scanId" -ForegroundColor Green

    $statusUrl = "$ApiBase/ci/scans/$scanId"
    $completed = $false

    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 5

        $statusResponse = $client.GetAsync($statusUrl).GetAwaiter().GetResult()
        $statusBody = $statusResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (!$statusResponse.IsSuccessStatusCode) {
            throw "Status request failed: HTTP $([int]$statusResponse.StatusCode)"
        }

        $scan = ($statusBody | ConvertFrom-Json).data

        Write-Host "Scan status: $($scan.status)"

        if ($scan.status -eq "COMPLETED") {
            $completed = $true
            break
        }

        if ($scan.status -eq "FAILED") {
            throw "DepGuard scan failed: $($scan.error)"
        }
    }

    if (!$completed) {
        throw "Scan polling timed out after 10 minutes."
    }

    $result = $scan.result
    $risk = $result.riskAnalysis

    Write-Host "`n===== DEPGUARD SCAN REPORT =====" -ForegroundColor Green
    Write-Host "Scan ID: $scanId"
    Write-Host "Status: $($scan.status)"
    Write-Host "Dependencies: $($result.totalDependencies)"
    Write-Host "Vulnerable dependencies: $($result.vulnerableDependencies)"
    Write-Host "Raw vulnerabilities: $($result.totalVulnerabilities)"

    Write-Host "`n===== PROJECT SECURITY POLICY =====" -ForegroundColor Cyan

    $policyResponse = $client.GetAsync("$ApiBase/ci/policy").GetAwaiter().GetResult()
    $policyBody = $policyResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (!$policyResponse.IsSuccessStatusCode) {
        throw "Project policy request failed: HTTP $([int]$policyResponse.StatusCode)"
    }

    $policyData = ($policyBody | ConvertFrom-Json).data
    $policy = $policyData.policy
    $exceptions = @($policyData.exceptions)

    if (
        !$policy -or
        $null -eq $policy.maxRiskScore -or
        $null -eq $policy.maxCriticalIssues -or
        $null -eq $policy.maxHighIssues -or
        $null -eq $policy.failOnFixAvailable
    ) {
        throw "Project security policy is incomplete."
    }

    if (
        [int]$policy.maxRiskScore -lt 0 -or
        [int]$policy.maxRiskScore -gt 100 -or
        [int]$policy.maxCriticalIssues -lt 0 -or
        [int]$policy.maxHighIssues -lt 0
    ) {
        throw "Project security policy contains invalid thresholds."
    }

    Write-Host "Maximum risk score: $($policy.maxRiskScore)"
    Write-Host "Maximum Critical issues: $($policy.maxCriticalIssues)"
    Write-Host "Maximum High issues: $($policy.maxHighIssues)"
    Write-Host "Fail on fix available: $($policy.failOnFixAvailable)"
    Write-Host "Active exceptions loaded: $($exceptions.Count)"

    $gateFailures = @()
    $criticalCount = 0
    $highCount = 0
    $riskScore = 0.0

    $issueList = @()
    if ($risk -and $risk.issues) {
        $issueList = @($risk.issues)
    }

    if (
        !$risk -or
        $null -eq $risk.riskScore -or
        !$risk.severityCounts -or
        !$risk.issues
    ) {
        $gateFailures += "Risk analysis, issue groups or severity counts are missing."
    }

    $effectiveIssueGroups = @()
    $effectiveTotalRiskPoints = 0.0
    $appliedExceptions = @()
    $partiallyMatchedExceptions = @()
    $policyExcludedGroups = 0

    foreach ($issue in $issueList) {
        $matchedForGroup = @()
        $unmatchedCount = 0

        if ($issue.status -eq "ACTIVE") {
            $activeAdvisories = @(
                $issue.advisories |
                    Where-Object { !$_.withdrawn }
            )

            foreach ($advisory in $activeAdvisories) {
                $identifiers = @()

                if ($advisory.id) {
                    $identifiers += [string]$advisory.id
                }

                if ($advisory.aliases) {
                    $identifiers += @($advisory.aliases)
                }

                $identifiers = @(
                    $identifiers |
                        Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) } |
                        ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } |
                        Select-Object -Unique
                )

                $matchedException = $null

                foreach ($exception in $exceptions) {
                    $ecosystemMatches = (
                        ([string]$exception.ecosystem).Trim().ToLowerInvariant() -eq
                        ([string]$issue.ecosystem).Trim().ToLowerInvariant()
                    )

                    $packageMatches = [string]::Equals(
                        [string]$exception.packageName,
                        [string]$issue.packageName,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )

                    $versionMatches = [string]::Equals(
                        [string]$exception.installedVersion,
                        [string]$issue.installedVersion,
                        [System.StringComparison]::Ordinal
                    )

                    $advisoryMatches = (
                        $identifiers -contains
                        ([string]$exception.advisoryId).Trim().ToUpperInvariant()
                    )

                    if (
                        $ecosystemMatches -and
                        $packageMatches -and
                        $versionMatches -and
                        $advisoryMatches
                    ) {
                        $matchedException = $exception
                        break
                    }
                }

                if ($matchedException) {
                    $matchedForGroup += $matchedException
                }
                else {
                    $unmatchedCount++
                }
            }

            $fullyExcepted = (
                $activeAdvisories.Count -gt 0 -and
                $unmatchedCount -eq 0
            )

            if ($fullyExcepted) {
                $policyExcludedGroups++

                $issue | Add-Member -NotePropertyName policyDisposition `
                    -NotePropertyValue "EXCEPTED" -Force

                foreach ($exception in $matchedForGroup) {
                    $appliedExceptions += $exception
                }
            }
            else {
                $effectiveIssueGroups += $issue
                $disposition = "NOT_EXEMPTED"

                if ($matchedForGroup.Count -gt 0) {
                    $disposition = "PARTIALLY_MATCHED_NOT_EXEMPTED"

                    foreach ($exception in $matchedForGroup) {
                        $partiallyMatchedExceptions += $exception
                    }
                }

                $issue | Add-Member -NotePropertyName policyDisposition `
                    -NotePropertyValue $disposition -Force

                $effectiveTotalRiskPoints += [double]$issue.riskPoints
            }
        }
        else {
            $issue | Add-Member -NotePropertyName policyDisposition `
                -NotePropertyValue "WITHDRAWN" -Force
        }

        $issue | Add-Member -NotePropertyName policyMatchedExceptions `
            -NotePropertyValue @($matchedForGroup) -Force
    }

    $effectiveActiveGroups = @($effectiveIssueGroups)

    $effectiveSeverityCounts = [ordered]@{
        CRITICAL = 0
        HIGH = 0
        MEDIUM = 0
        LOW = 0
        UNKNOWN = 0
    }

    foreach ($issue in $effectiveActiveGroups) {
        $severityName = ([string]$issue.severity).ToUpperInvariant()

        if ($effectiveSeverityCounts.Contains($severityName)) {
            $effectiveSeverityCounts[$severityName]++
        }
        else {
            $effectiveSeverityCounts.UNKNOWN++
        }
    }

    $effectiveTotalRiskPoints = [Math]::Round($effectiveTotalRiskPoints, 2)
    $riskScore = [Math]::Min(100, [Math]::Round($effectiveTotalRiskPoints))
    $securityScore = 100 - $riskScore

    $criticalCount = [int]$effectiveSeverityCounts.CRITICAL
    $highCount = [int]$effectiveSeverityCounts.HIGH

    $fixAvailableIssues = @(
        $effectiveActiveGroups | Where-Object { $_.hasFix -eq $true }
    )

    Write-Host "`n===== EFFECTIVE SECURITY RESULTS =====" -ForegroundColor Cyan
    Write-Host "Risk score: $riskScore"
    Write-Host "Security score: $securityScore"
    Write-Host "Critical issues: $criticalCount"
    Write-Host "High issues: $highCount"
    Write-Host "Active issue groups: $($effectiveActiveGroups.Count)"
    Write-Host "Fully excepted groups: $policyExcludedGroups"
    Write-Host "Issues with available fixes: $($fixAvailableIssues.Count)"

    if ($riskScore -gt [int]$policy.maxRiskScore) {
        $gateFailures += "Risk score $riskScore exceeds project maximum $($policy.maxRiskScore)."
    }

    if ($criticalCount -gt [int]$policy.maxCriticalIssues) {
        $gateFailures += "Critical issues $criticalCount exceed project maximum $($policy.maxCriticalIssues)."
    }

    if ($highCount -gt [int]$policy.maxHighIssues) {
        $gateFailures += "High issues $highCount exceed project maximum $($policy.maxHighIssues)."
    }

    if ($policy.failOnFixAvailable -and $fixAvailableIssues.Count -gt 0) {
        $gateFailures += "$($fixAvailableIssues.Count) non-exempt active issue groups have an available fix."
    }

    $policyEvaluation = [ordered]@{
        source = "PROJECT_SECURITY_POLICY"
        policyId = $policy.id
        thresholds = [ordered]@{
            maxRiskScore = $policy.maxRiskScore
            maxCriticalIssues = $policy.maxCriticalIssues
            maxHighIssues = $policy.maxHighIssues
            failOnFixAvailable = $policy.failOnFixAvailable
        }
        original = [ordered]@{
            riskScore = $risk.riskScore
            activeIssueGroups = $risk.activeIssueCount
            severityCounts = $risk.severityCounts
        }
        effective = [ordered]@{
            riskScore = $riskScore
            securityScore = $securityScore
            totalRiskPoints = $effectiveTotalRiskPoints
            activeIssueGroups = $effectiveActiveGroups.Count
            severityCounts = $effectiveSeverityCounts
            issuesWithFixAvailable = $fixAvailableIssues.Count
        }
        exceptions = [ordered]@{
            activeLoaded = $exceptions.Count
            applied = @($appliedExceptions | Sort-Object id -Unique)
            partiallyMatchedNotApplied = @($partiallyMatchedExceptions | Sort-Object id -Unique)
            fullyExceptedGroups = $policyExcludedGroups
        }
    }

    Write-Host "`n===== CI SECURITY GATE =====" -ForegroundColor Cyan
    # DEPGUARD_CI_REPORT_V1
    # Generate reports before the final gate decision.
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

    $timestamp = (Get-Date).ToUniversalTime().ToString("o")
    $safeScanId = [string]$scanId

    $jsonPath = Join-Path $reportDirectory "depguard-ci-$safeScanId.json"
    $markdownPath = Join-Path $reportDirectory "depguard-ci-$safeScanId.md"

    $issueList = @()

    if ($risk -and $risk.issues) {
        $issueList = @($risk.issues)
    }

    $remediationRecords = $result.remediation
    $reportIssues = @()

    foreach ($issue in $issueList) {
        $identifiers = @()

        if ($issue.advisoryIds -and @($issue.advisoryIds).Count -gt 0) {
            $identifiers = @($issue.advisoryIds)
        }
        elseif ($issue.aliases -and @($issue.aliases).Count -gt 0) {
            $identifiers = @($issue.aliases)
        }
        else {
            $identifiers = @([string]$issue.id)
        }

        $sortedIdentifiers = @(
            $identifiers |
                ForEach-Object { [string]$_ } |
                Sort-Object -CaseSensitive
        )

        $keyParts = New-Object 'object[]' 4
        $keyParts[0] = ([string]$issue.ecosystem).ToLowerInvariant()
        $keyParts[1] = ([string]$issue.packageName).ToLowerInvariant()
        $keyParts[2] = [string]$issue.installedVersion
        $keyParts[3] = [object[]]$sortedIdentifiers

        $issueKey = ConvertTo-Json -InputObject $keyParts -Compress -Depth 10

        $remediationProperty = $null

        if ($remediationRecords) {
            $remediationProperty = $remediationRecords.PSObject.Properties[$issueKey]
        }

        $remediation = if ($remediationProperty) {
            $remediationProperty.Value
        }
        else {
            [PSCustomObject]@{
                status = "OPEN"
                note = ""
                updatedAt = $null
                updatedBy = $null
            }
        }

        $remediationStatus = if ($remediation.status) {
            [string]$remediation.status
        }
        else {
            "OPEN"
        }

        $verificationStatus = if ($remediationStatus -eq "FIXED") {
            "NOT_CHECKED_BY_LOCAL_CI"
        }
        else {
            "NOT_MARKED_FIXED"
        }

        $reportIssues += [PSCustomObject][ordered]@{
            ecosystem = $issue.ecosystem
            packageName = $issue.packageName
            installedVersion = $issue.installedVersion
            severity = $issue.severity
            status = $issue.status
            cvssBaseScore = $issue.cvssBaseScore
            cvssVector = $issue.cvssVector
            cvssVersion = $issue.cvssVersion
            riskPoints = $issue.riskPoints
            advisoryCount = $issue.advisoryCount
            advisoryIds = $issue.advisoryIds
            aliases = $issue.aliases
            fixedVersions = $issue.fixedVersions
            hasFix = $issue.hasFix
            versionType = $issue.versionType
            summary = $issue.summary
            sourceFiles = $issue.sourceFiles
            advisories = $issue.advisories
            remediation = $remediation
            remediationStatus = $remediationStatus
            verificationStatus = $verificationStatus
            policyDisposition = $issue.policyDisposition
            policyMatchedExceptions = @($issue.policyMatchedExceptions)
        }
    }

    $gateStatus = if ($gateFailures.Count -gt 0) {
        "FAILED"
    }
    else {
        "PASSED"
    }

    $severityCounts = if ($risk -and $risk.severityCounts) {
        $risk.severityCounts
    }
    else {
        [PSCustomObject]@{
            CRITICAL = 0
            HIGH = 0
            MEDIUM = 0
            LOW = 0
            UNKNOWN = 0
        }
    }

        $severityCounts = $effectiveSeverityCounts

    $report = [ordered]@{
        reportName = "DepGuard CI Security Report"
        reportVersion = "1.0"
        generatedAt = $timestamp

        projectId = $ProjectId

        scan = [ordered]@{
            scanId = $scanId
            status = $scan.status
            createdAt = $scan.createdAt
            completedAt = $scan.completedAt
        }

        dependencySummary = [ordered]@{
            totalDependencies = $result.totalDependencies
            vulnerableDependencies = $result.vulnerableDependencies
            totalVulnerabilities = $result.totalVulnerabilities
            dependencyFiles = $result.dependencyFiles
            ecosystems = $result.ecosystems
            enrichmentStatus = $result.enrichmentStatus
        }

        riskAnalysis = [ordered]@{
            methodology = $risk.methodology
            riskScore = $riskScore
            securityScore = $securityScore
            totalRiskPoints = $effectiveTotalRiskPoints
            totalIssueGroups = $risk.totalIssueGroups
            activeIssueCount = $effectiveActiveGroups.Count
            withdrawnIssueCount = $risk.withdrawnIssueCount
            severityCounts = $severityCounts
            cvssScoredIssues = $risk.cvssScoredIssues
        }

        policyEvaluation = $policyEvaluation
        issues = $reportIssues

        remediationSummary = [ordered]@{
            OPEN = @($reportIssues | Where-Object remediationStatus -eq "OPEN").Count
            IN_PROGRESS = @($reportIssues | Where-Object remediationStatus -eq "IN_PROGRESS").Count
            FIXED = @($reportIssues | Where-Object remediationStatus -eq "FIXED").Count
            ACCEPTED_RISK = @($reportIssues | Where-Object remediationStatus -eq "ACCEPTED_RISK").Count
            IGNORED = @($reportIssues | Where-Object remediationStatus -eq "IGNORED").Count
        }

        securityGate = [ordered]@{
            status = $gateStatus
            thresholds = [ordered]@{
                maxRiskScore = $policy.maxRiskScore
                maxCriticalIssues = $policy.maxCriticalIssues
                maxHighIssues = $policy.maxHighIssues
                failOnFixAvailable = $policy.failOnFixAvailable
            }
            actual = [ordered]@{
                riskScore = $riskScore
                criticalIssues = $criticalCount
                highIssues = $highCount
                issuesWithFixAvailable = $fixAvailableIssues.Count
            }
            failures = @($gateFailures)
        }

        verificationNote = "Local CI does not retrieve scan history. FIXED issues are marked NOT_CHECKED_BY_LOCAL_CI. The Dashboard verifies fixes by comparing newer completed scans."
    }

    $json = ConvertTo-Json -InputObject $report -Depth 100

    [System.IO.File]::WriteAllText(
        $jsonPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    function ConvertTo-ReportCell {
        param($Value)

        if ($null -eq $Value) {
            return ""
        }

        return ([string]$Value -replace '\|', '\|' -replace '[\r\n]+', ' ')
    }

    $md = New-Object System.Collections.Generic.List[string]

    $md.Add("# DepGuard CI Security Report")
    $md.Add("")
    $md.Add("- **Project ID:** $ProjectId")
    $md.Add("- **Scan ID:** $scanId")
    $md.Add("- **Generated:** $timestamp")
    $md.Add("- **Scan status:** $($scan.status)")
    $md.Add("- **CI Security Gate:** $gateStatus")
    $md.Add("")
    $md.Add("## Dependency Summary")
    $md.Add("")
    $md.Add("| Metric | Result |")
    $md.Add("|---|---:|")
    $md.Add("| Total dependencies | $($result.totalDependencies) |")
    $md.Add("| Vulnerable dependencies | $($result.vulnerableDependencies) |")
    $md.Add("| Raw vulnerabilities | $($result.totalVulnerabilities) |")
    $md.Add("")
    $md.Add("## Risk Summary")
    $md.Add("")
    $md.Add("| Metric | Result |")
    $md.Add("|---|---:|")
    $md.Add("| Risk score | $riskScore |")
    $md.Add("| Security score | $securityScore |")
    $md.Add("| Active issue groups | $($effectiveActiveGroups.Count) |")
    $md.Add("| Withdrawn issue groups | $($risk.withdrawnIssueCount) |")
    $md.Add("| CVSS-scored issues | $($risk.cvssScoredIssues) |")
    $md.Add("")
    $md.Add("### Severity Breakdown")
    $md.Add("")
    $md.Add("| Severity | Count |")
    $md.Add("|---|---:|")
    $md.Add("| Critical | $($severityCounts.CRITICAL) |")
    $md.Add("| High | $($severityCounts.HIGH) |")
    $md.Add("| Medium | $($severityCounts.MEDIUM) |")
    $md.Add("| Low | $($severityCounts.LOW) |")
    $md.Add("| Unknown | $($severityCounts.UNKNOWN) |")
    $md.Add("")
    $md.Add("## Project Policy Evaluation")
    $md.Add("")
    $md.Add("- Policy source: Saved project security policy")
    $md.Add("- Policy ID: $($policy.id)")
    $md.Add("- Maximum risk score: $($policy.maxRiskScore)")
    $md.Add("- Maximum Critical issues: $($policy.maxCriticalIssues)")
    $md.Add("- Maximum High issues: $($policy.maxHighIssues)")
    $md.Add("- Fail on fix available: $($policy.failOnFixAvailable)")
    $md.Add("- Active exceptions loaded: $($exceptions.Count)")
    $md.Add("- Fully excepted issue groups: $policyExcludedGroups")
    $md.Add("- Applied exceptions: $(@($appliedExceptions | Sort-Object id -Unique).Count)")
    $md.Add("- Partially matched exceptions not applied: $(@($partiallyMatchedExceptions | Sort-Object id -Unique).Count)")
    $md.Add("- Non-exempt issues with fixes: $($fixAvailableIssues.Count)")
    $md.Add("")
    $md.Add("## Security Gate")
    $md.Add("")
    $md.Add("- **Result:** $gateStatus")
    $md.Add("- Maximum risk score: $($policy.maxRiskScore)")
    $md.Add("- Maximum Critical issues: $($policy.maxCriticalIssues)")
    $md.Add("- Maximum High issues: $($policy.maxHighIssues)")
    $md.Add("")

    if ($gateFailures.Count -gt 0) {
        $md.Add("### Gate failures")
        $md.Add("")
        foreach ($failure in $gateFailures) {
            $md.Add("- BLOCKED: $failure")
        }
        $md.Add("")
    }

    $md.Add("## Remediation Summary")
    $md.Add("")
    $md.Add("| Status | Count |")
    $md.Add("|---|---:|")

    foreach ($statusName in @("OPEN", "IN_PROGRESS", "FIXED", "ACCEPTED_RISK", "IGNORED")) {
        $count = @($reportIssues | Where-Object remediationStatus -eq $statusName).Count
        $md.Add("| $statusName | $count |")
    }

    $md.Add("")
    $md.Add("## Vulnerability Details")
    $md.Add("")
    $md.Add("| Ecosystem | Package | Installed | Severity | CVSS | Risk | Fix versions | Policy | Remediation | Verification |")
    $md.Add("|---|---|---|---|---:|---:|---|---|---|---|")

    $displayIssues = @($reportIssues | Select-Object -First 500)

    foreach ($issue in $displayIssues) {
        $fixed = (@($issue.fixedVersions) -join ", ")
        $md.Add(
            "| $(ConvertTo-ReportCell $issue.ecosystem) | $(ConvertTo-ReportCell $issue.packageName) | $(ConvertTo-ReportCell $issue.installedVersion) | $(ConvertTo-ReportCell $issue.severity) | $(ConvertTo-ReportCell $issue.cvssBaseScore) | $(ConvertTo-ReportCell $issue.riskPoints) | $(ConvertTo-ReportCell $fixed) | $(ConvertTo-ReportCell $issue.policyDisposition) | $(ConvertTo-ReportCell $issue.remediationStatus) | $(ConvertTo-ReportCell $issue.verificationStatus) |"
        )
    }

    if ($reportIssues.Count -gt 500) {
        $md.Add("")
        $md.Add("Showing first 500 issue groups. The JSON report contains all issue groups.")
    }

    $md.Add("")
    $md.Add("## Verification Note")
    $md.Add("")
    $md.Add("Local CI does not retrieve scan history. Issues marked FIXED are labelled NOT_CHECKED_BY_LOCAL_CI. Use the DepGuard Dashboard and a newer completed scan to verify whether an issue is actually resolved.")
    $md.Add("")
    $md.Add("---")
    $md.Add("*Generated automatically by DepGuard Local CI.*")

    [System.IO.File]::WriteAllLines(
        $markdownPath,
        $md,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host "`n===== CI REPORTS GENERATED =====" -ForegroundColor Cyan
    Write-Host "JSON: $jsonPath" -ForegroundColor Green
    Write-Host "Markdown: $markdownPath" -ForegroundColor Green
    Write-Host "Issue groups included: $($reportIssues.Count)"
    if ($gateFailures.Count -gt 0) {
        Write-Host "`n===== CI SECURITY GATE: FAILED =====" -ForegroundColor Red

        foreach ($failure in $gateFailures) {
            Write-Host "BLOCKED: $failure" -ForegroundColor Red
        }

        Write-Host "`nLOCAL CI FAILED. Build must be blocked." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n===== CI SECURITY GATE: PASSED =====" -ForegroundColor Green
    Write-Host "All configured security thresholds satisfied." -ForegroundColor Green
    Write-Host "`nLOCAL CI PASSED." -ForegroundColor Green
    $global:LASTEXITCODE = 0
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($multipart) { $multipart.Dispose() }
    $client.Dispose()
    $handler.Dispose()
}



