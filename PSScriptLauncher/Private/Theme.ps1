# Colours of the launcher: the palette of surlesnuages.fr, in light and dark.
# Every colour used by the window comes from here, so a theme change is one call, and the contrast
# of each pair is checked by the test suite.

function Get-ThemePalette {
    # Four levels of surface: Window (the frame), Surface (the cards), Sunken (fields, tree, tab
    # AccentText, Warning, Link, Selection.
    param([Parameter(Mandatory)][string]$Name)

    switch ($Name) {
        # Black, white and yellow: the classic high-contrast triple, independent of light and dark
        'contrast' {
            @{
                Window     = '#000000'
                Surface    = '#000000'
                Sunken     = '#000000'
                Field      = '#000000'
                Control    = '#000000'
                Text       = '#ffffff'
                Muted      = '#ffff00'
                Border     = '#ffffff'
                Accent     = '#ffff00'
                AccentText = '#000000'
                Warning    = '#ffb000'
                Link       = '#00ffff'
                Selection  = '#333333'
                Hover      = '#3a3a3a'
            }
        }
        'dark' {
            @{
                Window     = '#0f1923'
                Surface    = '#1c2a3a'
                Sunken     = '#16222e'
                Field      = '#2a3c50'
                Control    = '#2f4459'
                Text       = '#e8edf2'
                Muted      = '#b9c3cf'
                Border     = '#3c5068'
                Accent     = '#4a9eff'
                AccentText = '#081a34'
                Warning    = '#ffb86b'
                Link       = '#9fc7f5'
                Selection  = '#24405f'
                Hover      = '#25384c'
            }
        }
        default {
            @{
                Window     = '#e6ebef'
                Surface    = '#ffffff'
                Sunken     = '#f2f6f8'
                Field      = '#ffffff'
                Control    = '#f6f9fb'
                Text       = '#333333'
                Muted      = '#5f6a72'
                Border     = '#c9d4dc'
                Accent     = '#003b82'
                AccentText = '#ffffff'
                Warning    = '#b34700'
                Link       = '#2f6fa5'
                Selection  = '#cfe0f5'
                Hover      = '#eaf0f4'
            }
        }
    }
}

function Get-ThemeBrush {
    # Brush of the active palette. Falls back to light so a call before the theme is set still works.
    param([Parameter(Mandatory)][string]$Key)

    $palette = $script:Theme
    if ($palette -isnot [hashtable] -or -not $palette.ContainsKey($Key)) {
        $palette = Get-ThemePalette -Name 'light'
    }
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$Key])
    [System.Windows.Media.SolidColorBrush]::new($color)
}

function Get-SystemTheme {
    # Windows setting for applications, used by the "auto" choice.
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $light = (Get-ItemProperty -Path $key -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ($light -eq 0) { return 'dark' }
    }
    catch { Write-Verbose 'System theme unreadable, light is assumed.' }
    'light'
}

function Resolve-UiTheme {
    # 'auto' follows Windows, anything else is taken as is, a bad value falls back to the system.
    param([string]$Theme)

    if ($Theme -eq 'light' -or $Theme -eq 'dark') { return $Theme }
    Get-SystemTheme
}

function Add-UiStyle {
    # Merges the shared styles (Theme.xaml) into a window, so every window gets the same buttons,
    # fields and lists: without this, a secondary window falls back to the raw WPF chrome.
    param([Parameter(Mandatory)]$Window)

    $path = Join-Path $script:ModuleRoot 'Theme.xaml'
    $stream = [System.IO.File]::OpenRead($path)
    try {
        $dictionary = [System.Windows.Markup.XamlReader]::Load($stream)
    }
    finally { $stream.Dispose() }
    [void]$Window.Resources.MergedDictionaries.Add($dictionary)

    # And the active palette: a secondary window opened in dark mode must be dark too
    foreach ($key in 'Window', 'Surface', 'Sunken', 'Field', 'Control', 'Text', 'Muted', 'Border', 'Accent', 'AccentText', 'Warning', 'Link', 'Selection', 'Hover') {
        $Window.Resources[$key + 'Brush'] = Get-ThemeBrush $key
    }
    $Window.Background = Get-ThemeBrush 'Window'
    $Window.Foreground = Get-ThemeBrush 'Text'
}

function Get-EffectiveTheme {
    # High contrast sits on top of the light/dark choice; otherwise 'auto' follows Windows.
    param($State)

    if ($State -and $State.HighContrast) { return 'contrast' }
    $choice = 'auto'
    if ($State -and $State.Theme) { $choice = [string]$State.Theme }
    Resolve-UiTheme -Theme $choice
}

function Test-DyslexicFontAvailable {
    # OpenDyslexic is not shipped: it has to be installed on the computer. The result is kept, so
    # the list of system fonts is read once.
    if ($null -eq $script:DyslexicAvailable) {
        $found = [System.Windows.Media.Fonts]::SystemFontFamilies |
            Where-Object { $_.Source -like '*OpenDyslexic*' }
        $script:DyslexicAvailable = [bool]$found
    }
    $script:DyslexicAvailable
}

function Set-UiFont {
    # Dyslexia-friendly font when it is installed, the site's family chain otherwise.
    param([bool]$Dyslexic)

    $family = 'Poppins, Segoe UI'
    if ($Dyslexic -and (Test-DyslexicFontAvailable)) { $family = 'OpenDyslexic, ' + $family }
    if ($script:Window) { $script:Window.FontFamily = [System.Windows.Media.FontFamily]::new($family) }
}

function Set-UiFontScale {
    # One factor for the whole window: children inherit the window size, the few explicit sizes are
    # recomputed from the same factor.
    param([double]$Scale)

    if ($Scale -lt 1) { $Scale = 1 }
    if ($Scale -gt 2) { $Scale = 2 }
    $script:FontScale = $Scale
    if (-not $script:Window) { return }
    $script:Window.FontSize = [math]::Round(13 * $Scale, 1)
    if ($script:Ui -and $script:Ui.ScriptTitle) { $script:Ui.ScriptTitle.FontSize = [math]::Round(20 * $Scale, 1) }
}

function Get-UiFontSize {
    # Explicit size of a control built in code, scaled like the rest of the window.
    param([double]$Base)

    $scale = 1.0
    if ($script:FontScale) { $scale = [double]$script:FontScale }
    [math]::Round($Base * $scale, 1)
}

function Set-UiDensity {
    # More air between the parameter blocks, for a tired pair of eyes.
    param([bool]$Roomy)

    $script:RowSpacing = if ($Roomy) { 26 } else { 16 }
}

function Set-UiMotion {
    # Reduced motion keeps the progress bar informative but static, and removes the hover
    # highlight of the tree: a row only reacts when it is clicked.
    param([bool]$Reduced)

    $script:ReducedMotion = $Reduced
    if (-not $script:Window) { return }
    $hover = Get-ThemeBrush 'Hover'
    if ($Reduced) { $hover = [System.Windows.Media.Brushes]::Transparent }
    $script:Window.Resources['RowHoverBrush'] = $hover
}

function Set-UiAccessibilityFrame {
    # Thicker outline, and permanent: the setting exists to make the focus obvious, so it does not
    # wait for the keyboard.
    param([bool]$Thick)

    $script:ThickFocus = $Thick
    if (-not $script:Window) { return }
    $script:Window.Resources['FocusThickness'] = [System.Windows.Thickness]::new($(if ($Thick) { 2 } else { 1 }))
    Set-UiFocusRing -FromKeyboard ([bool]$script:KeyboardCues)
}

function Set-UiTheme {
    # Applies a palette ('light' or 'dark') to the window and its named elements. Controls created
    # later (tree items, parameter rows) read Get-ThemeBrush when they are built, and the window
    # rebuilds them on a theme change.
    param([Parameter(Mandatory)][ValidateSet('light', 'dark', 'contrast')][string]$Name)

    $script:ThemeName = $Name
    $script:Theme = Get-ThemePalette -Name $Name
    $ui = $script:Ui
    if (-not $ui) { return }

    # The window's own resources drive every implicit style: replacing the brushes repaints the
    # whole window, including the chrome of the default WPF templates.
    $resources = $script:Window.Resources
    foreach ($key in 'Window', 'Surface', 'Sunken', 'Field', 'Control', 'Text', 'Muted', 'Border', 'Accent', 'AccentText', 'Warning', 'Link', 'Selection', 'Hover') {
        $resources[$key + 'Brush'] = Get-ThemeBrush $key
    }
    # Both the window and the cards are black in high contrast: an outline gives the layout back
    $cardBorder = 0
    if ($Name -eq 'contrast') { $cardBorder = 1 }
    $resources['CardBorderThickness'] = [System.Windows.Thickness]::new($cardBorder)
    $script:Window.Background = Get-ThemeBrush 'Window'
    $script:Window.Foreground = Get-ThemeBrush 'Text'
    # Hover tint of the tree: gone when animations are reduced
    $hover = Get-ThemeBrush 'Hover'
    if ($script:ReducedMotion) { $hover = [System.Windows.Media.Brushes]::Transparent }
    $resources['RowHoverBrush'] = $hover
    $ring = [System.Windows.Media.Brushes]::Transparent
    if ($script:KeyboardCues -or $script:ThickFocus) { $ring = Get-ThemeBrush 'Accent' }
    $resources['FocusRingBrush'] = $ring

    # Colours that no generic style can guess
    foreach ($element in 'StatusText', 'RootText', 'SearchHint', 'ScriptPath', 'ScriptDescription') {
        if ($ui[$element]) { $ui[$element].Foreground = Get-ThemeBrush 'Muted' }
    }
    foreach ($element in 'EngineLabel', 'SetLabel', 'ExampleLabel', 'ExtraArgsLabel') {
        if ($ui[$element]) { $ui[$element].Foreground = Get-ThemeBrush 'Muted' }
    }
    $ui.ScriptInfo.Foreground = Get-ThemeBrush 'Link'
    $ui.ScriptWarning.Foreground = Get-ThemeBrush 'Warning'
    $ui.HelpGapsText.Foreground = Get-ThemeBrush 'Warning'
    $ui.RunButton.Background = Get-ThemeBrush 'Accent'
    $ui.RunButton.Foreground = Get-ThemeBrush 'AccentText'
    $ui.RunButton.BorderBrush = Get-ThemeBrush 'Accent'
}
