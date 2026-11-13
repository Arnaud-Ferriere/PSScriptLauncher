# Interface language: one catalog per language, in Lang\<code>\*.psd1.
# Keys are flat and dotted ('window.status.ready'), so that several catalog files can be merged
# without nesting, and so that a missing translation is easy to spot.

function Get-AvailableLanguage {
    # Language codes shipped with the module.
    $folder = Join-Path $script:ModuleRoot 'Lang'
    @(Get-ChildItem -LiteralPath $folder -Directory | ForEach-Object { $_.Name } | Sort-Object)
}

function Import-UiText {
    # Merges every catalog file of a language into one flat table.
    param([Parameter(Mandatory)][string]$Language)

    $folder = Join-Path (Join-Path $script:ModuleRoot 'Lang') $Language
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Unknown language: $Language"
    }
    $text = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.psd1' | Sort-Object -Property Name)) {
        $part = Import-PowerShellDataFile -LiteralPath $file.FullName
        foreach ($key in $part.Keys) {
            if ($text.ContainsKey($key)) { throw "Duplicate string key '$key' in $($file.Name)." }
            $text[$key] = $part[$key]
        }
    }
    $text
}

function Resolve-UiLanguage {
    # Chosen language, then the saved preference, then the Windows UI language, then 'en'.
    # An explicit choice that does not exist is an error: a typo should not pass silently.
    param([string]$Language, [hashtable]$State)

    $available = Get-AvailableLanguage
    if ($Language) {
        if ($available -notcontains $Language) {
            throw ("Unknown language '{0}'. Available: {1}." -f $Language, ($available -join ', '))
        }
        return $Language
    }
    foreach ($candidate in @($(if ($State) { $State.Language }), [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName, 'en')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($available -contains $candidate) { return $candidate }
    }
    $available[0]
}

function Set-UiLanguage {
    # Loads the catalog of a language in the module scope.
    param([Parameter(Mandatory)][string]$Language)

    $script:Language = $Language
    $script:Text = Import-UiText -Language $Language
}

function Get-UiText {
    # String of the active catalog. -Arguments fills {0}, {1}... placeholders.
    # A missing key renders as <key>: visible in the window instead of an empty label.
    param([Parameter(Mandatory)][string]$Key, [object[]]$Arguments)

    $value = $script:Text[$Key]
    if ($null -eq $value) { return "<$Key>" }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        # Numbers follow the interface language, not the Windows regional settings
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($script:Language)
        return [string]::Format($culture, $value, $Arguments)
    }
    [string]$value
}

function Get-UiLanguageName {
    # Language name shown in the selector: an autonym, never translated.
    param([Parameter(Mandatory)][string]$Code)

    switch ($Code) {
        'en' { 'English' }
        'fr' { 'Français' }
        default { $Code }
    }
}

function Initialize-UiText {
    # Loads the catalog once, before anything else touches the interface: explicit -Language,
    # then the preference stored in the user state, then the Windows UI language.
    param([string]$Language, [string]$StatePath)

    if (-not $StatePath) { $StatePath = Get-DefaultStatePath }
    $state = Read-UserState -Path $StatePath
    Set-UiLanguage -Language (Resolve-UiLanguage -Language $Language -State $state)
}
