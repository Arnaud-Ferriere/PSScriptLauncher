#Requires -Version 5.1

<#
.SYNOPSIS
    Interface graphique (façon Show-Command) pour lancer les scripts PowerShell de ce dossier
    et de ses sous-dossiers, à partir de l'aide intégrée à chaque script.

.DESCRIPTION
    Point d'entrée du lanceur : charge le module PSScriptLauncher (dossier voisin) et ouvre
    la fenêtre sur le dossier indiqué.

    Le lanceur lit, pour chaque script .ps1, le bloc param() et l'aide comment-based par analyse
    syntaxique (AST) : les scripts ne sont jamais exécutés pendant la lecture. L'inventaire se
    fait en arrière-plan, la fenêtre reste utilisable.

    À gauche : mes favoris, mes scripts récents, l'arborescence et une recherche (nom, dossier,
    synopsis ; insensible à la casse et aux accents). À droite : un formulaire généré à partir
    des paramètres (jeux de paramètres, champs obligatoires, ValidateSet et enums en listes,
    ValidateRange et ValidatePattern vérifiés à la saisie, boutons Fichier/Dossier pour les
    chemins), le remplissage depuis un .EXAMPLE, l'aide complète, et la commande générée, que
    l'on peut copier ou lancer dans une nouvelle console.

    Lecture de l'aide : mêmes règles que Get-Help, avec deux tolérances voulues :
    - un type de paramètre inconnu de la session (type d'un module non chargé) n'empêche pas
      la lecture, alors qu'il fait échouer Get-Help ;
    - un bloc d'aide en tête de script que Get-Help ignore pour une question de mise en forme
      (ligne vide manquante après #Requires, aide placée après using...) est quand même
      affiché, avec un avertissement qui indique la correction à faire.

    Saisie des valeurs :
    - les dates et les nombres sont interprétés selon la culture de l'utilisateur (09/11/2026,
      3,5) puis réécrits au format invariant (2026-11-09, 3.5) ;
    - PSCredential et SecureString ne transitent jamais en clair : la commande générée appelle
      Get-Credential ou Read-Host -AsSecureString dans la console lancée.

    Données personnelles : favoris, scripts récents et dernière saisie lancée de chaque script
    sont enregistrés dans le profil de l'utilisateur connecté
    (%LOCALAPPDATA%\PSScriptLauncher), jamais dans le dossier des scripts. Les valeurs des
    paramètres dont le nom évoque un secret (password, token, secret, key...) ne sont pas
    conservées.

    Le dossier analysé est celui de ce script, ou celui de -Path. Il peut être changé en cours
    d'utilisation (bouton « Dossier... », Ctrl+O) : l'inventaire est relancé sans redémarrer.

    Raccourcis : Ctrl+O (dossier), Ctrl+F (recherche), F5 (actualiser), Ctrl+Entrée (lancer).

.PARAMETER Path
    Dossier racine à parcourir. Par défaut : le dossier qui contient ce lanceur.

.PARAMETER ExcludePattern
    Motifs (caractères génériques) appliqués au chemin relatif et au nom des scripts à masquer.
    Par défaut : les fichiers de tests Pester (*.Tests.ps1). Le dossier PSScriptLauncher (le
    lanceur lui-même) est toujours ignoré.

.PARAMETER StatePath
    Fichier d'état de l'utilisateur (favoris, récents, saisies). Par défaut :
    %LOCALAPPDATA%\PSScriptLauncher\state.json.

.EXAMPLE
    .\Show-PSScriptLauncher.ps1

    Ouvre le lanceur sur le dossier qui contient ce script.

.EXAMPLE
    .\Show-PSScriptLauncher.ps1 -ExcludePattern '*.Tests.ps1', 'Lib\*', '*\_Archives\*'

    Masque aussi les bibliothèques dot-sourcées et les archives.

.INPUTS
    None. Ce script n'accepte pas d'entrée par le pipeline.

.OUTPUTS
    None. Ce script ouvre une fenêtre et ne renvoie aucun objet.

.NOTES
    Version : 2.0.0 (2026-11-10)

    Prérequis : Windows, Windows PowerShell 5.1 ou PowerShell 7+, session STA (défaut des deux
    consoles) et mode de langage FullLanguage (WPF n'est pas utilisable en ConstrainedLanguage).
    Le dossier PSScriptLauncher doit se trouver à côté de ce script.

    Raccourci conseillé, qui masque la console du lanceur :
        powershell.exe -NoProfile -WindowStyle Hidden -File "<dossier>\Show-PSScriptLauncher.ps1"

    Chaque script est lancé dans son propre processus (nouvelle console) : un exit, une erreur
    ou un Read-Host dans un script n'affecte pas le lanceur.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [SupportsWildcards()]
    [ValidateNotNull()]
    [string[]]$ExcludePattern = @('*.Tests.ps1'),

    [string]$StatePath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $PSScriptRoot }

$manifest = Join-Path (Join-Path $PSScriptRoot 'PSScriptLauncher') 'PSScriptLauncher.psd1'
try {
    Import-Module -Name $manifest -Force
}
catch {
    $message = "Le module du lanceur n'a pas pu être chargé ($manifest) : $($_.Exception.Message)"
    # Message visible même si la console est masquée (raccourci -WindowStyle Hidden)
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($message, 'Lanceur de scripts',
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
    catch { Write-Warning 'Boîte de dialogue WPF indisponible.' }
    throw
}

$launcherParameters = @{ Path = $Path; ExcludePattern = $ExcludePattern }
if ($StatePath) { $launcherParameters['StatePath'] = $StatePath }
Show-PSScriptLauncher @launcherParameters
