#Requires -Version 5.1

# Module du lanceur de scripts. Une seule commande publique : Show-ScriptLauncher.
# Les fichiers de Private ne contiennent que des fonctions (et les réglages) ; l'ordre de
# chargement ne compte que pour Settings.ps1, qui doit venir en premier.

# Toute erreur de cmdlet est bloquante dans le module : elle est interceptée et affichée, au
# lieu de passer inaperçue dans une console que le raccourci conseillé masque.
$ErrorActionPreference = 'Stop'

$privateFiles = 'Settings', 'Analysis', 'Command', 'HelpText', 'UserState', 'Ui.Form', 'Ui.Window'
foreach ($name in $privateFiles) {
    . (Join-Path (Join-Path $PSScriptRoot 'Private') "$name.ps1")
}

function Show-ScriptLauncher {
    <#
    .SYNOPSIS
        Ouvre le lanceur graphique de scripts PowerShell sur un dossier.

    .DESCRIPTION
        Parcourt le dossier et ses sous-dossiers, lit le bloc param() et l'aide de chaque script
        sans l'exécuter, et affiche une fenêtre qui permet de renseigner les paramètres et de
        lancer le script choisi dans une nouvelle console.

        Les favoris, les scripts récents et la dernière saisie de chaque script sont propres à
        l'utilisateur connecté : ils sont enregistrés dans son profil (%LOCALAPPDATA%), jamais
        dans le dossier des scripts.

    .PARAMETER Path
        Dossier racine à parcourir. Par défaut : le dossier courant.

    .PARAMETER ExcludePattern
        Motifs (caractères génériques) appliqués au chemin relatif et au nom des scripts à masquer.

    .PARAMETER StatePath
        Fichier d'état de l'utilisateur. Par défaut : %LOCALAPPDATA%\ScriptLauncher\state.json.

    .EXAMPLE
        Show-ScriptLauncher -Path C:\Scripts

    .INPUTS
        None.

    .OUTPUTS
        None. La commande rend la main à la fermeture de la fenêtre.
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Path = (Get-Location).ProviderPath,

        [SupportsWildcards()]
        [ValidateNotNull()]
        [string[]]$ExcludePattern = @('*.Tests.ps1'),

        [string]$StatePath
    )

    try {
        Assert-LauncherPrerequisite
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Dossier introuvable : $Path" }
        $root = (Resolve-Path -LiteralPath $Path).ProviderPath
        $script:Window = $null
        $script:State = New-LauncherState -Root $root -ExcludePattern $ExcludePattern -StatePath $StatePath
        Initialize-LauncherWindow
        [void]$script:Window.ShowDialog()
    }
    catch {
        $message = "Le lanceur n'a pas pu démarrer : $($_.Exception.Message)"
        # Message visible même si la console est masquée (raccourci -WindowStyle Hidden)
        try {
            Add-Type -AssemblyName PresentationFramework
            $script:Window = $null
            Show-ErrorDialog -Message $message
        }
        catch { Write-Warning 'Boîte de dialogue WPF indisponible.' }
        throw
    }
    finally {
        Stop-CatalogScan
    }
}

Export-ModuleMember -Function 'Show-ScriptLauncher'
