# Launcher settings. Loaded first: the other files read $script:Settings.

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot

# Interface language and string catalog, filled at startup by Initialize-UiText (Private\Text.ps1).
$script:Language = 'en'
$script:Text = @{}

$script:Settings = @{
    AutoExpandLimit      = 40        # above this number of scripts, the tree opens collapsed
    SearchDelayMs        = 250       # debounce for the search while typing
    ScanPollMs           = 150       # polling interval for the inventory progress
    MaxParseErrorShown   = 3         # detailed syntax errors per script
    MaxEchoLength        = 600       # above this, the command echoed in the console is shortened
    MaxCommandLineLength = 32000     # Windows refuses a command line longer than 32,767 characters
    MaxRecent            = 8         # scripts kept in "Recents"
    MaxRecentRoots       = 6         # folders kept in "Recent folders"
    MaxRememberedScript  = 300       # scripts whose last input is kept
    MaxExampleLabel      = 90        # length of an example label in the list
    CacheVersion         = 6         # bumped when the cached fields change (invalidates old caches)
}
