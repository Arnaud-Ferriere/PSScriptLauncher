#Requires -Version 5.1

# Script launcher module. One public command: Show-PSScriptLauncher.
# Files in Private only hold functions (and settings); loading order matters only for
# Settings.ps1 and Text.ps1, which must come first.

# Any cmdlet error is terminating inside the module: it is caught and displayed, instead of
# going unnoticed in a console that the recommended shortcut hides.
$ErrorActionPreference = 'Stop'

$privateFiles = 'Settings', 'Text', 'Analysis', 'Command', 'HelpText', 'UserState', 'Cache', 'Theme', 'Ui.Form', 'Ui.Window', 'Ui.Report', 'Ui.Shortcuts'
foreach ($name in $privateFiles) {
    . (Join-Path (Join-Path $PSScriptRoot 'Private') "$name.ps1")
}

function Show-PSScriptLauncher {
    <#
    .SYNOPSIS
        Opens the graphical launcher for the PowerShell scripts of a folder.

    .DESCRIPTION
        Scans the folder and its subfolders, reads the param() block and the comment-based help of
        each script without running it, and shows a window where the parameters can be filled in
        and the chosen script launched in a new console.

        Favorites, recent scripts and the last input of each script belong to the logged-on user:
        they are stored in the profile (%LOCALAPPDATA%), never in the scripts folder.

        The interface is available in several languages; the catalog of strings lives in
        Lang\<code>. The language can be changed from the window, and is remembered.

    .PARAMETER Path
        Root folder to scan. Default: the last folder opened, or the folder holding the launcher.
        An explicit value always wins and is never replaced by a remembered one.

    .PARAMETER ExcludePattern
        Wildcard patterns applied to the relative path and to the script name to hide.

    .PARAMETER StatePath
        User state file. Default: %LOCALAPPDATA%\PSScriptLauncher\state.json.

    .PARAMETER Language
        Interface language code ('en', 'fr'). Default: the saved preference, then the Windows UI
        language.

    .EXAMPLE
        Show-PSScriptLauncher -Path C:\Scripts

        Opens the launcher on C:\Scripts.

    .EXAMPLE
        Show-PSScriptLauncher -Path C:\Scripts -Language fr

        Opens the launcher in French.

    .INPUTS
        None.

    .OUTPUTS
        None. The command returns when the window is closed.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,

        [SupportsWildcards()]
        [ValidateNotNull()]
        [string[]]$ExcludePattern = @('*.Tests.ps1'),

        [string]$StatePath,

        [string]$Language
    )

    try {
        Assert-LauncherPrerequisite
        Initialize-UiText -Language $Language -StatePath $StatePath
        if (-not $Path) { $Path = Get-DefaultRoot -StatePath $StatePath }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw (Get-UiText 'window.error.folderNotFound' -Arguments @($Path))
        }
        $root = (Resolve-Path -LiteralPath $Path).ProviderPath
        $script:Window = $null
        $script:State = New-LauncherState -Root $root -ExcludePattern $ExcludePattern -StatePath $StatePath
        Initialize-LauncherWindow
        [void]$script:Window.ShowDialog()
    }
    catch {
        $message = Get-UiText 'window.error.startup' -Arguments @($_.Exception.Message)
        # Message visible even if the console is hidden (shortcut -WindowStyle Hidden)
        try {
            Add-Type -AssemblyName PresentationFramework
            $script:Window = $null
            Show-ErrorDialog -Message $message
        }
        catch { Write-Warning 'WPF dialog unavailable.' }
        throw
    }
    finally {
        Stop-CatalogScan
    }
}

function Get-DefaultRoot {
    # Folder opened when -Path is not given: the most recent folder that still exists, else the
    # folder holding the launcher. When a remembered folder disappeared, the status bar says so.
    param([string]$StatePath)

    $launcherRoot = Split-Path -Parent $script:ModuleRoot
    if (-not $StatePath) { $StatePath = Get-DefaultStatePath }
    $state = Read-UserState -Path $StatePath
    $recent = @($state.RecentRoots)
    foreach ($candidate in $recent) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { return $candidate }
    }
    if ($recent.Count -gt 0) {
        # Something was remembered but nothing is reachable any more
        $script:StartupNotice = 'window.status.lastRootMissing'
    }
    $launcherRoot
}

Export-ModuleMember -Function 'Show-PSScriptLauncher'
