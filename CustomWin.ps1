
[714 lines collapsed]

    $Roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432
        [string]$env:ProgramFiles,
        [string]${env:ProgramFiles(x86)},
        [string]$env:ProgramW6432
    )
    $Paths = New-Object System.Collections.Generic.List[string]
    $Paths = @()
    foreach ($Root in $Roots) {

[4 lines collapsed]

        }
        foreach ($RelativePath in $RelativePaths) {
        foreach ($RelativePath in @($RelativePaths)) {
            if ([string]::IsNullOrWhiteSpace($RelativePath)) {
            $Relative = [string]$RelativePath
            if ([string]::IsNullOrWhiteSpace($Relative)) {
                continue
            }
            $FullPath = Join-Path $Root $RelativePath
            $FullPath = Join-Path -Path $Root -ChildPath $Relative
            if (-not $Paths.Contains($FullPath)) {
            if ($Paths -notcontains $FullPath) {
                $Paths.Add($FullPath)
                $Paths += $FullPath
            }
        }
    }
    foreach ($ExtraPath in $ExtraPaths) {
    foreach ($ExtraPath in @($ExtraPaths)) {
        if ([string]::IsNullOrWhiteSpace($ExtraPath)) {
        $Extra = [string]$ExtraPath
        if ([string]::IsNullOrWhiteSpace($Extra)) {
            continue
        }
        if (-not $Paths.Contains($ExtraPath)) {
        if ($Paths -notcontains $Extra) {
            $Paths.Add($ExtraPath)
            $Paths += $Extra
        }
    }
    return @($Paths)
    return ,$Paths
}

[131 lines collapsed]

    )
    $Candidates = @(
        Get-CandidatePaths `
            -RelativePaths $RelativePaths `
            -ExtraPaths $ExtraPaths
    )
    $Candidates = Get-CandidatePaths `
        -RelativePaths $RelativePaths `
        -ExtraPaths $ExtraPaths
    foreach ($Candidate in $Candidates) {
    foreach ($Candidate in @($Candidates)) {
        if (Test-Path -LiteralPath $Candidate) {
        if ([string]::IsNullOrWhiteSpace([string]$Candidate)) {
            continue
        }
        if (Test-Path -LiteralPath ([string]$Candidate)) {
            return [pscustomobject]@{
                Version  = Get-FileVersionText -Path $Candidate
                Location = $Candidate
                Version  = Get-FileVersionText -Path ([string]$Candidate)
                Location = [string]$Candidate
            }
        }
    }

[602 lines collapsed]

    try {
        & $Schtasks /Create /TN $TaskName /TR "$env:SystemRoot\explorer.exe" /SC ONCE /ST 00:00 /F /RL LIMITED > $null
        $StartAt = (Get-Date).AddMinutes(5)
        $TaskTime = $StartAt.ToString("HH:mm")
        $TaskDate = $StartAt.ToString((Get-Culture).DateTimeFormat.ShortDatePattern)
        $CreateOutput = & $Schtasks /Create /TN $TaskName /TR "$env:SystemRoot\explorer.exe" /SC ONCE /ST $TaskTime /SD $TaskDate /F /RL LIMITED 2>&1
        if ($LASTEXITCODE -eq 0) {
            & $Schtasks /Run /TN $TaskName > $null
            $RunOutput = & $Schtasks /Run /TN $TaskName 2>&1
            for ($Wait = 1; $Wait -le 20; $Wait++) {

[12 lines collapsed]

    }
    finally {
        & $Schtasks /Delete /TN $TaskName /F > $null
        $DeleteOutput = & $Schtasks /Delete /TN $TaskName /F 2>&1
        $ErrorActionPreference = $PreviousErrorAction
    }

[75 lines collapsed]

    }
    $LiveRoots = New-Object System.Collections.Generic.List[string]
    $LiveRoots = @("HKCU:")
    $LiveRoots.Add("HKCU:")
    $ProfileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    foreach ($Profile in @(Get-ChildItem -LiteralPath $ProfileList -ErrorAction SilentlyContinue)) {

[37 lines collapsed]

            if (Test-Path -LiteralPath $LoadedUser) {
                if (-not $LiveRoots.Contains($LoadedUser)) {
                if ($LiveRoots -notcontains $LoadedUser) {
                    $LiveRoots.Add($LoadedUser)
                    $LiveRoots += $LoadedUser
                }
                continue

[755 lines collapsed]
