# État propre à l'utilisateur connecté : favoris, scripts récents, dernière saisie par script.
# Tout est écrit dans un fichier JSON de son profil (%LOCALAPPDATA%), jamais dans le dossier
# des scripts : rien n'est partagé avec les collègues ni visible par eux.

function Get-DefaultStatePath {
    # %LOCALAPPDATA%\PSScriptLauncher\state.json
    $folder = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'PSScriptLauncher'
    Join-Path $folder 'state.json'
}

function New-UserState {
    # État vide.
    @{
        Version   = 1
        Favorites = [System.Collections.Generic.List[string]]::new()
        Recents   = [System.Collections.Generic.List[string]]::new()
        Scripts   = @{}       # clé de script -> @{ ParameterSet; Values = @{ nom = valeur }; LastUsed }
    }
}

function Get-ScriptStateKey {
    # Clé d'un script dans l'état : son chemin complet, sans distinction de casse.
    param([Parameter(Mandatory)][string]$Path)

    $Path.ToLowerInvariant()
}

function ConvertTo-PlainHashtable {
    # ConvertFrom-Json renvoie des PSCustomObject (pas de -AsHashtable en Windows PowerShell 5.1) :
    # conversion récursive en tables de hachage et tableaux.
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
    # Charge l'état. Fichier absent, illisible ou d'un format inattendu : état vide (le lanceur
    # ne doit jamais refuser de démarrer pour une préférence perdue).
    param([Parameter(Mandatory)][string]$Path)

    $state = New-UserState
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $data = ConvertTo-PlainHashtable -InputObject ($json | ConvertFrom-Json)
        if ($data -isnot [hashtable]) { return $state }
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
        Write-Verbose "État utilisateur illisible, ignoré ($Path) : $($_.Exception.Message)"
        return (New-UserState)
    }
    $state
}

function Copy-JsonReadyValue {
    # Copie « propre » d'une valeur avant ConvertTo-Json. En Windows PowerShell 5.1, un tableau
    # enveloppé dans un PSObject (renvoyé par une fonction, par exemple) est sérialisé sous la
    # forme { "value": [...], "Count": n } : on reconstruit donc tableaux et tables.
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
    # Retire un chemin d'une liste, sans distinction de casse.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory)][string]$Path
    )

    for ($i = $List.Count - 1; $i -ge 0; $i--) {
        if ([string]::Equals($List[$i], $Path, [System.StringComparison]::OrdinalIgnoreCase)) { $List.RemoveAt($i) }
    }
}

function Save-UserState {
    # Écrit l'état. Écriture dans un fichier temporaire puis remplacement : un arrêt en cours
    # d'écriture ne laisse pas un fichier tronqué.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $data = [ordered]@{
        Version   = 1
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
    # Paramètres dont la valeur ne doit pas être conservée sur disque, même saisie en clair.
    param([Parameter(Mandatory)][string]$Name)

    $Name -match '(?i)pass(word|wd|phrase)?|pwd|secret|token|credential|api_?key|access_?key|private_?key|client_?key'
}

function ConvertTo-StoredValue {
    # Valeur d'une ligne du formulaire -> valeur enregistrable ($null : rien à conserver).
    param([Parameter(Mandatory)]$Parameter, $Value)

    # Les cases « demander au lancement » (Credential, SecureString) ne contiennent aucun secret ;
    # en revanche une valeur saisie en clair n'est pas conservée si le nom du paramètre évoque un secret.
    $isFreeText = $Parameter.Kind -notin 'Switch', 'Bool', 'Choice', 'MultiChoice', 'Credential', 'SecureString'
    if ($isFreeText -and (Test-SensitiveParameterName -Name $Parameter.Name)) { return $null }
    switch ($Parameter.Kind) {
        { $_ -in 'Switch', 'SecureString' } {
            if ($Value -eq $true) { return $true }
            return $null
        }
        'Credential' {
            # On retient seulement « demander au lancement » et le nom d'utilisateur : jamais de mot de passe
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

function Set-RememberedInput {
    # Retient la saisie d'un script (jeu de paramètres + valeurs non sensibles) et le place en
    # tête des scripts récents. Modifie $State ; l'appelant enregistre.
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
    # Dernière saisie retenue pour un script, ou $null.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    $State.Scripts[(Get-ScriptStateKey -Path $ScriptPath)]
}

function Remove-RememberedInput {
    # Oublie la saisie retenue pour un script.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    $State.Scripts.Remove((Get-ScriptStateKey -Path $ScriptPath))
}

function Test-FavoriteScript {
    # Vrai si le script est dans les favoris.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    foreach ($item in $State.Favorites) {
        if ([string]::Equals($item, $ScriptPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Switch-FavoriteScript {
    # Ajoute le script aux favoris, ou l'en retire. Renvoie $true s'il est favori après l'appel.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ScriptPath)

    if (Test-FavoriteScript -State $State -ScriptPath $ScriptPath) {
        Remove-PathFromList -List $State.Favorites -Path $ScriptPath
        return $false
    }
    $State.Favorites.Add($ScriptPath)
    $true
}
