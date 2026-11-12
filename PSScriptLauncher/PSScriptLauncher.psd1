@{
    RootModule           = 'PSScriptLauncher.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '6f0d9a3e-5b1c-4e7a-9a52-3c8f2d7b4e10'
    Author               = 'Arnaud Ferrière'
    Copyright            = '(c) 2026 Arnaud Ferrière. Licence MIT.'
    Description          = 'Lanceur graphique (WPF) pour les scripts PowerShell d''un dossier, à partir de leur aide intégrée.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Show-PSScriptLauncher')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('WPF', 'GUI', 'Launcher', 'Show-Command', 'Windows')
            LicenseUri = 'https://github.com/Arnaud-Ferriere/PSScriptLauncher/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Arnaud-Ferriere/PSScriptLauncher'
        }
    }
    FileList             = @(
        'PSScriptLauncher.psd1'
        'PSScriptLauncher.psm1'
        'MainWindow.xaml'
        'Private\Settings.ps1'
        'Private\Analysis.ps1'
        'Private\Command.ps1'
        'Private\HelpText.ps1'
        'Private\UserState.ps1'
        'Private\Ui.Form.ps1'
        'Private\Ui.Window.ps1'
    )
}
