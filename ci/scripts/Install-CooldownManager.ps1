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
    answer. Passing it once also teaches the script where this machine keeps
    WoW, so the clients installed beside it are found from then on.

.PARAMETER Flavour
    Install to the client whose folder matches this, e.g. era, classic, ptr.
    Matched loosely against the folder name, so it also finds a client this
    script has no name for.

.PARAMETER All
    Install to every WoW client found. The addon supports three game versions,
    and leaving them on different builds is how you end up testing the wrong
    one.

.PARAMETER Forget
    Ignore the remembered folder and pick again.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CooldownManager.ps1

    Installs develop, asking once which client if there is more than one.

.EXAMPLE
    .\Install-CooldownManager.ps1 -Branch claude/my-feature -All

    Installs a feature branch to every client at once. The addon list will read
    0.6.0-my-feature.<sha> in each.

.EXAMPLE
    .\Install-CooldownManager.ps1 -Flavour era

    Installs develop to the Classic Era client only.

.NOTES
    Windows blocks scripts downloaded from the internet, hence the
    -ExecutionPolicy Bypass above. To avoid typing it every time, unblock the
    file once:  Unblock-File .\Install-CooldownManager.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Branch = 'develop',
    [string] $AddOnsPath,
    [string] $Flavour,
    [switch] $All,
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

function Get-RememberedRoots {
    $file = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        return @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Roots)
    } catch {
        return @()
    }
}

function Save-Settings([string] $Path) {
    $file = Get-SettingsPath
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # An AddOns path is <root>\<flavour>\Interface\AddOns, so its WoW root is
    # three levels up. Remembering the root rather than only the leaf is what
    # lets a later -All find the other clients installed beside it.
    $root = $null
    try { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Path)) } catch { }

    $roots = @(Get-RememberedRoots)
    if ($root -and $roots -notcontains $root) { $roots += $root }

    [pscustomobject]@{ AddOnsPath = $Path; Roots = @($roots) } |
        ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
}

function Get-FlavourLabel([string] $Folder) {
    # Only the folders whose meaning is certain get a friendly name. Anything
    # else keeps its own -- a confident-sounding wrong label is worse than the
    # raw folder, which is at least what the player sees in the launcher.
    switch -Regex ($Folder) {
        '^_classic_era_ptr_$' { 'Classic Era PTR' ; break }
        '^_classic_era_$'     { 'Classic Era (incl. Season of Discovery, Hardcore)' ; break }
        '^_classic_ptr_$'     { 'Classic progression PTR' ; break }
        '^_classic_beta_$'    { 'Classic beta' ; break }
        '^_classic_$'         { 'Classic progression' ; break }
        '^_retail_$'          { 'Retail' ; break }
        '^_ptr_$'             { 'Retail PTR' ; break }
        '^_beta_$'            { 'Retail beta' ; break }
        default               { $Folder }
    }
}

function Find-AddOnsCandidates {
    # Flavour folders are enumerated rather than hardcoded: Blizzard has added
    # and renamed them over the years (_classic_era_, _classic_, _retail_, the
    # _ptr_ variants), and a wrong guess here is a silent no-match. Enumerating
    # also means a client this script has never heard of -- an Anniversary or
    # seasonal install under whatever folder Blizzard gave it -- is found anyway.
    # Join-Path throws on a null base, and an environment variable that is not
    # set is null rather than empty -- so the Program Files roots are built only
    # when there is something to build them from.
    $roots = @()
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { $roots += (Join-Path $base 'World of Warcraft') }
    }

    # Every fixed drive, rather than a list of drive letters: Battle.net installs
    # wherever it is pointed, and a game this size routinely lands on whichever
    # disk had room -- G: as readily as C:. Four Test-Paths per drive costs
    # nothing, and guessing letters is how an install goes unfound.
    # Fixed and ready only: a network drive would hang the scan and an empty
    # optical drive would throw.
    $drives = @()
    try {
        $drives = [IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
            ForEach-Object { $_.RootDirectory.FullName }
    } catch {
        Write-Verbose "Could not enumerate drives; falling back to the usual locations."
        $drives = @('C:\', 'D:\')
    }

    foreach ($drive in $drives) {
        $roots += (Join-Path $drive 'World of Warcraft')
        $roots += (Join-Path (Join-Path $drive 'Games') 'World of Warcraft')
        $roots += (Join-Path (Join-Path $drive 'Program Files (x86)') 'World of Warcraft')
        $roots += (Join-Path (Join-Path $drive 'Program Files') 'World of Warcraft')
    }

    # Roots learned from an explicit -AddOnsPath. Point the script at one client
    # by hand once and its siblings are found from then on, which is what makes
    # -All work on an install that lives somewhere unusual.
    $roots += @(Get-RememberedRoots)

    $roots = $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique

    $found = foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                # Nested rather than 'Interface\AddOns': a literal backslash is
                # not a separator everywhere, and Join-Path only takes a third
                # segment on PowerShell 7, which Windows PowerShell 5.1 is not.
                $addons = Join-Path (Join-Path $_.FullName 'Interface') 'AddOns'
                if (Test-Path -LiteralPath $addons) {
                    [pscustomobject]@{
                        Path    = $addons
                        Flavour = $_.Name
                        Label   = Get-FlavourLabel $_.Name
                    }
                }
            }
    }
    return @($found | Sort-Object -Property Path -Unique)
}

function Resolve-Targets {
    # An explicit path wins outright, and teaches the script where this machine
    # keeps WoW so -All can find the rest later.
    if ($AddOnsPath) {
        if (-not (Test-Path -LiteralPath $AddOnsPath)) {
            throw "AddOns folder not found: $AddOnsPath"
        }
        $resolved = (Resolve-Path -LiteralPath $AddOnsPath).Path
        Save-Settings $resolved
        return @([pscustomobject]@{ Path = $resolved; Flavour = 'explicit'; Label = 'the folder you gave' })
    }

    $candidates = Find-AddOnsCandidates

    if ($candidates.Count -eq 0) {
        throw ("Could not find a WoW AddOns folder. Pass one explicitly, e.g.`n" +
               "  -AddOnsPath 'C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns'`n" +
               "It is remembered, and the other clients installed beside it are found from then on.")
    }

    # Every client at once. The reason this exists: the addon supports three
    # game versions, and keeping them on different builds is how you end up
    # testing the wrong one.
    if ($All) { return $candidates }

    if ($Flavour) {
        $matched = @($candidates | Where-Object { $_.Flavour -like "*$Flavour*" -or $_.Label -like "*$Flavour*" })
        if ($matched.Count -eq 0) {
            $known = ($candidates | ForEach-Object { $_.Flavour }) -join ', '
            throw "No installed client matches '$Flavour'. Found: $known"
        }
        return $matched
    }

    if (-not $Forget) {
        $remembered = Get-RememberedAddOnsPath
        if ($remembered) {
            $match = $candidates | Where-Object { $_.Path -eq $remembered } | Select-Object -First 1
            if ($match) { return @($match) }
            return @([pscustomobject]@{ Path = $remembered; Flavour = 'remembered'; Label = 'remembered folder' })
        }
    }

    if ($candidates.Count -eq 1) {
        Save-Settings $candidates[0].Path
        return @($candidates[0])
    }

    Write-Host "`nFound more than one WoW client:`n"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $candidates[$i].Flavour) -NoNewline
        Write-Host ("  -- {0}" -f $candidates[$i].Label) -ForegroundColor DarkGray
    }
    Write-Host ("  [A] all of them" ) -ForegroundColor DarkGray
    $answer = Read-Host "`nWhich one? (1-$($candidates.Count), or A)"

    if ($answer -match '^[Aa]$') { return $candidates }

    $index = 0
    if (-not [int]::TryParse($answer, [ref] $index) -or $index -lt 1 -or $index -gt $candidates.Count) {
        throw "Not a valid choice: '$answer'"
    }
    Save-Settings $candidates[$index - 1].Path
    Write-Host "Remembered. Use -Flavour, -All or -Forget to install elsewhere." -ForegroundColor DarkGray
    return @($candidates[$index - 1])
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

$targets = Resolve-Targets

Write-Host ""
Write-Host "Repo:    $Owner/$Repo"
Write-Host "Branch:  $Branch"
Write-Host ("Clients: {0}" -f (($targets | ForEach-Object { $_.Flavour }) -join ', '))
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

    # One download, installed to each client. Downloading per client would risk
    # them ending up on different commits if the branch moved mid-run, which is
    # the exact confusion the version stamp exists to prevent.
    $installed = 0
    foreach ($target in $targets) {
        $destination = Join-Path $target.Path $AddonName

        if (-not $PSCmdlet.ShouldProcess($destination, "Replace addon install")) { continue }

        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        foreach ($item in Get-ChildItem -LiteralPath $extracted.FullName -Force) {
            if ($item.PSIsContainer) {
                if ($ExcludeDirs -contains $item.Name) { continue }
            } else {
                if ($ExcludeFiles -contains $item.Name) { continue }
                if ($item.Name -like '.env*') { continue }
            }
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
        }

        $installed++
        Write-Host ("  installed to {0}  ({1})" -f $target.Flavour, $target.Path) -ForegroundColor Green
    }

    if ($installed -gt 0) {
        Write-Host ""
        Write-Host "Installed to $installed client(s)." -ForegroundColor Green
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
