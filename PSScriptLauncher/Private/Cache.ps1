# Catalog cache: what the tree needs to paint before the inventory runs.
# One file per analyzed folder, next to the user state. Cached data is language-neutral (the
# synopsis comes from the script itself, warnings are only counted), so switching the interface
# language never invalidates it.

function Get-CatalogCachePath {
    # Cache file of a root folder: <state folder>\cache\<sha1 of the normalized root>.json
    param([Parameter(Mandatory)][string]$Root, [string]$StatePath)

    if (-not $StatePath) { $StatePath = Get-DefaultStatePath }
    $folder = Join-Path (Split-Path -Parent $StatePath) 'cache'
    $normalized = $Root.TrimEnd('\', '/').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
    }
    finally { $sha.Dispose() }
    $name = -join ($hash | ForEach-Object { $_.ToString('x2') })
    Join-Path $folder ($name + '.json')
}

function New-CatalogCache {
    # Empty cache for a folder.
    param([Parameter(Mandatory)][string]$Root)

    @{
        Version = [int]$script:Settings.CacheVersion
        Root    = $Root.TrimEnd('\', '/')
        Entries = @{}
    }
}

function Get-CacheKey {
    # Key of a file in the cache: its full path, without case.
    param([Parameter(Mandatory)][string]$Path)

    $Path.ToLowerInvariant()
}

function Test-CachedFile {
    # True when the entry still describes the file: same modification time and same size.
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)]$File)

    ($Entry.Mtime -eq $File.LastWriteTimeUtc.Ticks) -and ($Entry.Size -eq [long]$File.Length)
}

function ConvertFrom-CachedScript {
    # Script information rebuilt from a cache entry: the fields the tree uses, plus the raw help block
    # re-reads the file when the script is selected: parameters and formatted help are not cached.
    param([Parameter(Mandatory)][hashtable]$Entry, [Parameter(Mandatory)][string]$Root)

    $relative = [string]$Entry.RelativePath
    $full = Join-Path $Root $relative
    [pscustomobject]@{
        Path              = $full
        Name              = [System.IO.Path]::GetFileName($relative)
        BaseName          = [System.IO.Path]::GetFileNameWithoutExtension($relative)
        Directory         = [System.IO.Path]::GetDirectoryName($full)
        RelativePath      = $relative
        RelativeDirectory = [System.IO.Path]::GetDirectoryName($relative)
        Synopsis          = [string]$Entry.Synopsis
        Description       = (Get-HelpSectionText -Text ([string]$Entry.HelpBlock) -Name 'DESCRIPTION')
        HelpBlock         = [string]$Entry.HelpBlock
        SearchText        = ([string]$Entry.RelativePath + ' ' + [string]$Entry.Synopsis + ' ' + [string]$Entry.HelpBlock)
        ParameterHelp     = (Get-HelpParameterSection -Text ([string]$Entry.HelpBlock))
        HelpStatus        = [string]$Entry.HelpStatus
        MissingSynopsis       = [bool]$Entry.MissingSynopsis
        MissingDescription    = [bool]$Entry.MissingDescription
        MissingExample        = [bool]$Entry.MissingExample
        UndocumentedParameters = [string[]]@($Entry.Undocumented)
        UndocumentedCount     = @($Entry.Undocumented).Count
        WarningCount      = [int]$Entry.Warnings
        Warnings          = @()
        FromCache         = $true
    }
}

function Read-CatalogCache {
    # Cache of a folder, or an empty cache when the file is missing, unreadable, of another version
    # or built for another folder. A cache never prevents the launcher from starting.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $cache = New-CatalogCache -Root $Root
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $cache }
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $data = ConvertTo-PlainHashtable -InputObject ($json | ConvertFrom-Json)
        if ($data -isnot [hashtable]) { return $cache }
        if ([int]$data['Version'] -ne [int]$cache.Version) { return $cache }
        if (-not [string]::Equals([string]$data['Root'], $cache.Root, [System.StringComparison]::OrdinalIgnoreCase)) { return $cache }
        if ($data['Entries'] -isnot [hashtable]) { return $cache }
        foreach ($key in $data['Entries'].Keys) {
            $entry = $data['Entries'][$key]
            if ($entry -isnot [hashtable]) { continue }
            if (-not [string]$entry['RelativePath']) { continue }
            $cache.Entries[[string]$key] = @{
                Mtime        = [long]$entry['Mtime']
                Size         = [long]$entry['Size']
                RelativePath = [string]$entry['RelativePath']
                Synopsis     = [string]$entry['Synopsis']
                HelpBlock    = [string]$entry['HelpBlock']
                HelpStatus   = [string]$entry['HelpStatus']
                MissingSynopsis    = [bool]$entry['MissingSynopsis']
                MissingDescription = [bool]$entry['MissingDescription']
                MissingExample     = [bool]$entry['MissingExample']
                Undocumented       = [string[]]@($entry['Undocumented'])
                Warnings     = [int]$entry['Warnings']
            }
        }
    }
    catch {
        Write-Verbose "Cache ignored ($Path): $($_.Exception.Message)"
        return (New-CatalogCache -Root $Root)
    }
    $cache
}

function Save-CatalogCache {
    # Writes the cache through a temporary file: an interrupted write never leaves a truncated file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Cache)

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $data = [ordered]@{
        Version = [int]$Cache.Version
        Root    = [string]$Cache.Root
        Entries = $Cache.Entries
    }
    $json = ConvertTo-Json -InputObject $data -Depth 6
    $temporary = "$Path.tmp"
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
