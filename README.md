# ScriptLauncher

Interface graphique pour lancer les scripts PowerShell d'un dossier, à la manière de
`Show-Command`, en s'appuyant sur ce qui existe déjà dans chaque script : le bloc `param()`
et l'aide comment-based. Aucune configuration à écrire, aucun serveur à installer.

<!-- Capture d'écran : docs/screenshot.png -->

## Fonctionnalités

- **Inventaire automatique** du dossier et de ses sous-dossiers, en arrière-plan. Les scripts
  sont lus par analyse syntaxique (AST) : **ils ne sont jamais exécutés pendant la lecture**.
- **Formulaire généré** depuis `param()` :
  - jeux de paramètres, champs obligatoires, alias, valeurs par défaut ;
  - `ValidateSet` et enums en listes, choix multiples pour les tableaux ;
  - `ValidateRange` et `ValidatePattern` vérifiés à la saisie ;
  - boutons « Fichier... » / « Dossier... » pour les paramètres `*Path`, `*File`, `*Folder` ;
  - `PSCredential` et `SecureString` demandés au lancement, jamais transmis en clair.
- **Aide intégrée** : synopsis et description en tête, aide complète façon `Get-Help -Full`.
  Les descriptions écrites en commentaire dans `param()` sont reprises, comme le fait `Get-Help`.
- **Remplissage depuis un `.EXAMPLE`** : un clic sur un exemple de l'aide remplit le formulaire.
- **Favoris, scripts récents et dernière saisie** de chaque script, propres à l'utilisateur.
- **Recherche** par nom, dossier ou synopsis, insensible à la casse et aux accents.
- **Lancement dans une nouvelle console** (Windows PowerShell 5.1 ou PowerShell 7, choisi
  d'après `#Requires`), en administrateur si besoin. La commande générée peut aussi être copiée.
- **Diagnostic de l'aide** : un bloc d'aide que `Get-Help` ignore pour une question de mise en
  forme (ligne vide manquante après `#Requires`, aide placée après `using`...) est quand même
  affiché, avec un avertissement qui indique la correction.

## Prérequis

- Windows, avec Windows PowerShell 5.1 ou PowerShell 7+.
- Session STA (le défaut des deux consoles) et mode de langage `FullLanguage` (WPF n'est pas
  utilisable en `ConstrainedLanguage`, par exemple sous une stratégie AppLocker ou WDAC stricte).

## Installation

1. Copier `Show-ScriptLauncher.ps1` et le dossier `ScriptLauncher` à la racine du dossier de
   scripts à présenter.
2. Si les fichiers viennent d'un téléchargement, les débloquer :

   ```powershell
   Get-ChildItem -Recurse -File | Unblock-File
   ```

3. Si l'exécution de scripts est désactivée (stratégie `Restricted`, le défaut sur un poste
   client), autoriser au moins la session :

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Show-ScriptLauncher.ps1
   ```

   Pour un usage durable : `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Utilisation

```powershell
.\Show-ScriptLauncher.ps1                                  # dossier du lanceur
.\Show-ScriptLauncher.ps1 -Path D:\Scripts                 # autre dossier
.\Show-ScriptLauncher.ps1 -ExcludePattern '*.Tests.ps1', 'Lib\*'
```

Raccourci conseillé, qui masque la console du lanceur :

```text
powershell.exe -NoProfile -WindowStyle Hidden -File "<dossier>\Show-ScriptLauncher.ps1"
```

Raccourcis clavier : `Ctrl+F` (recherche), `F5` (actualiser), `Ctrl+Entrée` (lancer).

## Données enregistrées

Les favoris, les scripts récents et la dernière saisie lancée de chaque script sont écrits dans
`%LOCALAPPDATA%\ScriptLauncher\state.json`, c'est-à-dire dans le profil de l'utilisateur
connecté. Rien n'est écrit dans le dossier des scripts : sur un dossier partagé, chacun garde
ses propres préférences.

Ne sont jamais conservés : les mots de passe et identifiants (`PSCredential`, `SecureString`),
ni les valeurs des paramètres dont le nom évoque un secret (`Password`, `Token`, `Secret`,
`ApiKey`...).

## Écrire des scripts qui s'affichent bien

Le lanceur suit les règles de `Get-Help`. Quelques points qui font la différence :

```powershell
#Requires -Version 5.1

<#
.SYNOPSIS
    Une phrase : elle apparaît dans l'arborescence et en tête du formulaire.
.DESCRIPTION
    Le détail, affiché sous le synopsis.
.PARAMETER UserPrincipalName
    Décrit le paramètre (une ligne de commentaire juste avant le paramètre fonctionne aussi).
.EXAMPLE
    .\Set-Something.ps1 -UserPrincipalName user@contoso.com -Level 3

    Les exemples qui appellent le script peuvent remplir le formulaire en un clic.
#>
[CmdletBinding(SupportsShouldProcess)]       # -WhatIf et -Verbose proposés dans le formulaire
param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [ValidateRange(1, 5)]
    [int]$Level = 1,

    [ValidateSet('Standard', 'Admin')]
    [string]$Profile = 'Standard'
)
```

- Laisser **une ligne vide** entre `#Requires` (ou tout autre commentaire) et le bloc d'aide.
- Placer le bloc d'aide **avant** les instructions `using`.
- Si le script commence par une fonction, laisser **deux lignes vides** entre l'aide et la
  fonction, sinon `Get-Help` attribue l'aide à la fonction.

## Développement

```text
Show-ScriptLauncher.ps1          point d'entrée
ScriptLauncher/
  ScriptLauncher.psd1 / .psm1    module (une commande publique : Show-ScriptLauncher)
  MainWindow.xaml                fenêtre WPF
  Private/
    Settings.ps1                 réglages
    Analysis.ps1                 lecture des scripts par AST (sans WPF)
    Command.ps1                  conversion des valeurs, validation, lancement
    HelpText.ps1                 mise en forme de l'aide
    UserState.ps1                favoris, récents, saisies
    Ui.Form.ps1 / Ui.Window.ps1  formulaire et fenêtre
  Tests/                         tests Pester (hors interface)
```

Tests (Pester 5.2 ou plus récent ; Windows PowerShell 5.1 est livré avec Pester 3) :

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\ScriptLauncher\Tests
```

Analyse statique :

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptLauncher\PSScriptAnalyzerSettings.psd1
```

Les fichiers sont en UTF-8 avec BOM et fins de ligne CRLF (`.gitattributes`), indispensable
pour que Windows PowerShell 5.1 lise correctement les accents.

## Limites connues

- Les paramètres dynamiques (`DynamicParam`) ne sont pas affichés.
- `ValidateLength`, `ValidateCount` et `ValidateScript` ne sont pas vérifiés dans le formulaire.
- La dernière saisie retenue est celle du dernier **lancement**.

## Outils proches

- [`Show-Command`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/show-command) :
  intégré à PowerShell, une commande à la fois, sans navigation dans un dossier.
- [ScriptRunner](https://www.scriptrunner.com/) et
  [PowerShell Universal](https://ironmansoftware.com/powershell-universal) : plateformes web
  avec serveur, délégation, droits et audit. Plus adaptées pour confier des scripts à des
  utilisateurs non administrateurs.
- [PSScriptMenuGui](https://github.com/dan-osull/PowerShell-Script-Menu-Gui) : menu de boutons
  décrit dans un CSV, arguments fixes.

## Licence

[MIT](LICENSE).
