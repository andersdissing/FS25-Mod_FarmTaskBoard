# release.ps1
# Starts a GitHub release: sets <version> in Build\modDesc.xml, commits, tags v<version>
# and pushes. The tag push runs .github/workflows/release.yml, which builds the zip and
# publishes the release.
#
# Usage:
#   pwsh -File tools\release.ps1 1.3.3.0          set the version, commit, tag, push
#   pwsh -File tools\release.ps1                  release the version already in modDesc.xml
#   pwsh -File tools\release.ps1 -Beta 1          test build: tag v<version>-beta.1, GitHub pre-release
#                                                 (modDesc keeps the 4-number version ModHub needs)

param(
    [string]$Version,
    [int]$Beta = 0
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModDesc  = Join-Path $RepoRoot 'Build\modDesc.xml'

Push-Location $RepoRoot
try {
    if (git status --porcelain) {
        throw 'Working tree has uncommitted changes. Commit or stash them first.'
    }

    $current = ([xml](Get-Content $ModDesc -Raw)).modDesc.version
    if (-not $Version) {
        $Version = $current
    }
    # FS25 mod versions have four parts
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Version '$Version' must look like 1.3.2.0"
    }
    $tag = "v$Version"
    if ($Beta -gt 0) {
        $tag = "v$Version-beta.$Beta"
    }

    if (git tag --list $tag) {
        throw "Tag $tag already exists"
    }

    if ($Version -ne $current) {
        # Text replace, so the rest of modDesc.xml keeps its formatting
        $text = Get-Content $ModDesc -Raw
        $text = $text -replace "<version>$([regex]::Escape($current))</version>", "<version>$Version</version>"
        Set-Content $ModDesc $text -NoNewline
        git add $ModDesc
        git commit -q -m "Version $Version"
        Write-Host "modDesc.xml: $current -> $Version"
    }

    # The workflow runs the same checks; locally only if luaparser is installed
    python -c "import luaparser" 2>$null
    if ($LASTEXITCODE -eq 0) {
        python tests/check_static.py Build
        if ($LASTEXITCODE -ne 0) {
            throw 'Static checks failed, nothing tagged or pushed'
        }
    } else {
        Write-Host 'luaparser not installed (pip install luaparser), static checks run in the workflow only'
    }

    $message = if ($Beta -gt 0) { "Test build $Version beta $Beta" } else { "Release $Version" }
    git tag -a $tag -m $message
    git push origin HEAD
    git push origin $tag
    Write-Host "Pushed $tag. Follow the release build with: gh run watch"
} finally {
    Pop-Location
}
