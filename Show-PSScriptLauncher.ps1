#Requires -Version 5.1

<#
.SYNOPSIS
    Graphical interface (in the spirit of Show-Command) to run the PowerShell scripts of this
    folder and its subfolders, from the help each script already contains.

.DESCRIPTION
    Entry point: loads the PSScriptLauncher module (sibling folder) and opens the window on the
    requested folder.

    For every .ps1 script, the launcher reads the param() block and the comment-based help through
    syntax analysis (AST): scripts are never executed while being read. The inventory runs in the
    background, so the window stays usable.

    Left: favorites, recent scripts, the tree and a search (name, folder, synopsis; case- and
    accent-insensitive). Right: a form generated from the parameters (parameter sets, mandatory
    fields, ValidateSet and enums as lists, ValidateRange and ValidatePattern checked while
    typing, File/Folder buttons for paths), filling from an .EXAMPLE, the full help, and the
    generated command, which can be copied or run in a new console.

    Help reading follows the Get-Help rules, with two deliberate tolerances:
    - a parameter type unknown to the session (type from a module that is not loaded) does not
      prevent reading, whereas it makes Get-Help fail;
    - a help block at the top of a script that Get-Help ignores for a formatting reason (missing
      blank line after #Requires, help placed after using...) is still displayed, with a warning
      telling what to fix.

    Value entry:
    - dates and numbers are interpreted in the user's culture (11/09/2026, 3.5) then rewritten in
      the invariant format (2026-11-09, 3.5);
    - PSCredential and SecureString never travel in clear text: the generated command calls
      Get-Credential or Read-Host -AsSecureString in the launched console.

    Personal data: favorites, recent scripts and the last input run of each script are stored in
    the profile of the logged-on user (%LOCALAPPDATA%\PSScriptLauncher), never in the scripts
    folder. Values of parameters whose name suggests a secret (password, token, secret, key...)
    are not kept.

    The analyzed folder is the one holding this script, or the one given to -Path. It is shown
    under the search box and can be changed while the window is open (Folder... button, Ctrl+O):
    the inventory starts again without restarting anything.

    Shortcuts: Ctrl+O (folder), Ctrl+F (search), F5 (refresh), Ctrl+Enter (run).

.PARAMETER Path
    Root folder to scan. Default: the last folder opened, or the folder holding this launcher.

.PARAMETER ExcludePattern
    Wildcard patterns applied to the relative path and to the script name to hide. Default: the
    Pester test files (*.Tests.ps1). The PSScriptLauncher folder (the launcher itself) is always
    ignored.

.PARAMETER StatePath
    User state file (favorites, recents, inputs). Default:
    %LOCALAPPDATA%\PSScriptLauncher\state.json.

.PARAMETER Language
    Interface language ('en', 'fr'). Default: the saved preference, then the Windows UI language.

.EXAMPLE
    .\Show-PSScriptLauncher.ps1

    Opens the launcher on the folder holding this script.

.EXAMPLE
    .\Show-PSScriptLauncher.ps1 -ExcludePattern '*.Tests.ps1', 'Lib\*', '*\_Archives\*'

    Also hides dot-sourced libraries and archives.

.EXAMPLE
    .\Show-PSScriptLauncher.ps1 -Path D:\Scripts -Language fr

    Opens another folder, with a French interface.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    None. This script opens a window and returns no object.

.NOTES
    Version: 1.0.0 (2026-11-13)

    Requirements: Windows, Windows PowerShell 5.1 or PowerShell 7+, STA session (default in both
    consoles) and FullLanguage language mode (WPF cannot be used in ConstrainedLanguage). The
    PSScriptLauncher folder must sit next to this script.

    Recommended shortcut, which hides the launcher console:
        powershell.exe -NoProfile -WindowStyle Hidden -File "<folder>\Show-PSScriptLauncher.ps1"

    Each script runs in its own process (a new console): an exit, an error or a Read-Host in a
    script does not affect the launcher.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [SupportsWildcards()]
    [ValidateNotNull()]
    [string[]]$ExcludePattern = @('*.Tests.ps1'),

    [string]$StatePath,

    [string]$Language
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path (Join-Path $PSScriptRoot 'PSScriptLauncher') 'PSScriptLauncher.psd1'
try {
    Import-Module -Name $manifest -Force
}
catch {
    $message = "The launcher module could not be loaded ($manifest): $($_.Exception.Message)"
    # Visible even when the console is hidden (-WindowStyle Hidden shortcut)
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($message, 'Script launcher',
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
    catch { Write-Warning 'WPF dialog unavailable.' }
    throw
}

$launcherParameters = @{ ExcludePattern = $ExcludePattern }
if ($Path) { $launcherParameters['Path'] = $Path }
if ($StatePath) { $launcherParameters['StatePath'] = $StatePath }
if ($Language) { $launcherParameters['Language'] = $Language }
Show-PSScriptLauncher @launcherParameters
