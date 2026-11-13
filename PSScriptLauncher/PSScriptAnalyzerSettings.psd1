# PSScriptAnalyzer settings of the module: Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    ExcludeRules = @(
        # Internal Set-/New-/Start-/Update-/Remove- functions only change the window, in-memory
        # objects or the user preference file: -WhatIf makes no sense there.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
