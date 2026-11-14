@{
    RootModule           = 'PSScriptLauncher.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = '6f0d9a3e-5b1c-4e7a-9a52-3c8f2d7b4e10'
    Author               = 'Arnaud Ferrière'
    Copyright            = '(c) 2026 Arnaud Ferrière. MIT license.'
    Description          = 'Graphical launcher (WPF) for the PowerShell scripts of a folder, based on their built-in help.'
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
        'HelpReportWindow.xaml'
    'ShortcutsWindow.xaml'
    'Theme.xaml'
        'Private\Settings.ps1'
        'Private\Text.ps1'
        'Private\Analysis.ps1'
        'Private\Command.ps1'
        'Private\HelpText.ps1'
        'Private\UserState.ps1'
        'Private\Cache.ps1'
        'Private\Ui.Form.ps1'
        'Private\Ui.Window.ps1'
        'Private\Ui.Report.ps1'
    'Private\Ui.Shortcuts.ps1'
        'Lang\en\analysis.psd1'
        'Lang\en\command.psd1'
        'Lang\en\form.psd1'
        'Lang\en\help.psd1'
        'Lang\en\ui.psd1'
        'Lang\en\window.psd1'
        'Lang\fr\analysis.psd1'
        'Lang\fr\command.psd1'
        'Lang\fr\form.psd1'
        'Lang\fr\help.psd1'
        'Lang\fr\ui.psd1'
        'Lang\fr\window.psd1'
    )
}
