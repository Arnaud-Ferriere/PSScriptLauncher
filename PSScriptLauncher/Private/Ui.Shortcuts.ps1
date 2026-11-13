# Keyboard shortcuts: a small window listing what the keyboard can do, translated.

function Get-ShortcutRow {
    # One line of the window: the keys, what they do, and how a screen reader reads the pair.
    param([Parameter(Mandatory)][string]$Keys, [Parameter(Mandatory)][string]$Text)

    [pscustomobject]@{
        Keys           = $Keys
        Text           = $Text
        AutomationName = $Keys + ' : ' + $Text
    }
}

function New-ShortcutsWindow {
    # Builds the shortcuts window without showing it, so the tests can inspect it.
    $xamlPath = Join-Path $script:ModuleRoot 'ShortcutsWindow.xaml'
    $window = [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($xamlPath))
    Add-UiStyle -Window $window
    try {
        if ($script:Window -and $script:Window.IsVisible) {
            $window.Owner = $script:Window
            $window.FontFamily = [System.Windows.Media.FontFamily]::new($script:Window.FontFamily.Source)
            $window.FontSize = $script:Window.FontSize
        }
        $window.Title = Get-UiText 'shortcuts.title'
        $window.Background = Get-ThemeBrush 'Surface'
        $window.Foreground = Get-ThemeBrush 'Text'
        $window.Resources['KeyBrush'] = Get-ThemeBrush 'Accent'
        $window.Resources['ListBrush'] = Get-ThemeBrush 'Sunken'
        $window.Resources['BorderBrush'] = Get-ThemeBrush 'Border'

        $hint = $window.FindName('ShortcutsHint')
        $hint.Text = Get-UiText 'shortcuts.hint'
        $hint.Foreground = Get-ThemeBrush 'Muted'
        $window.FindName('KeysHeader').Text = Get-UiText 'shortcuts.column.keys'
        $window.FindName('ActionHeader').Text = Get-UiText 'shortcuts.column.action'

        $list = $window.FindName('ShortcutsList')
        [System.Windows.Automation.AutomationProperties]::SetName($list, (Get-UiText 'shortcuts.title'))
        # Key names follow the interface language (Echap, Fleches, Maj+Tab...), shortcuts do not
        $list.ItemsSource = @(
            Get-ShortcutRow -Keys 'Ctrl+O' -Text (Get-UiText 'shortcuts.folder')
            Get-ShortcutRow -Keys 'Ctrl+F' -Text (Get-UiText 'shortcuts.search')
            Get-ShortcutRow -Keys 'F5' -Text (Get-UiText 'shortcuts.refresh')
            Get-ShortcutRow -Keys (Get-UiText 'shortcuts.keys.run') -Text (Get-UiText 'shortcuts.run')
            Get-ShortcutRow -Keys (Get-UiText 'shortcuts.keys.close') -Text (Get-UiText 'shortcuts.close')
            Get-ShortcutRow -Keys (Get-UiText 'shortcuts.keys.navigate') -Text (Get-UiText 'shortcuts.navigate')
            Get-ShortcutRow -Keys (Get-UiText 'shortcuts.keys.tree') -Text (Get-UiText 'shortcuts.tree')
            Get-ShortcutRow -Keys (Get-UiText 'shortcuts.keys.activate') -Text (Get-UiText 'shortcuts.activate')
        )

        $close = $window.FindName('ShortcutsCloseButton')
        $close.Content = Get-UiText 'shortcuts.button.close'
        $close.Background = Get-ThemeBrush 'Control'
        $close.Foreground = Get-ThemeBrush 'Text'
        $close.BorderBrush = Get-ThemeBrush 'Border'
        [System.Windows.Automation.AutomationProperties]::SetName($close, (Get-UiText 'shortcuts.button.close'))
        $close.Add_Click({
                $window = [System.Windows.Window]::GetWindow($this)
                if ($null -ne $window) { $window.Close() }
            })

        $window
    }
    catch {
        $window.Close()
        throw
    }
}

function Show-ShortcutHelp {
    # Shows the shortcuts window, modal over the launcher. The list takes the focus, so the arrows
    # and the page keys scroll it as soon as it opens.
    $window = New-ShortcutsWindow
    try {
        [void]$window.ShowDialog()
    }
    finally { $window.Close() }
}
