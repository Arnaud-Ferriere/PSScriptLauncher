# State specific to the logged-on user: favorites, recent scripts, last input per script.
# Everything is written to a JSON file of the user profile (%LOCALAPPDATA%), never to the
# scripts folder: nothing is shared with colleagues nor visible to them.

function Get-DefaultStatePath {
    # %LOCALAPPDATA%\PSScriptLauncher\state.json
    $folder = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'PSScriptLauncher'
    Join-Path $folder 'state.json'
}

function New-UserState {
    # Empty state.
    @{
        Version   = 1
        Language  = ''
        Theme     = 'auto'
        HighContrast = $false
        FontScale    = 1.0
        DyslexicFont = $false
        ReduceMotion = $false
        ThickFocus   = $false
        RoomyLayout  = $false
        Favorites = [System.Collections.Generic.List[string]]::new()
        Recents   = [System.Collections.Generic.List[string]]::new()
        RecentRoots = [System.Collections.Generic.List[string]]::new()
        Scripts   = @{}       # script key -> @{ ParameterSet; Values = @{ name = value }; LastUsed }
    }
}

function Get-ScriptStateKey {
    # Key of a script in the state: its full path, without regard to case.
    param([Parameter(Mandatory)][string]$Path)

    $Path.ToLowerInvariant()
}

function ConvertTo-PlainHashtable {
    # ConvertFrom-Json returns PSCustomObject (no -AsHashtable in Windows PowerShell 5.1):
    # recursive conversion into hashtables and arrays.
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [valuetype]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[[string]$key] = ConvertTo-PlainHashtable -InputObject $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @($InputObject | ForEach-Object { ConvertTo-PlainHashtable -InputObject $_ })
    }
    $table = @{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $table[$property.Name] = ConvertTo-PlainHashtable -InputObject $property.Value
    }
    $table
}

function Read-UserState {
    # Loads the state. File missing, unreadable or of an unexpected format: empty state (the
    # launcher must never refuse to start because of a lost preference).
    param([Parameter(Mandatory)][string]$Path)

    $state = New-UserState
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $data = ConvertTo-PlainHashtable -InputObject ($json | ConvertFrom-Json)
        if ($data -isnot [hashtable]) { return $state }
        $state.Language = [string]$data['Language']
        if ($data['Theme']) { $state.Theme = [string]$data['Theme'] }
        $state.HighContrast = [bool]$data['HighContrast']
        $state.DyslexicFont = [bool]$data['DyslexicFont']
        $state.ReduceMotion = [bool]$data['ReduceMotion']
        $state.ThickFocus = [bool]$data['ThickFocus']
        $state.RoomyLayout = [bool]$data['RoomyLayout']
        # The file is written by ConvertTo-Json, which always uses the invariant culture: parsing
        # with the current one would read 1.3 as 13 in a French session, or refuse it.
        $scale = 0.0
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $numberStyle = [System.Globalization.NumberStyles]::Float
        if ([double]::TryParse([string]$data['FontScale'], $numberStyle, $invariant, [ref]$scale) -and
            $scale -ge 1 -and $scale -le 2) {
            $state.FontScale = $scale
        }
        foreach ($item in @($data['RecentRoots'])) { if ($item -is [string] -and $item) { $state.RecentRoots.Add($item) } }
        foreach ($item in @($data['Favorites'])) { if ($item -is [string] -and $item) { $state.Favorites.Add($item) } }
        foreach ($item in @($data['Recents'])) { if ($item -is [string] -and $item) { $state.Recents.Add($item) } }
        if ($data['Scripts'] -is [hashtable]) {
            foreach ($key in $data['Scripts'].Keys) {
                $entry = $data['Scripts'][$key]
                if ($entry -isnot [hashtable]) { continue }
                $values = if ($entry['Values'] -is [hashtable]) { $entry['Values'] } else { @{} }
                $state.Scripts[$key] = @{
                    ParameterSet = [string]$entry['ParameterSet']
                    Values       = $values
                    LastUsed     = [string]$entry['LastUsed']
                }
            }
        }
    }
    catch {
        Write-Verbose "Unreadable user state, ignored ($Path): $($_.Exception.Message)"
        return (New-UserState)
    }
    $state
}

function Copy-JsonReadyValue {
    # "Clean" copy of a value before ConvertTo-Json. In Windows PowerShell 5.1, an array wrapped
    # in a PSObject (returned by a function, for example) is serialized as
    # { "value": [...], "Count": n }: arrays and tables are therefore rebuilt.
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return [string]$InputObject }
    if ($InputObject -is [bool]) { return [bool]$InputObject }
    if ($InputObject -is [valuetype]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($InputObject.Keys | Sort-Object)) {
            $copy[[string]$key] = Copy-JsonReadyValue -InputObject $InputObject[$key]
        }
        return $copy
    }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $InputObject) { $list.Add((Copy-JsonReadyValue -InputObject $item)) }
    , $list.ToArray()
}

function Remove-PathFromList {
    # Removes a path from a list, without regard to case.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory)][string]$Path
    )

    for ($i = $List.Count - 1; $i -ge 0; $i--) {
        if ([string]::Equals($List[$i], $Path, [System.StringComparison]::OrdinalIgnoreCase)) { $List.RemoveAt($i) }
    }
}

function Save-UserState {
    # Writes the state. Write to a temporary file then replace: a stop in the middle of the
    # write does not leave a truncated file.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $data = [ordered]@{
        Version   = 1
        Language  = [string]$State.Language
        Theme     = [string]$State.Theme
        HighContrast = [bool]$State.HighContrast
        FontScale    = [double]$State.FontScale
        DyslexicFont = [bool]$State.DyslexicFont
        ReduceMotion = [bool]$State.ReduceMotion
        ThickFocus   = [bool]$State.ThickFocus
        RoomyLayout  = [bool]$State.RoomyLayout
        RecentRoots = $State.RecentRoots.ToArray()
        Favorites = $State.Favorites.ToArray()
        Recents   = $State.Recents.ToArray()
        Scripts   = Copy-JsonReadyValue -InputObject $State.Scripts
    }
    $json = ConvertTo-Json -InputObject $data -Depth 8
    $temporary = "$Path.tmp"
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Test-SensitiveParameterName {
    # Parameters whose value must not be kept on disk, even when typed in clear text.
    param([Parameter(Mandatory)][string]$Name)

    $Name -match '(?i)pass(word|wd|phrase)?|pwd|secret|token|credential|api_?key|access_?key|private_?key|client_?key'
}

function ConvertTo-StoredValue {
    # Value of a form row -> storable value ($null: nothing to keep).
    param([Parameter(Mandatory)]$Parameter, $Value)

    # The "ask at launch" check boxes (Credential, SecureString) hold no secret; on the other
    # hand, a value typed in clear text is not kept if the parameter name suggests a secret.
    $isFreeText = $Parameter.Kind -notin 'Switch', 'Bool', 'Choice', 'MultiChoice', 'Credential', 'SecureString'
    if ($isFreeText -and (Test-SensitiveParameterName -Name $Parameter.Name)) { return $null }
    switch ($Parameter.Kind) {
        { $_ -in 'Switch', 'SecureString' } {
            if ($Value -eq $true) { return $true }
            return $null
        }
        'Credential' {
            # Only "ask at launch" and the user name are kept: never a password
            if ($Value -and $Value.Prompt) { return @{ Prompt = $true; UserName = [string]$Value.UserName } }
            return $null
        }
        { $_ -in 'MultiChoice', 'TextArray' } {
            $items = @(
                @($Value) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { [string]$_ }
            )
            if ($items.Count -gt 0) { return , $items }
            return $null
        }
        default {
            if ([string]::IsNullOrEmpty([string]$Value)) { return $null }
            return [string]$Value
        }
    }
}

function Add-RecentRoot {
    # Puts a folder at the head of the recent folders, without duplicates and with a hard limit.
    # Returns $true when the list changed.
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Path
    )

    $root = $Path.TrimEnd('\', '/')
    if (-not $root) { return $false }
    $existing = @($State.RecentRoots)
    if ($existing.Count -gt 0 -and
        [string]::Equals($existing[0], $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    Remove-PathFromList -List $State.RecentRoots -Path $root
    $State.RecentRoots.Insert(0, $root)
    while ($State.RecentRoots.Count -gt $script:Settings.MaxRecentRoots) {
        $State.RecentRoots.RemoveAt($State.RecentRoots.Count - 1)
    }
    $true
}

function Set-RememberedInput {
    # Remembers the input of a script (parameter set + non-sensitive values) and puts it at
    # the top of the recent scripts. Modifies $State; the caller saves.
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$ParameterSet,
        [hashtable]$Values = @{}
    )

    $key = Get-ScriptStateKey -Path $ScriptPath
    $State.Scripts[$key] = @{
        ParameterSet = $ParameterSet
        Values       = $Values
        LastUsed     = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $max = $script:Settings.MaxRememberedScript
    if ($State.Scripts.Count -gt $max) {
        $oldest = $State.Scripts.GetEnumerator() |
            Sort-Object -Property { $_.Value.LastUsed } |
            Select-Object -First ($State.Scripts.Count - $max)
        foreach ($entry in @($oldest)) { $State.Scripts.Remove($entry.Key) }
    }

    Remove-PathFromList -List $State.Recents -Path $ScriptPath
    $State.Recents.Insert(0, $ScriptPath)
    while ($State.Recents.Count -gt $script:Settings.MaxRecent) { $State.Recents.RemoveAt($State.Recents.Count - 1) }
}

function Get-RememberedInput {
    # Last input remembered for a script, or $null.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    $State.Scripts[(Get-ScriptStateKey -Path $ScriptPath)]
}

function Remove-RememberedInput {
    # Forgets the input remembered for a script.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    $State.Scripts.Remove((Get-ScriptStateKey -Path $ScriptPath))
}

function Test-FavoriteScript {
    # True if the script is a favorite.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    foreach ($item in $State.Favorites) {
        if ([string]::Equals($item, $ScriptPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Switch-FavoriteScript {
    # Adds the script to the favorites, or removes it. Returns $true if it is a favorite after the call.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    if (Test-FavoriteScript -State $State -ScriptPath $ScriptPath) {
        Remove-PathFromList -List $State.Favorites -Path $ScriptPath
        return $false
    }
    $State.Favorites.Add($ScriptPath)
    $true
}
