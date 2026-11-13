# Parameter form: creating the rows, reading and writing the values.

function New-HintedTextBox {
    # TextBox with a hint text (WPF has no Placeholder property).
    param([string]$Hint, [switch]$Multiline, [switch]$Monospace)

    $grid = [System.Windows.Controls.Grid]::new()
    $box = [System.Windows.Controls.TextBox]::new()
    $box.Padding = [System.Windows.Thickness]::new(4, 3, 4, 3)
    if ($Multiline) {
        $box.AcceptsReturn = $true
        $box.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $box.MinHeight = 64
        $box.MaxHeight = 170
        $box.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    }
    if ($Monospace) { $box.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas') }
    [void]$grid.Children.Add($box)

    if ($Hint) {
        $hintBlock = [System.Windows.Controls.TextBlock]::new()
        $hintBlock.Text = $Hint
        $hintBlock.Foreground = [System.Windows.Media.Brushes]::Gray
        $hintBlock.IsHitTestVisible = $false
        $hintBlock.Margin = [System.Windows.Thickness]::new(8, 4, 0, 0)
        $hintBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        [void]$grid.Children.Add($hintBlock)
        $box.Tag = $hintBlock
    }

    # Handler without closure: $args[0] is the source TextBox, its Tag holds the hint
    $box.Add_TextChanged({
            $changedBox = $args[0]
            if ($changedBox.Tag) {
                $changedBox.Tag.Visibility = if ($changedBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
            }
            Invoke-UiAction { Update-CommandPreview }
        })
    [pscustomobject]@{ Container = $grid; TextBox = $box }
}

function Get-BrowseMode {
    # "Browse" buttons to offer for a parameter, from its type and its name:
    # 'File', 'Folder', 'Both' (*Path: cannot be guessed) or $null.
    param([Parameter(Mandatory)]$Parameter)

    if ($Parameter.Kind -notin 'Text', 'TextArray') { return $null }
    $typeName = $Parameter.TypeName -replace '\[\]$', ''
    if ($typeName -match '(?i)(^|\.)DirectoryInfo$') { return 'Folder' }
    if ($typeName -match '(?i)(^|\.)FileInfo$') { return 'File' }
    if ($typeName -notmatch '(?i)^(System\.)?(String|Object)$') { return $null }
    switch -Regex ($Parameter.Name) {
        '(?i)(Folder|Directory|Dir)s?$' { return 'Folder' }
        '(?i)Files?$' { return 'File' }
        '(?i)Paths?$' { return 'Both' }
    }
    $null
}

function Select-FilePath {
    # "Open" dialog. A nonexistent file name is accepted (output file).
    param([string]$InitialDirectory, [switch]$Multiple)

    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = Get-UiText 'form.dialog.pickFile'
    $dialog.CheckFileExists = $false
    $dialog.Multiselect = [bool]$Multiple
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $dialog.InitialDirectory = $InitialDirectory
    }
    if ($dialog.ShowDialog($script:Window) -eq $true) { return , [string[]]$dialog.FileNames }
    , [string[]]@()
}

function Select-FolderPath {
    # Folder picker dialog (Windows Forms: WPF does not provide one in .NET Framework).
    param([string]$InitialDirectory)

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = Get-UiText 'window.dialog.pickFolder'
        $dialog.ShowNewFolderButton = $true
        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
            $dialog.SelectedPath = $InitialDirectory
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally { $dialog.Dispose() }
}

function Invoke-BrowseButton {
    # Click on "File..." or "Folder...": the button Tag designates the target input box.
    param([Parameter(Mandatory)]$Button)

    $target = $Button.Tag
    $box = $target.Box
    # Starting folder: that of the value already typed, otherwise that of the script
    $initial = $null
    $currentValue = @($box.Text -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($currentValue) {
        $candidate = $currentValue.Trim()
        if (Test-Path -LiteralPath $candidate -PathType Container) { $initial = $candidate }
        else {
            $parent = Split-Path -Parent $candidate -ErrorAction SilentlyContinue
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) { $initial = $parent }
        }
    }
    if (-not $initial -and $script:State.Current) { $initial = $script:State.Current.Directory }

    $selected = if ($target.Folder) { @(Select-FolderPath -InitialDirectory $initial) }
    else { @(Select-FilePath -InitialDirectory $initial -Multiple:$target.Multiple) }
    $selected = @($selected | Where-Object { $_ })
    if ($selected.Count -eq 0) { return }

    if ($target.Multiple) {
        # Array: the choices are added to the lines already typed
        $lines = @($box.Text -split '\r?\n' | Where-Object { $_.Trim() }) + $selected
        $box.Text = $lines -join [Environment]::NewLine
    }
    else {
        $box.Text = $selected[0]
    }
}

function New-BrowsePanel {
    # Row of "File..." / "Folder..." buttons attached to one input box.
    param(
        [Parameter(Mandatory)]$TextBox,
        [Parameter(Mandatory)][ValidateSet('File', 'Folder', 'Both')][string]$Mode,
        [switch]$Multiple
    )

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $panel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $folderLabel = Get-UiText 'window.button.folder'
    $labels = [System.Collections.Generic.List[string]]::new()
    if ($Mode -in 'File', 'Both') { $labels.Add((Get-UiText 'form.button.file')) }
    if ($Mode -in 'Folder', 'Both') { $labels.Add($folderLabel) }
    foreach ($label in $labels) {
        $button = [System.Windows.Controls.Button]::new()
        $button.Content = $label
        $button.Padding = [System.Windows.Thickness]::new(8, 1, 8, 1)
        $button.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $button.Tag = [pscustomobject]@{ Box = $TextBox; Folder = ($label -eq $folderLabel); Multiple = [bool]$Multiple }
        # Handler without closure: $args[0] is the button, its Tag holds the target
        $button.Add_Click({
                $clicked = $args[0]
                Invoke-UiAction { Invoke-BrowseButton -Button $clicked }
            })
        [void]$panel.Children.Add($button)
    }
    $panel
}

function New-ParameterRow {
    # Input block for one parameter: header, control suited to the type, description.
    param([Parameter(Mandatory)]$Parameter)

    $panel = [System.Windows.Controls.StackPanel]::new()
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)

    $header = [System.Windows.Controls.TextBlock]::new()
    $header.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $nameRun = [System.Windows.Documents.Run]::new()
    $nameRun.Text = '-' + $Parameter.Name
    $nameRun.FontWeight = [System.Windows.FontWeights]::SemiBold
    $star = [System.Windows.Documents.Run]::new()
    $star.Foreground = [System.Windows.Media.Brushes]::Firebrick
    $star.FontWeight = [System.Windows.FontWeights]::Bold
    $typeRun = [System.Windows.Documents.Run]::new()
    $typeRun.Text = '   [' + $Parameter.TypeName + ']'
    $typeRun.Foreground = [System.Windows.Media.Brushes]::Gray
    $header.Inlines.Add($nameRun)
    $header.Inlines.Add($star)
    $header.Inlines.Add($typeRun)
    [void]$panel.Children.Add($header)

    $control = $null
    $inputBox = $null
    $userBox = $null
    switch ($Parameter.Kind) {
        { $_ -in 'Switch', 'SecureString' } {
            $control = [System.Windows.Controls.CheckBox]::new()
            $control.Content = if ($Parameter.Kind -eq 'Switch') { Get-UiText 'form.check.enable' }
            else { Get-UiText 'form.check.secureStringPrompt' }
            $control.Add_Click({ Invoke-UiAction { Update-CommandPreview } })
            [void]$panel.Children.Add($control)
        }
        'Credential' {
            $control = [System.Windows.Controls.CheckBox]::new()
            $control.Content = Get-UiText 'form.check.credentialPrompt'
            $control.Add_Click({ Invoke-UiAction { Update-CommandPreview } })
            $line = [System.Windows.Controls.StackPanel]::new()
            $line.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $line.Margin = [System.Windows.Thickness]::new(22, 5, 0, 0)
            $label = [System.Windows.Controls.TextBlock]::new()
            $label.Text = Get-UiText 'form.label.userName'
            $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $label.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
            $hinted = New-HintedTextBox -Hint (Get-UiText 'form.hint.domainUser')
            $hinted.Container.Width = 240
            $userBox = $hinted.TextBox
            [void]$line.Children.Add($label)
            [void]$line.Children.Add($hinted.Container)
            [void]$panel.Children.Add($control)
            [void]$panel.Children.Add($line)
        }
        { $_ -in 'Bool', 'Choice' } {
            $control = [System.Windows.Controls.ComboBox]::new()
            $control.MinWidth = 220
            $control.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
            [void]$control.Items.Add((Get-UiText 'form.choice.unset'))
            $choices = if ($Parameter.Kind -eq 'Bool') { @('$true', '$false') } else { $Parameter.ValidValues }
            foreach ($choice in $choices) { [void]$control.Items.Add([string]$choice) }
            $control.SelectedIndex = 0
            $control.Add_SelectionChanged({ Invoke-UiAction { Update-CommandPreview } })
            [void]$panel.Children.Add($control)
        }
        'MultiChoice' {
            $control = [System.Windows.Controls.WrapPanel]::new()
            foreach ($choice in $Parameter.ValidValues) {
                $box = [System.Windows.Controls.CheckBox]::new()
                # Label inside a TextBlock: in plain text, an "_" would be taken as a keyboard shortcut
                $label = [System.Windows.Controls.TextBlock]::new()
                $label.Text = [string]$choice
                $box.Content = $label
                $box.Tag = [string]$choice
                $box.Margin = [System.Windows.Thickness]::new(0, 0, 16, 4)
                $box.Add_Click({ Invoke-UiAction { Update-CommandPreview } })
                [void]$control.Children.Add($box)
            }
            [void]$panel.Children.Add($control)
        }
        default {
            $hint = switch ($Parameter.Kind) {
                'TextArray' { Get-UiText 'form.hint.textArray' }
                'Number' {
                    if ($Parameter.IsInteger) { Get-UiText 'form.hint.integer' }
                    else { Get-UiText 'form.hint.number' }
                }
                'Date' {
                    Get-UiText 'form.hint.date' -Arguments @((Get-Date).ToString('g'))
                }
                'Expression' {
                    if ($Parameter.Type -eq [scriptblock]) { Get-UiText 'form.hint.expressionBlock' }
                    else { Get-UiText 'form.hint.expressionTable' }
                }
                default { '' }
            }
            $hinted = New-HintedTextBox -Hint $hint -Multiline:($Parameter.Kind -eq 'TextArray') `
                -Monospace:($Parameter.Kind -eq 'Expression')
            $control = $hinted.TextBox
            $inputBox = $hinted.TextBox
            [void]$panel.Children.Add($hinted.Container)
            $browseMode = Get-BrowseMode -Parameter $Parameter
            if ($browseMode) {
                $browse = New-BrowsePanel -TextBox $hinted.TextBox -Mode $browseMode `
                    -Multiple:($Parameter.Kind -eq 'TextArray')
                [void]$panel.Children.Add($browse)
            }
        }
    }

    if ($Parameter.Description) {
        $description = [System.Windows.Controls.TextBlock]::new()
        $description.Text = $Parameter.Description
        $description.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $description.Foreground = [System.Windows.Media.Brushes]::DimGray
        $description.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
        [void]$panel.Children.Add($description)
    }
    $details = [System.Collections.Generic.List[string]]::new()
    if ($Parameter.DefaultValue) {
        $details.Add((Get-UiText 'form.label.default' -Arguments @($Parameter.DefaultValue)))
    }
    if ($Parameter.Aliases.Count -gt 0) {
        $details.Add((Get-UiText 'form.label.alias' -Arguments @(($Parameter.Aliases -join ', '))))
    }
    foreach ($constraint in @(Format-ParameterValidation -Validation $Parameter.Validation)) { $details.Add($constraint) }
    if ($details.Count -gt 0) {
        $meta = [System.Windows.Controls.TextBlock]::new()
        $meta.Text = $details -join '   ·   '
        $meta.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $meta.FontSize = 11.5
        $meta.Foreground = [System.Windows.Media.Brushes]::Gray
        $meta.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        [void]$panel.Children.Add($meta)
    }

    [pscustomobject]@{
        Parameter = $Parameter
        Panel     = $panel
        Star      = $star
        Control   = $control
        InputBox  = $inputBox
        UserBox   = $userBox
    }
}

function Get-RowValue {
    # Value typed in a form row, in the form expected by ConvertTo-ParameterArgument.
    param([Parameter(Mandatory)]$Row)

    $control = $Row.Control
    switch ($Row.Parameter.Kind) {
        { $_ -in 'Switch', 'SecureString' } { return ($control.IsChecked -eq $true) }
        'Credential' {
            return [pscustomobject]@{ Prompt = ($control.IsChecked -eq $true); UserName = $Row.UserBox.Text }
        }
        'Bool' {
            if ($control.SelectedIndex -eq 1) { return 'true' }
            if ($control.SelectedIndex -eq 2) { return 'false' }
            return ''
        }
        'Choice' {
            if ($control.SelectedIndex -gt 0) { return [string]$control.SelectedItem }
            return ''
        }
        'MultiChoice' {
            $checked = @($control.Children | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [string]$_.Tag })
            return , [string[]]$checked      # comma: the array is returned whole, even when empty
        }
        'TextArray' { return , [string[]]@($control.Text -split '\r?\n') }
        default { return $control.Text }
    }
}

function Set-RowValue {
    # Writes a value into a form row (inverse of Get-RowValue). $null clears the row.
    # A value that no longer fits (choice removed from the ValidateSet...) is ignored, without error.
    param([Parameter(Mandatory)]$Row, $Value)

    $control = $Row.Control
    switch ($Row.Parameter.Kind) {
        { $_ -in 'Switch', 'SecureString' } { $control.IsChecked = ($Value -eq $true) }
        'Credential' {
            $prompt = $false
            $userName = ''
            if ($Value -is [System.Collections.IDictionary]) {
                $prompt = ($Value['Prompt'] -eq $true)
                $userName = [string]$Value['UserName']
            }
            elseif ($Value -eq $true) { $prompt = $true }
            $control.IsChecked = $prompt
            $Row.UserBox.Text = $userName
        }
        'Bool' {
            $text = ([string]$Value).TrimStart('$')
            $control.SelectedIndex = if ($text -eq 'true') { 1 } elseif ($text -eq 'false') { 2 } else { 0 }
        }
        'Choice' {
            $index = 0
            for ($i = 1; $i -lt $control.Items.Count; $i++) {
                if ([string]$control.Items[$i] -eq [string]$Value) { $index = $i }
            }
            $control.SelectedIndex = $index
        }
        'MultiChoice' {
            $wanted = @(@($Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            foreach ($box in $control.Children) { $box.IsChecked = ($wanted -contains [string]$box.Tag) }
        }
        'TextArray' {
            $lines = @(@($Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            $control.Text = $lines -join [Environment]::NewLine
        }
        default { $control.Text = [string]$Value }
    }
}

function Set-RowFromExample {
    # Fills a row with an argument read from a .EXAMPLE. Returns $false if the example value is not
    # literal (variable, subexpression) and cannot be typed as is.
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Argument)

    switch ($Row.Parameter.Kind) {
        'Switch' {
            Set-RowValue -Row $Row -Value ($Argument.Value -ne $false)
            return $true
        }
        { $_ -in 'Credential', 'SecureString' } {
            # The example passes an object ($cred, (Get-Credential)...): it will be asked at launch
            Set-RowValue -Row $Row -Value $true
            return $true
        }
        'Expression' {
            Set-RowValue -Row $Row -Value $Argument.Text
            return $true
        }
    }
    if (-not $Argument.IsLiteral) { return $false }
    Set-RowValue -Row $Row -Value $Argument.Value
    $true
}

function Update-ParameterVisibility {
    # Shows the parameters of the selected set and whether they are mandatory in that set.
    foreach ($row in $script:State.Rows) {
        $mandatory = Get-ParameterSetMembership -Parameter $row.Parameter -ParameterSet $script:State.CurrentSet
        if ($null -eq $mandatory) {
            $row.Panel.Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $row.Panel.Visibility = [System.Windows.Visibility]::Visible
            $row.Star.Text = if ($mandatory) { ' *' } else { '' }
        }
    }
    Update-CommandPreview
}

function Update-CommandPreview {
    # Rebuilds the command from the form and reports the invalid values.
    if ($script:State.Loading -or $null -eq $script:State.Current) { return }

    $values = @{}
    foreach ($row in $script:State.Rows) { $values[$row.Parameter.Name] = Get-RowValue -Row $row }
    $common = [System.Collections.Generic.List[string]]::new()
    if ($script:Ui.VerboseCheck.IsChecked -eq $true) { $common.Add('Verbose') }
    if ($script:Ui.WhatIfCheck.IsChecked -eq $true) { $common.Add('WhatIf') }

    $commandParameters = @{
        ScriptInfo      = $script:State.Current
        ParameterSet    = $script:State.CurrentSet
        Values          = $values
        CommonParameter = $common.ToArray()
        ExtraArguments  = $script:Ui.ExtraArgsBox.Text
    }
    $result = New-ScriptCommand @commandParameters
    $script:State.LastCommand = $result
    $script:Ui.CommandBox.Text = $result.CommandText

    foreach ($row in $script:State.Rows) {
        if ($null -eq $row.InputBox) { continue }
        if ($result.Errors.ContainsKey($row.Parameter.Name)) {
            $row.InputBox.BorderBrush = [System.Windows.Media.Brushes]::Firebrick
            $row.InputBox.ToolTip = $result.Errors[$row.Parameter.Name] -join [Environment]::NewLine
        }
        else {
            $row.InputBox.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
            $row.InputBox.ClearValue([System.Windows.FrameworkElement]::ToolTipProperty)
        }
    }
}
