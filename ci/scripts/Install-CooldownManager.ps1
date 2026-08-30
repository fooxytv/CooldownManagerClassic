<#
.SYNOPSIS
    Installs Cooldown Manager Classic straight from GitHub into a WoW AddOns
    folder, with the branch name stamped into the version.

.DESCRIPTION
    For a machine that plays the game rather than builds the addon: this is the
    only file it needs. No git, no bash, no toolchain -- it downloads the branch
    itself, drops the files that do not belong in an addon, and installs what is
    left.

    The version in the .toc is stamped with the branch and commit it came from,
    so the in-game addon list says which build is loaded. Two builds that both
    report "0.6.0-alpha.<sha>" are indistinguishable in game, and by the time
    something behaves oddly you are debugging the wrong one.

    The previous install is removed rather than copied over, so a file deleted
    or renamed upstream cannot linger in the AddOns folder and keep being loaded
    from the .toc.

.PARAMETER Branch
    Branch to install. Defaults to develop. Any branch, tag or commit that
    GitHub will serve an archive for works.

.PARAMETER AddOnsPath
    The Interface\AddOns folder to install into. Omit it and the script looks
    for one, asking if there is more than one candidate, and remembers the
    answer for next time.

.PARAMETER Forget
    Discard the remembered AddOns folder and pick again.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CooldownManager.ps1

    Installs develop, asking once where the AddOns folder is.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CooldownManager.ps1 -Branch claude/cooldown-manager-range-indicator-3aog48

    Installs a feature branch. The addon list will read
    0.6.0-cooldown-manager-range-indicator-3aog48.<sha>

.NOTES
    Windows blocks scripts downloaded from the internet, hence the
    -ExecutionPolicy Bypass above. To avoid typing it every time, unblock the
    file once:  Unblock-File .\Install-CooldownManager.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Branch = 'develop',
    [string] $AddOnsPath,
    [switch] $Forget
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 still negotiates TLS 1.0 by default, which GitHub
# refuses; and its progress bar makes Invoke-WebRequest an order of magnitude
# slower. Both are no-ops on PowerShell 7.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not raise the TLS version; continuing with the default."
}
$ProgressPreference = 'SilentlyContinue'

$Owner      = 'fooxytv'
$Repo       = 'CooldownManagerClassic'
$AddonName  = 'CooldownManagerClassic'   # must match the .toc basename

# Mirrors the exclusion list in ci/scripts/package.sh. Deny rather than allow,
# so a new addon folder is shipped without anyone remembering to list it here --
# but the two lists have to be changed together.
$ExcludeDirs = @('.git', '.github', 'ci', 'docs', 'code', 'dist', '.vscode', '.claude')
$ExcludeFiles = @('README.md', 'CLAUDE.md', '.luacheckrc', '.gitignore', '.gitattributes')

function Get-SettingsPath {
    $root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
            elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME }
            else { [IO.Path]::GetTempPath() }
    Join-Path $root "$AddonName\install-settings.json"
}

function Get-RememberedAddOnsPath {
    $file = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $saved = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).AddOnsPath
        if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
    } catch {
        # A corrupt settings file is not worth failing over; pick again instead.
        Write-Verbose "Ignoring unreadable settings file at $file"
    }
    return $null
}

function Save-AddOnsPath([string] $Path) {
    $file = Get-SettingsPath
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]@{ AddOnsPath = $Path } | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Host "Remembered this AddOns folder. Re-run with -Forget to change it." -ForegroundColor DarkGray
}

function Find-AddOnsCandidates {
    # Flavour folders are enumerated rather than hardcoded: Blizzard has added
    # and renamed them over the years (_classic_era_, _classic_, _retail_, the
    # _ptr_ variants), and a wrong guess here is a silent no-match.
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'World of Warcraft'),
        (Join-Path $env:ProgramFiles 'World of Warcraft'),
        'C:\World of Warcraft',
        'D:\World of Warcraft',
        'C:\Games\World of Warcraft',
        'D:\Games\World of Warcraft'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $found = foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $addons = Join-Path $_.FullName 'Interface\AddOns'
                if (Test-Path -LiteralPath $addons) { $addons }
            }
    }
    return @($found | Sort-Object -Unique)
}

function Resolve-AddOnsPath {
    if ($AddOnsPath) {
        if (-not (Test-Path -LiteralPath $AddOnsPath)) {
            throw "AddOns folder not found: $AddOnsPath"
        }
        return (Resolve-Path -LiteralPath $AddOnsPath).Path
    }

    if (-not $Forget) {
        $remembered = Get-RememberedAddOnsPath
        if ($remembered) { return $remembered }
    }

    $candidates = Find-AddOnsCandidates
    if ($candidates.Count -eq 0) {
        throw ("Could not find a WoW AddOns folder. Pass one explicitly, e.g.`n" +
               "  -AddOnsPath 'C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns'")
    }

    $chosen = if ($candidates.Count -eq 1) {
        $candidates[0]
    } else {
        Write-Host "`nFound more than one WoW install:`n"
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $candidates[$i])
        }
        $answer = Read-Host "`nWhich one? (1-$($candidates.Count))"
        $index = 0
        if (-not [int]::TryParse($answer, [ref] $index) -or $index -lt 1 -or $index -gt $candidates.Count) {
            throw "Not a valid choice: '$answer'"
        }
        $candidates[$index - 1]
    }

    Save-AddOnsPath $chosen
    return $chosen
}

function Get-CommitSha([string] $Ref) {
    # Anonymous and rate-limited to 60/hour, which is far more than anyone
    # installs. The sha is only for the version stamp, so a failure here should
    # not stop the install.
    try {
        $uri = "https://api.github.com/repos/$Owner/$Repo/commits/$Ref"
        $commit = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = $AddonName } -TimeoutSec 30
        return $commit.sha.Substring(0, 7)
    } catch {
        Write-Warning "Could not read the commit for '$Ref' ($($_.Exception.Message)); stamping without a sha."
        return $null
    }
}

function Get-BranchSlug([string] $Name) {
    # Kept in step with ci/scripts/deploy-branch.sh so a build made either way
    # reports the same version string.
    $slug = $Name -replace '^(claude|feat|feature|fix|hotfix|docs|chore|release)/', ''
    $slug = $slug -replace '[^A-Za-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
    return $slug
}

# ---------------------------------------------------------------------------

# Everything below runs inside one try, so a mistyped branch or a missing AddOns
# folder prints one readable line instead of PowerShell's red source listing.
# This is run by someone who wants to play the game, not debug a script.
try {

$destinationRoot = Resolve-AddOnsPath
$destination = Join-Path $destinationRoot $AddonName

Write-Host ""
Write-Host "Repo:    $Owner/$Repo"
Write-Host "Branch:  $Branch"
Write-Host "Install: $destination"
Write-Host ""

$sha = Get-CommitSha $Branch
$staging = Join-Path ([IO.Path]::GetTempPath()) ("$AddonName-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    $archive = Join-Path $staging 'source.zip'
    $url = "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Branch"

    Write-Host "Downloading $Branch..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $archive -Headers @{ 'User-Agent' = $AddonName } -TimeoutSec 120
    } catch {
        throw ("Could not download branch '$Branch'.`n" +
               "GitHub returns 404 for a branch that does not exist. Check the spelling, " +
               "or list branches at https://github.com/$Owner/$Repo/branches`n" +
               "Underlying error: $($_.Exception.Message)")
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force

    # GitHub names the top folder after the ref with slashes flattened, which is
    # fiddly to predict; there is only ever one, so take whatever is there.
    $extracted = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
    if (-not $extracted) { throw "The downloaded archive did not contain a folder." }

    $mainToc = Join-Path $extracted.FullName "$AddonName.toc"
    if (-not (Test-Path -LiteralPath $mainToc)) {
        throw "No $AddonName.toc in the download -- is '$Branch' a branch of this addon?"
    }

    # Stamp every .toc, so whichever flavour the client loads reports the same.
    $baseVersion = ((Select-String -LiteralPath $mainToc -Pattern '^## Version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
    $baseVersion = ($baseVersion -split '-')[0]
    $slug = Get-BranchSlug $Branch
    $stamped = if ($sha) { "$baseVersion-$slug.$sha" } else { "$baseVersion-$slug" }

    foreach ($toc in Get-ChildItem -LiteralPath $extracted.FullName -Filter '*.toc') {
        $text = Get-Content -LiteralPath $toc.FullName -Raw
        $text = $text -replace '(?m)^## Version:.*$', "## Version: $stamped"
        Set-Content -LiteralPath $toc.FullName -Value $text -NoNewline
    }

    Write-Host "Version: $stamped"

    if ($PSCmdlet.ShouldProcess($destination, "Replace addon install")) {
        if (Test-Path -LiteralPath $destination) {
            Write-Host "Removing the previous install..."
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        $copied = 0
        foreach ($item in Get-ChildItem -LiteralPath $extracted.FullName -Force) {
            if ($item.PSIsContainer) {
                if ($ExcludeDirs -contains $item.Name) { continue }
            } else {
                if ($ExcludeFiles -contains $item.Name) { continue }
                if ($item.Name -like '.env*') { continue }
            }
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
            $copied++
        }

        Write-Host ""
        Write-Host "Installed $copied top-level items to $destination" -ForegroundColor Green
        Write-Host "Type /reload in game (or restart it if the addon was not loaded before)."
        Write-Host "The addon list should show version $stamped."
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

} catch {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    exit 1
}
