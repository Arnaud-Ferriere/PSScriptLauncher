# Help report: the scripts whose help is missing something, and what is missing.

function Get-HelpReportRow {
    # One line of the report: script name, folder, and the list of gaps.
    param([Parameter(Mandatory)]$ScriptInfo)

    $gapText = Format-HelpGapText -ScriptInfo $ScriptInfo
    [pscustomobject]@{
        Script         = $ScriptInfo.BaseName
        Folder         = $(if ($ScriptInfo.RelativeDirectory) { $ScriptInfo.RelativeDirectory } else { '.' })
        Missing        = $gapText
        Path           = $ScriptInfo.Path
        AutomationName = $ScriptInfo.BaseName + ' — ' + $gapText
    }
}

function New-HelpReportWindow {
    # Builds and fills the report window without showing it: the caller decides how to display it.
    $scripts = @($script:State.Scripts | Where-Object {
            (Test-IncompleteHelp -ScriptInfo $_) -or ([int]$_.UndocumentedCount -gt 0)
        } | Sort-Object -Property RelativePath)

    $xamlPath = Join-Path $script:ModuleRoot 'HelpReportWindow.xaml'
    $window = [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($xamlPath))
    Add-UiStyle -Window $window
    $ui = @{}
    try {
        if ($script:Window -and $script:Window.IsVisible) { $window.Owner = $script:Window }
        $window.Title = Get-UiText 'report.title'
        foreach ($name in 'ReportSummary', 'ReportList', 'ColumnScript', 'ColumnFolder', 'ColumnMissing',
            'ReportEditButton', 'ReportFolderButton', 'ReportCloseButton') {
            $element = $window.FindName($name)
            if ($null -eq $element) { throw (Get-UiText 'window.error.uiElement' -Arguments @($name)) }
            $ui[$name] = $element
        }

        $ui.ColumnScript.Text = Get-UiText 'report.column.script'
        $ui.ColumnFolder.Text = Get-UiText 'report.column.folder'
        $ui.ColumnMissing.Text = Get-UiText 'report.column.missing'
        $ui.ReportEditButton.Content = Get-UiText 'report.button.edit'
        $ui.ReportFolderButton.Content = Get-UiText 'report.button.folder'
        $ui.ReportCloseButton.Content = Get-UiText 'report.button.close'
        $ui.ReportSummary.Text = if ($scripts.Count -eq 0) {
            Get-UiText 'report.empty'
        }
        else {
            Get-UiText 'report.summary' -Arguments @($script:State.Scripts.Count, $scripts.Count)
        }
        $ui.ReportList.ItemsSource = @(foreach ($scriptInfo in $scripts) { Get-HelpReportRow -ScriptInfo $scriptInfo })

        # The handlers outlive this function, so they take everything from their sender ($this):
        # captured locals are gone by the time the button is clicked, and GetNewClosure would
        # detach them from the module they need for Open-ScriptEditor and Show-ScriptLocation.
        $ui.ReportCloseButton.Add_Click({
                $window = [System.Windows.Window]::GetWindow($this)
                if ($null -ne $window) { $window.Close() }
            })
        $ui.ReportEditButton.Add_Click({
                $row = [System.Windows.Window]::GetWindow($this).FindName('ReportList').SelectedItem
                if ($null -ne $row) { Open-ScriptEditor -Path $row.Path }
            })
        $ui.ReportFolderButton.Add_Click({
                $row = [System.Windows.Window]::GetWindow($this).FindName('ReportList').SelectedItem
                if ($null -ne $row) { Show-ScriptLocation -Path $row.Path }
            })
        $ui.ReportList.Add_MouseDoubleClick({
                $row = $this.SelectedItem
                if ($null -ne $row) { Open-ScriptEditor -Path $row.Path }
            })

        $window
    }
    catch {
        $window.Close()
        throw
    }
}

function Show-HelpReport {
    # Shows the report window, modal over the launcher.
    $window = New-HelpReportWindow
    try { [void]$window.ShowDialog() }
    finally { $window.Close() }
}
