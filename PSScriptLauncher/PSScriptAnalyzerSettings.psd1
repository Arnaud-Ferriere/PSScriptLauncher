# Réglages PSScriptAnalyzer du module : Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        # Les fonctions internes en Set-/New-/Start-/Update-/Remove- ne modifient que la fenêtre,
        # des objets en mémoire ou le fichier de préférences de l'utilisateur : -WhatIf n'y a pas de sens.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
