# Main window: script tree, script details, launching, events.

function Show-ErrorDialog {
    # Modal error box, attached to the launcher window when one exists.
    param([Parameter(Mandatory)][string]$Message)

    $button = [System.Windows.MessageBoxButton]::OK
    $icon = [System.Windows.MessageBoxImage]::Error
    if ($script:Window) {
        [void][System.Windows.MessageBox]::Show($script:Window, $Message, (Get-UiText 'window.title'), $button, $icon)
    }
    else {
        [void][System.Windows.MessageBox]::Show($Message, (Get-UiText 'window.title'), $button, $icon)
    }
}

function Invoke-UiAction {
    # Runs the body of an event handler: an error is displayed (with the line of the
    # launcher where it occurred) instead of bringing the window down.
    param([Parameter(Mandatory)][scriptblock]$Action)

    try { & $Action }
    catch {
        # Message of the original error, without the "Exception calling ..." wrappers
        $message = $_.Exception.GetBaseException().Message
        $file = Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)
        $origin = '{0}, line {1}' -f $file, $_.InvocationInfo.ScriptLineNumber
        Show-ErrorDialog -Message ((Get-UiText 'window.error.uiAction' -Arguments @($message)) + [Environment]::NewLine + '(' + $origin + ')')
    }
}

function Set-Status {
    # Status bar message (repeated as a tooltip: the text may be truncated).
    param([string]$Message)

    $script:Ui.StatusText.Text = $Message
    $script:Ui.StatusText.ToolTip = $Message
    # Announce the change to a screen reader: the status bar is a live region
    $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::FromElement($script:Ui.StatusText)
    if ($peer) {
        $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
    }
}

function Set-OptionalText {
    # Sets the text of a TextBlock and hides it when the text is empty.
    param([Parameter(Mandatory)]$Element, [string]$Text)

    $Element.Text = $Text
    $Element.Visibility = if ([string]::IsNullOrWhiteSpace($Text)) { 'Collapsed' } else { 'Visible' }
}

function New-LauncherState {
    # Window state for one launcher session.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludePattern = @(),
        [string]$StatePath
    )

    if (-not $StatePath) { $StatePath = Get-DefaultStatePath }
    $cachePath = Get-CatalogCachePath -Root $Root -StatePath $StatePath
    @{
        Root           = $Root
        ExcludePattern = $ExcludePattern
        LauncherPath   = Join-Path (Split-Path -Parent $script:ModuleRoot) 'Show-PSScriptLauncher.ps1'
        DefaultEdition = $PSVersionTable.PSEdition
        StatePath      = $StatePath
        UserState      = Read-UserState -Path $StatePath
        Scripts        = @()
        Current        = $null
        CurrentSet     = ''
        Rows           = @()
        LastCommand    = $null
        ScanSeconds    = 0
        ScanWarnings   = 0
        ScanErrors     = 0
        CachePath      = $cachePath
        Cache          = Read-CatalogCache -Path $cachePath -Root $Root
        Loading        = $false
        Loaded         = $false
        Engines        = @()
        SearchTimer    = $null
        ScanTimer      = $null
        Scan           = $null
        TreeFolders    = @{}
        TreeFiltered   = $false
        HelpFilter     = 'all'
        FilterLoading  = $false
    }
}

function Edit-UserState {
    # Applies a change to the user state and saves it. The state is re-read just
    # before, so as not to overwrite what another launcher window saved in the meantime.
    # A failed write interrupts nothing: it is only reported in the status bar.
    param([Parameter(Mandatory)][scriptblock]$Change)

    $state = Read-UserState -Path $script:State.StatePath
    & $Change $state
    $script:State.UserState = $state
    try { Save-UserState -Path $script:State.StatePath -State $state }
    catch { Set-Status (Get-UiText 'window.error.preferences' -Arguments @($_.Exception.Message)) }
}

function Get-TreeFolderNode {
    # Folder node in the tree, created on demand along with its parent folders.
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$RelativeDirectory,
        [bool]$Expand
    )

    if ($Cache.ContainsKey($RelativeDirectory)) { return $Cache[$RelativeDirectory] }
    $item = [System.Windows.Controls.TreeViewItem]::new()
    # Bold on the header only: applied to the node, FontWeight would be inherited by scripts
    $header = [System.Windows.Controls.TextBlock]::new()
    $header.Text = [System.IO.Path]::GetFileName($RelativeDirectory)
    $header.FontWeight = [System.Windows.FontWeights]::SemiBold
    $item.Header = $header
    $item.IsExpanded = $Expand
    $parent = [System.IO.Path]::GetDirectoryName($RelativeDirectory)
    if ([string]::IsNullOrEmpty($parent)) { [void]$script:Ui.ScriptTree.Items.Add($item) }
    else {
        $parentNode = Get-TreeFolderNode -Cache $Cache -RelativeDirectory $parent -Expand $Expand
        [void]$parentNode.Items.Add($item)
    }
    $Cache[$RelativeDirectory] = $item
    $item
}

function New-ScriptTreeItem {
    # Script node: name, color according to its state (warning, no help), tooltip.
    param([Parameter(Mandatory)]$Entry, [switch]$ShowLocation)

    $item = [System.Windows.Controls.TreeViewItem]::new()
    $header = [System.Windows.Controls.TextBlock]::new()
    $header.Text = $Entry.BaseName
    $header.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $itemStatus = ''
    if ((Get-ScriptWarningCount -ScriptInfo $Entry) -gt 0) {
        $header.Foreground = Get-ThemeBrush 'Warning'
        $itemStatus = Get-UiText 'window.a11y.warning'
    }
    elseif (-not $Entry.Synopsis) {
        $header.Foreground = Get-ThemeBrush 'Muted'
        $itemStatus = Get-UiText 'window.a11y.noHelp'
    }
    if ($itemStatus) {
        # Colour alone is not information: the state is also exposed to screen readers
        [System.Windows.Automation.AutomationProperties]::SetItemStatus($item, $itemStatus)
    }
    $item.Header = $header
    $item.Tag = $Entry
    $toolTip = if ($Entry.Synopsis) { $Entry.Synopsis } else { Get-UiText 'window.tree.noHelp' }

    if ($ShowLocation) { $toolTip = $Entry.RelativePath + [Environment]::NewLine + $toolTip }
    $item.ToolTip = $toolTip
    $item
}

function Add-PinnedSection {
    # Section at the top of the tree (Favorites, Recents): shortcuts to inventory scripts.
    # Paths that are no longer in the inventory are simply ignored.
    param(
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Path = @(),
        [Parameter(Mandatory)][hashtable]$ScriptByPath,
        [switch]$Sort
    )

    $entries = @($Path | ForEach-Object { $ScriptByPath[$_.ToLowerInvariant()] } | Where-Object { $_ })
    if ($entries.Count -eq 0) { return }
    if ($Sort) { $entries = @($entries | Sort-Object -Property BaseName) }

    $section = [System.Windows.Controls.TreeViewItem]::new()
    $header = [System.Windows.Controls.TextBlock]::new()
    $header.Text = $Title
    $header.FontWeight = [System.Windows.FontWeights]::SemiBold
    $section.Header = $header
    $section.IsExpanded = $true
    foreach ($entry in $entries) { [void]$section.Items.Add((New-ScriptTreeItem -Entry $entry -ShowLocation)) }
    [void]$script:Ui.ScriptTree.Items.Add($section)
}

function Test-ScriptHelpFilter {
    # True when the script belongs to the help filter selected in the list.
    param([Parameter(Mandatory)]$ScriptInfo, [string]$Filter)

    switch ($Filter) {
        'incomplete' { Test-IncompleteHelp -ScriptInfo $ScriptInfo }
        'synopsis' { [bool]$ScriptInfo.MissingSynopsis }
        'description' { [bool]$ScriptInfo.MissingDescription }
        'example' { [bool]$ScriptInfo.MissingExample }
        'parameters' { [int]$ScriptInfo.UndocumentedCount -gt 0 }
        default { $true }
    }
}

function Get-ScriptView {
    # Scripts shown by the tree: the text filter and the help filter combined.
    param([string]$Filter)

    $helpFilter = [string]$script:State.HelpFilter
    @($script:State.Scripts | Where-Object {
            (Test-ScriptFilter -ScriptInfo $_ -Filter $Filter) -and
            (Test-ScriptHelpFilter -ScriptInfo $_ -Filter $helpFilter)
        })
}

function Format-HelpGapText {
    # What is missing for this script, as one localized sentence, or an empty string.
    param([Parameter(Mandatory)]$ScriptInfo)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($gap in @(Get-HelpGap -ScriptInfo $ScriptInfo)) {
        switch ($gap) {
            'synopsis' { $parts.Add((Get-UiText 'helpGap.synopsis')) }
            'description' { $parts.Add((Get-UiText 'helpGap.description')) }
            'example' { $parts.Add((Get-UiText 'helpGap.example')) }
            'parameters' {
                $names = @($ScriptInfo.UndocumentedParameters)
                if ($names.Count -gt 0) {
                    $parts.Add((Get-UiText 'helpGap.parametersNamed' -Arguments @($names.Count, ($names -join ', '))))
                }
                else {
                    $parts.Add((Get-UiText 'helpGap.parameters' -Arguments @([int]$ScriptInfo.UndocumentedCount)))
                }
            }
        }
    }
    ($parts -join ' · ')
}

function Initialize-HelpFilter {
    # Filter list: 'all' plus one entry per kind of gap. Labels come from the catalog, so the list
    # is rebuilt when the interface language changes.
    $combo = $script:Ui.HelpFilterCombo
    $current = [string]$script:State.HelpFilter
    $script:State.FilterLoading = $true
    try {
        $combo.Items.Clear()
        foreach ($code in 'all', 'incomplete', 'synopsis', 'description', 'example', 'parameters') {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = Get-UiText ('window.filter.help.' + $code)
            $item.Tag = $code
            [void]$combo.Items.Add($item)
            if ($code -eq $current) { $combo.SelectedItem = $item }
        }
        if ($null -eq $combo.SelectedItem -and $combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    }
    finally { $script:State.FilterLoading = $false }
}

function Set-HelpFilter {
    # Filter picked in the list: refresh the tree and the status bar.
    $item = $script:Ui.HelpFilterCombo.SelectedItem
    if ($null -eq $item) { return }
    $script:State.HelpFilter = [string]$item.Tag
    Update-ScriptTree
    if ($script:State.HelpFilter -eq 'all') {
        Set-Status (Format-CatalogStatus -Count $script:State.Scripts.Count -Seconds $script:State.ScanSeconds `
            -Warnings $script:State.ScanWarnings -Errors $script:State.ScanErrors)
    }
    else {
        $count = @(Get-ScriptView -Filter $script:Ui.SearchBox.Text).Count
        $message = Get-UiText 'window.status.helpFilter' -Arguments @($count, (Get-UiText ('window.filter.help.' + $script:State.HelpFilter)))
        if ($script:State.HelpFilter -eq 'incomplete') {
            $scripts = @($script:State.Scripts)
            $message += ' ' + (Get-UiText 'window.status.helpAudit' -Arguments @(
                    @($scripts | Where-Object { $_.MissingSynopsis }).Count,
                    @($scripts | Where-Object { $_.MissingDescription }).Count,
                    @($scripts | Where-Object { $_.MissingExample }).Count,
                    @($scripts | Where-Object { [int]$_.UndocumentedCount -gt 0 }).Count))
        }
        Set-Status $message
    }
}

function Update-ScriptTree {
    # Rebuilds the tree from the inventory, the search filter and the favorites.
    $tree = $script:Ui.ScriptTree
    $filter = $script:Ui.SearchBox.Text
    $isFiltered = -not [string]::IsNullOrWhiteSpace($filter)

    # Folders the user had opened or collapsed: kept from one rebuild to the next
    $previousExpansion = @{}
    if (-not $isFiltered -and -not $script:State.TreeFiltered) {
        foreach ($key in $script:State.TreeFolders.Keys) {
            $previousExpansion[$key] = $script:State.TreeFolders[$key].IsExpanded
        }
    }

    $tree.Items.Clear()
    $scripts = @(Get-ScriptView -Filter $filter)
    $expand = $isFiltered -or ($scripts.Count -le $script:Settings.AutoExpandLimit)
    $folders = @{}

    if (-not $isFiltered) {
        $scriptByPath = @{}
        foreach ($entry in $scripts) { $scriptByPath[$entry.Path.ToLowerInvariant()] = $entry }
        $userState = $script:State.UserState
        Add-PinnedSection -Title (Get-UiText 'window.section.favorites') -Path $userState.Favorites.ToArray() -ScriptByPath $scriptByPath -Sort
        Add-PinnedSection -Title (Get-UiText 'window.section.recents') -Path $userState.Recents.ToArray() -ScriptByPath $scriptByPath
    }

    if ($isFiltered) {
        # Searching: results are grouped by the field that matched. The reason is written once, as a
        # heading, so rows stay short and nothing needs a horizontal scroll.
        $order = @('name', 'description', 'parameter', 'example', 'help')
        $byKind = [ordered]@{}
        foreach ($entry in $scripts) {
            $kind = Get-ScriptMatchKind -ScriptInfo $entry -Filter $filter
            if (-not $kind) { $kind = 'name' }
            if (-not $byKind.Contains($kind)) { $byKind[$kind] = [System.Collections.Generic.List[object]]::new() }
            $byKind[$kind].Add($entry)
        }
        $currentPath = if ($script:State.Current) { $script:State.Current.Path } else { $null }
        $currentItem = $null
        foreach ($kind in $order) {
            if (-not $byKind.Contains($kind)) { continue }
            $entries = @($byKind[$kind] | Sort-Object -Property Name)
            $group = [System.Windows.Controls.TreeViewItem]::new()
            $groupHeader = [System.Windows.Controls.TextBlock]::new()
            $groupHeader.Text = Get-UiText ('search.group.' + $kind) -Arguments @($entries.Count)
            $groupHeader.FontWeight = [System.Windows.FontWeights]::SemiBold
            $groupHeader.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $group.Header = $groupHeader
            $group.IsExpanded = $true
            foreach ($entry in $entries) {
                $childItem = New-ScriptTreeItem -Entry $entry
                [void]$group.Items.Add($childItem)
                if ($currentPath -and $entry.Path -eq $currentPath) { $currentItem = $childItem }
            }
            [void]$tree.Items.Add($group)
        }
    }
    else {
        # Folders first, sorted segment by segment, then the scripts of each folder
        $directories = [string[]]@(
            $scripts | ForEach-Object { $_.RelativeDirectory } | Where-Object { $_ } | Select-Object -Unique)
        if ($directories.Count -gt 0) {
            # Sort key: separator replaced by U+0001, so that "A\B" sorts before "A-C"
            $keys = [string[]]@($directories | ForEach-Object { $_ -replace '[\\/]', [string][char]1 })
            [Array]::Sort($keys, $directories, [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($directory in $directories) {
                [void](Get-TreeFolderNode -Cache $folders -RelativeDirectory $directory -Expand $expand)
            }
        }
        $currentPath = if ($script:State.Current) { $script:State.Current.Path } else { $null }
        $currentItem = $null
        foreach ($entry in @($scripts | Sort-Object -Property Name)) {
            $item = New-ScriptTreeItem -Entry $entry
            if ($entry.RelativeDirectory) {
                $folder = Get-TreeFolderNode -Cache $folders -RelativeDirectory $entry.RelativeDirectory -Expand $expand
                [void]$folder.Items.Add($item)
            }
            else {
                [void]$tree.Items.Add($item)
            }
            if ($currentPath -and $entry.Path -eq $currentPath) { $currentItem = $item }
        }

    }
    foreach ($key in $previousExpansion.Keys) {
        if ($folders.ContainsKey($key)) { $folders[$key].IsExpanded = $previousExpansion[$key] }
    }
    $script:State.TreeFolders = $folders
    $script:State.TreeFiltered = $isFiltered

    # The displayed script stays selected in the rebuilt tree (the selection handler
    # recognizes the same script and keeps the values already entered)
    if ($currentItem) { $currentItem.IsSelected = $true }
    if ($scripts.Count -eq 0) {
        $empty = [System.Windows.Controls.TreeViewItem]::new()
        $empty.Header = if ($filter) { Get-UiText 'window.tree.noMatch' } else { Get-UiText 'window.tree.noScript' }
        $empty.IsEnabled = $false
        [void]$tree.Items.Add($empty)
    }
}

function Stop-CatalogScan {
    # Abandons the current inventory, if any, and releases its runspace.
    if (-not $script:State) { return }
    if ($script:State.ScanTimer) { $script:State.ScanTimer.Stop() }
    $scan = $script:State.Scan
    $script:State.Scan = $null
    if ($script:Ui -and $script:Ui.ScanProgress) { $script:Ui.ScanProgress.Visibility = [System.Windows.Visibility]::Collapsed }
    if (-not $scan) { return }
    try { $scan.PowerShell.Stop() }
    catch { Write-Verbose "Inventory stop: $($_.Exception.Message)" }
    $scan.PowerShell.Dispose()
}

function Start-CatalogScan {
    # Starts the script inventory in a background runspace: the window stays usable.
    # A timer (Update-CatalogScan) follows the progress and collects the result.
    Stop-CatalogScan

    $progress = [hashtable]::Synchronized(@{ Total = 0; Done = 0 })
    $arguments = @{
        Root             = $script:State.Root
        ExcludePattern   = $script:State.ExcludePattern
        ExcludeFile      = $script:State.LauncherPath
        ExcludeDirectory = @($script:ModuleRoot)
        Progress         = $progress
        Cache            = $script:State.Cache
    }
    # The runspace shares nothing with the window: it loads the string catalog and the analysis
    # functions itself. The language parameter is not called -Language on purpose: Settings.ps1
    # resets $script:Language when it is dot-sourced, which would overwrite the argument.
    $private = Join-Path $script:ModuleRoot 'Private'
    $files = @(
        (Join-Path $private 'Settings.ps1'),
        (Join-Path $private 'Text.ps1'),
        (Join-Path $private 'Cache.ps1'),
        (Join-Path $private 'Analysis.ps1')
    )
    $scanScript = {
        param($Files, $Arguments, $LanguageCode)
        $ErrorActionPreference = 'Stop'
        foreach ($file in $Files) { . $file }
        Set-UiLanguage -Language $LanguageCode
        Get-ScriptCatalog @Arguments
    }
    $powerShell = [powershell]::Create()
    [void]$powerShell.AddScript($scanScript.ToString()).AddArgument($files).AddArgument($arguments).AddArgument($script:Language)
    $script:State.Scan = @{
        PowerShell = $powerShell
        Handle     = $powerShell.BeginInvoke()
        Progress   = $progress
        Watch      = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $bar = $script:Ui.ScanProgress
    # Reduced motion keeps the bar static: the status text already says what is happening
    $bar.IsIndeterminate = -not $script:ReducedMotion
    $bar.Visibility = [System.Windows.Visibility]::Visible
    Set-Status (Get-UiText 'window.status.scanning')
    $script:State.ScanTimer.Start()
}

function Update-CatalogScan {
    # Called by the timer: shows the progress, or completes the inventory once it is done.
    $scan = $script:State.Scan
    if (-not $scan) {
        $script:State.ScanTimer.Stop()
        return
    }
    if (-not $scan.Handle.IsCompleted) {
        $total = [int]$scan.Progress['Total']
        if ($total -gt 0) {
            $done = [int]$scan.Progress['Done']
            $bar = $script:Ui.ScanProgress
            $bar.IsIndeterminate = $false
            $bar.Maximum = $total
            $bar.Value = $done
            Set-Status (Get-UiText 'window.status.scanningOf' -Arguments @($done, $total))
        }
        return
    }
    Complete-CatalogScan
}

function Complete-CatalogScan {
    # Collects the result of the finished inventory and updates the interface.
    $scan = $script:State.Scan
    $script:State.ScanTimer.Stop()
    $script:State.Scan = $null
    $script:Ui.ScanProgress.Visibility = [System.Windows.Visibility]::Collapsed
    try {
        $catalog = @($scan.PowerShell.EndInvoke($scan.Handle)) | Select-Object -First 1
        if (-not $catalog) { throw (Get-UiText 'window.error.catalogEmpty') }
    }
    catch {
        Set-Status (Get-UiText 'window.error.scanFailed' -Arguments @($_.Exception.GetBaseException().Message))
        throw
    }
    finally {
        $scan.PowerShell.Dispose()
    }

    $script:State.Scripts = @($catalog.Scripts)
    $script:State.ScanSeconds = $scan.Watch.Elapsed.TotalSeconds
    # Remember the folder in the recent list (only when it is not already the first one)
    $recent = @($script:State.UserState.RecentRoots)
    if ($recent.Count -eq 0 -or -not [string]::Equals($recent[0], $catalog.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        Edit-UserState { param($state) [void](Add-RecentRoot -State $state -Path $catalog.Root) }
    }
    if ($catalog.Cache) {
        $script:State.Cache = $catalog.Cache
        try { Save-CatalogCache -Path $script:State.CachePath -Cache $catalog.Cache }
        catch { Write-Verbose "Cache not saved: $($_.Exception.Message)" }
    }
    $script:Window.Title = (Get-UiText 'window.title') + ' - ' + $catalog.Root
    $script:Ui.RootText.Text = $catalog.Root
    $script:Ui.RootText.ToolTip = $catalog.Root
    Update-ScriptTree

    $script:State.ScanWarnings = @($script:State.Scripts | Where-Object { (Get-ScriptWarningCount -ScriptInfo $_) -gt 0 }).Count
    $script:State.ScanErrors = @($catalog.ScanErrors).Count
    $statusText = Format-CatalogStatus -Count $script:State.Scripts.Count -Seconds $script:State.ScanSeconds `
        -Warnings $script:State.ScanWarnings -Errors $script:State.ScanErrors
    if ($script:StartupNotice) {
        $statusText += ' · ' + (Get-UiText $script:StartupNotice)
        $script:StartupNotice = $null
    }
    Set-Status $statusText

    # Refresh also reloads the displayed script (parameters or help changed in the meantime)
    $current = $script:State.Current
    if ($current -and (Test-Path -LiteralPath $current.Path)) {
        $refreshed = Get-ScriptInfo -LiteralPath $current.Path -RelativePath $current.RelativePath
        Show-ScriptDetail -ScriptInfo $refreshed
    }
}

function Set-LauncherRoot {
    # Switches to another folder: everything coming from the previous one goes away (tree,
    # selection, filter), the cache of the new folder is loaded and its inventory starts.
    param([Parameter(Mandatory)][string]$Root)

    $script:State.Root = $Root
    $script:State.TreeFolders = @{}
    $script:Ui.ScriptTree.Items.Clear()
    $script:Ui.SearchBox.Text = ''
    $script:State.HelpFilter = 'all'
    Initialize-HelpFilter
    # Cache of the new folder: its tree is usable before the inventory finishes
    $script:State.CachePath = Get-CatalogCachePath -Root $Root -StatePath $script:State.StatePath
    $script:State.Cache = Read-CatalogCache -Path $script:State.CachePath -Root $Root
    $script:State.Scripts = @()
    Reset-ScriptDetail
    $script:Window.Title = (Get-UiText 'window.title') + ' - ' + $Root
    $script:Ui.RootText.Text = $Root
    $script:Ui.RootText.ToolTip = $Root
    [void](Show-CachedCatalog)
    Start-CatalogScan
}

function Select-LauncherRoot {
    # "Folder...": picks a folder in a dialog and switches to it.
    $selected = Select-FolderPath -InitialDirectory $script:State.Root
    if (-not $selected) { return }
    $root = (Resolve-Path -LiteralPath $selected).ProviderPath
    if ($root -eq $script:State.Root) {
        Set-Status (Get-UiText 'window.status.folderShown')
        return
    }
    Set-LauncherRoot -Root $root
}

function Show-RecentRootMenu {
    # "Recent folders": the remembered folders that still exist, plus the launcher folder and
    # the browse dialog.
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $places = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($script:State.UserState.RecentRoots)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { $places.Add($candidate) }
    }
    if ($places.Count -eq 0) {
        $empty = [System.Windows.Controls.MenuItem]::new()
        $empty.Header = Get-UiText 'window.menu.noRecent'
        $empty.IsEnabled = $false
        [void]$menu.Items.Add($empty)
    }
    else {
        foreach ($candidate in $places) {
            $item = [System.Windows.Controls.MenuItem]::new()
            $item.Header = $candidate
            $item.ToolTip = $candidate
            $item.Tag = $candidate
            $item.IsCheckable = [string]::Equals($candidate, $script:State.Root, [System.StringComparison]::OrdinalIgnoreCase)
            $item.IsChecked = $item.IsCheckable
            $item.Add_Click({
                    $menuItem = $this
                    Invoke-UiAction {
                        $target = [string]$menuItem.Tag
                        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                            Set-Status (Get-UiText 'window.error.folderNotFound' -Arguments @($target))
                            return
                        }
                        if ($target -eq $script:State.Root) { Set-Status (Get-UiText 'window.status.folderShown'); return }
                        Set-LauncherRoot -Root $target
                    }
                })
            [void]$menu.Items.Add($item)
        }
    }

    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())

    $launcherItem = [System.Windows.Controls.MenuItem]::new()
    $launcherItem.Header = Get-UiText 'window.menu.launcherFolder'
    $launcherItem.Tag = Split-Path -Parent $script:ModuleRoot
    $launcherItem.Add_Click({
            $menuItem = $this
            Invoke-UiAction { Set-LauncherRoot -Root ([string]$menuItem.Tag) }
        })
    [void]$menu.Items.Add($launcherItem)

    $browseItem = [System.Windows.Controls.MenuItem]::new()
    $browseItem.Header = Get-UiText 'window.menu.browse'
    $browseItem.Add_Click({ Invoke-UiAction { Select-LauncherRoot } })
    [void]$menu.Items.Add($browseItem)

    $script:Ui.RecentButton.ContextMenu = $menu
    $menu.PlacementTarget = $script:Ui.RecentButton
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
}

function Initialize-EngineList {
    # Fills the list of PowerShell engines available on the machine.
    $script:State.Engines = @(Get-PowerShellEngine)
    $script:Ui.EngineCombo.Items.Clear()
    foreach ($engine in $script:State.Engines) {
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        $item.Content = $engine.Name
        $item.Tag = $engine
        [void]$script:Ui.EngineCombo.Items.Add($item)
    }
    if ($script:Ui.EngineCombo.Items.Count -gt 0) { $script:Ui.EngineCombo.SelectedIndex = 0 }
}

function Select-EngineForScript {
    # Picks the engine required by #Requires, otherwise the one running the launcher. Returns a
    # warning when the required engine is missing.
    param([Parameter(Mandatory)]$ScriptInfo)

    $preferred = Get-PreferredEdition -ScriptInfo $ScriptInfo
    $wanted = if ($preferred) { $preferred } else { $script:State.DefaultEdition }
    foreach ($item in $script:Ui.EngineCombo.Items) {
        if ($item.Tag.Edition -eq $wanted) {
            $script:Ui.EngineCombo.SelectedItem = $item
            return ''
        }
    }
    if ($preferred -eq 'Core') { return (Get-UiText 'window.error.coreRequired') }
    ''
}

function Update-FavoriteButton {
    # Favorite button label according to the state of the displayed script.
    $button = $script:Ui.FavoriteButton
    $current = $script:State.Current
    if (-not $current) {
        $button.IsEnabled = $false
        return
    }
    $button.IsEnabled = $true
    $isFavorite = Test-FavoriteScript -State $script:State.UserState -ScriptPath $current.Path
    $button.Content = if ($isFavorite) { Get-UiText 'window.favorite.on' } else { Get-UiText 'window.favorite.off' }
    $button.ToolTip = if ($isFavorite) { Get-UiText 'window.favorite.remove' } else { Get-UiText 'window.favorite.add' }
}

function Switch-CurrentFavorite {
    # Adds the displayed script to the user favorites, or removes it from them.
    $current = $script:State.Current
    if (-not $current) { return }
    Edit-UserState { param($state) [void](Switch-FavoriteScript -State $state -ScriptPath $current.Path) }
    Update-FavoriteButton
    Update-ScriptTree
}

function Restore-RememberedInput {
    # Restores into the form the last input launched for this script. Call it while the
    # form is loading ($script:State.Loading): the command preview is recomputed afterwards.
    param([Parameter(Mandatory)]$ScriptInfo)

    $remembered = Get-RememberedInput -State $script:State.UserState -ScriptPath $ScriptInfo.Path
    if (-not $remembered) { return $false }
    if ($remembered.ParameterSet -and $ScriptInfo.ParameterSets -contains $remembered.ParameterSet) {
        $script:State.CurrentSet = $remembered.ParameterSet
        if ($ScriptInfo.ParameterSets.Count -gt 1) { $script:Ui.SetCombo.SelectedItem = $remembered.ParameterSet }
    }
    $restored = $false
    foreach ($row in $script:State.Rows) {
        $name = $row.Parameter.Name
        if ($remembered.Values.ContainsKey($name)) {
            Set-RowValue -Row $row -Value $remembered.Values[$name]
            $restored = $true
        }
    }
    $restored
}

function Show-CachedCatalog {
    # Paints the tree from the cache before the inventory starts: the window is usable at once,
    # and the background scan then confirms or corrects it.
    $cache = $script:State.Cache
    if ($null -eq $cache -or $cache.Entries.Count -eq 0) { return $false }
    $scripts = foreach ($key in $cache.Entries.Keys) {
        ConvertFrom-CachedScript -Entry $cache.Entries[$key] -Root $script:State.Root
    }
    $script:State.Scripts = @($scripts | Sort-Object -Property RelativePath)
    Update-ScriptTree
    Set-Status (Get-UiText 'window.status.cached' -Arguments @($script:State.Scripts.Count))
    $true
}

function Format-CatalogStatus {
    # Status bar after an inventory: count, duration, warnings, unreadable items.
    param(
        [Parameter(Mandatory)][int]$Count,
        [double]$Seconds = 0,
        [int]$Warnings = 0,
        [int]$Errors = 0
    )

    $message = Get-UiText 'window.status.catalog' -Arguments @($Count, $Seconds)
    if ($Warnings -gt 0) { $message += ' · ' + (Get-UiText 'window.status.warnings' -Arguments @($Warnings)) }
    if ($Errors -gt 0) { $message += ' · ' + (Get-UiText 'window.status.errors' -Arguments @($Errors)) }
    $message
}

function Set-UiText {
    # Fills every fixed label of the window from the active catalog. Called at startup, and
    # again after a language change.
    $ui = $script:Ui
    $script:Window.Title = Get-UiText 'window.title'
    $ui.SearchHint.Text = Get-UiText 'window.search.hint'
    $ui.FolderButton.Content = Get-UiText 'window.button.folder'
    $ui.FolderButton.ToolTip = Get-UiText 'window.button.folder.tip'
    $ui.RecentButton.ToolTip = Get-UiText 'window.button.recent.tip'
    $ui.RefreshButton.Content = Get-UiText 'window.button.refresh'
    $ui.ParamTab.Header = Get-UiText 'window.tab.parameters'
    $ui.HelpTab.Header = Get-UiText 'window.tab.help'
    $ui.SetLabel.Text = Get-UiText 'window.label.parameterset'
    $ui.ExampleLabel.Text = Get-UiText 'window.label.example'
    $ui.ExtraArgsLabel.Text = Get-UiText 'window.label.extra'
    $ui.CommandLabel.Text = Get-UiText 'window.label.command'
    $ui.EngineLabel.Text = Get-UiText 'window.label.engine'
    $ui.WhatIfCheck.Content = Get-UiText 'window.check.whatif'
    $ui.NoExitCheck.Content = Get-UiText 'window.check.noexit'
    $ui.NoProfileCheck.Content = Get-UiText 'window.check.noprofile'
    $ui.ElevateCheck.Content = Get-UiText 'window.check.elevate'
    $ui.ResetButton.Content = Get-UiText 'window.button.reset'
    $ui.LocateButton.Content = Get-UiText 'window.button.locate'
    $ui.CopyButton.Content = Get-UiText 'window.button.copy'
    $ui.RunButton.Content = Get-UiText 'window.button.run'
    $ui.LanguageCombo.ToolTip = Get-UiText 'window.language.tooltip'
    $ui.ThemeCombo.ToolTip = Get-UiText 'window.theme.tooltip'
    $ui.AccessButton.Content = Get-UiText 'window.button.access'
    $ui.AccessButton.ToolTip = Get-UiText 'window.access.tip'
    $ui.ShortcutsButton.Content = Get-UiText 'window.button.shortcuts'
    $ui.ShortcutsButton.ToolTip = Get-UiText 'window.shortcuts.tip'
    Initialize-ThemeList
    $ui.HelpReportButton.Content = Get-UiText 'window.button.helpReport'
    $ui.HelpReportButton.ToolTip = Get-UiText 'window.button.helpReport.tip'
    $ui.HelpFilterCombo.ToolTip = Get-UiText 'window.filter.help.tip'
    $ui.EditButton.Content = Get-UiText 'window.button.edit'
    $ui.EditButton.ToolTip = Get-UiText 'window.button.edit.tip'
    Initialize-HelpFilter
    if ($script:State.Current) { Update-FavoriteButton }
    else {
        $ui.ScriptTitle.Text = Get-UiText 'window.empty.title'
        $ui.FavoriteButton.Content = Get-UiText 'window.favorite.off'
    }
}

function Initialize-ThemeList {
    # Theme list: Auto (follows Windows), Light, Dark. Rebuilt when the language changes.
    $combo = $script:Ui.ThemeCombo
    $preference = [string]$script:State.UserState.Theme
    if (-not $preference) { $preference = 'auto' }
    $script:State.FilterLoading = $true
    try {
        $combo.Items.Clear()
        foreach ($code in 'auto', 'light', 'dark') {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = Get-UiText ('window.theme.' + $code)
            $item.Tag = $code
            [void]$combo.Items.Add($item)
            if ($code -eq $preference) { $combo.SelectedItem = $item }
        }
        if ($null -eq $combo.SelectedItem -and $combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    }
    finally { $script:State.FilterLoading = $false }
}

function Set-AccessibleLabel {
    # Names announced by a screen reader for the controls that have no visible label of their own.
    $ui = $script:Ui
    [System.Windows.Automation.AutomationProperties]::SetName($ui.SearchBox, (Get-UiText 'window.search.hint'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.ScriptTree, (Get-UiText 'window.a11y.tree'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.RecentButton, (Get-UiText 'window.button.recent.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.FolderButton, (Get-UiText 'window.button.folder.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.HelpReportButton, (Get-UiText 'window.button.helpReport'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.HelpFilterCombo, (Get-UiText 'window.filter.help.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.LanguageCombo, (Get-UiText 'window.language.tooltip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.ThemeCombo, (Get-UiText 'window.theme.tooltip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.AccessButton, (Get-UiText 'window.access.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.ShortcutsButton, (Get-UiText 'window.shortcuts.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.EditButton, (Get-UiText 'window.button.edit.tip'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.CommandBox, (Get-UiText 'window.label.command'))
    [System.Windows.Automation.AutomationProperties]::SetName($ui.HelpText, (Get-UiText 'window.tab.help'))
}

function Switch-UiTheme {
    # Theme picked in the list: remembered, applied, then the dynamic parts are rebuilt so the
    # colours baked into tree items and parameter rows follow.
    $item = $script:Ui.ThemeCombo.SelectedItem
    if ($null -eq $item) { return }
    $code = [string]$item.Tag
    if ($code -eq [string]$script:State.UserState.Theme) { return }

    Edit-UserState { param($state) $state.Theme = $code }
    $current = $script:State.Current
    $values = @{}
    foreach ($row in $script:State.Rows) { $values[$row.Parameter.Name] = Get-RowValue -Row $row }

    Set-UiTheme -Name (Resolve-UiTheme -Theme $code)
    Update-ScriptTree
    if ($current) {
        Show-ScriptDetail -ScriptInfo $current -NoRestore
        foreach ($row in $script:State.Rows) {
            if ($values.ContainsKey($row.Parameter.Name)) { Set-RowValue -Row $row -Value $values[$row.Parameter.Name] }
        }
        Update-ParameterVisibility
        Update-CommandPreview
    }
}

function New-AccessibilityItem {
    # One checkable entry of the accessibility menu; Tag carries the setting it switches.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Text,
        [bool]$Checked,
        [bool]$Enabled = $true,
        [string]$ToolTip
    )

    $item = [System.Windows.Controls.MenuItem]::new()
    $item.Header = $Text
    $item.IsCheckable = $true
    $item.IsChecked = $Checked
    $item.IsEnabled = $Enabled
    $item.Tag = $Key
    if ($ToolTip) { $item.ToolTip = $ToolTip }
    $item.Add_Click({
            $menuItem = $this
            Invoke-UiAction { Switch-AccessibilitySetting -Key ([string]$menuItem.Tag) }
        })
    $item
}

function Show-AccessibilityMenu {
    # The accessibility settings, as a checkable menu: what is on is visible at a glance.
    $state = $script:State.UserState
    $menu = [System.Windows.Controls.ContextMenu]::new()

    $dyslexicAvailable = Test-DyslexicFontAvailable
    $dyslexicTip = ''
    if (-not $dyslexicAvailable) { $dyslexicTip = Get-UiText 'window.access.dyslexicMissing' }
    [void]$menu.Items.Add((New-AccessibilityItem -Key 'contrast' -Text (Get-UiText 'window.access.contrast') `
                -Checked $state.HighContrast))
    [void]$menu.Items.Add((New-AccessibilityItem -Key 'dyslexic' -Text (Get-UiText 'window.access.dyslexic') `
                -Checked $state.DyslexicFont -Enabled $dyslexicAvailable -ToolTip $dyslexicTip))

    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())

    foreach ($percent in 100, 115, 130, 150) {
        $scale = $percent / 100
        $label = Get-UiText 'window.access.fontScale' -Arguments @($percent)
        $item = New-AccessibilityItem -Key ('scale-' + $percent) -Text $label `
            -Checked ([math]::Abs([double]$state.FontScale - $scale) -lt 0.01)
        [void]$menu.Items.Add($item)
    }

    [void]$menu.Items.Add([System.Windows.Controls.Separator]::new())

    [void]$menu.Items.Add((New-AccessibilityItem -Key 'motion' -Text (Get-UiText 'window.access.reduceMotion') `
                -Checked $state.ReduceMotion))
    [void]$menu.Items.Add((New-AccessibilityItem -Key 'focus' -Text (Get-UiText 'window.access.thickFocus') `
                -Checked $state.ThickFocus))
    [void]$menu.Items.Add((New-AccessibilityItem -Key 'roomy' -Text (Get-UiText 'window.access.roomy') `
                -Checked $state.RoomyLayout))

    $script:Ui.AccessButton.ContextMenu = $menu
    $menu.PlacementTarget = $script:Ui.AccessButton
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
}

function Set-Accessibility {
    # Applies every accessibility preference, then rebuilds the parts built in code so the new
    # font size and the new colours reach the tree and the parameter rows.
    $state = $script:State.UserState
    $current = $script:State.Current
    $values = @{}
    foreach ($row in $script:State.Rows) { $values[$row.Parameter.Name] = Get-RowValue -Row $row }

    Set-UiFont -Dyslexic ([bool]$state.DyslexicFont)
    Set-UiFontScale -Scale ([double]$state.FontScale)
    Set-UiDensity -Roomy ([bool]$state.RoomyLayout)
    Set-UiAccessibilityFrame -Thick ([bool]$state.ThickFocus)
    Set-UiTheme -Name (Get-EffectiveTheme -State $state)
    Set-UiMotion -Reduced ([bool]$state.ReduceMotion)

    Update-ScriptTree
    if ($current) {
        Show-ScriptDetail -ScriptInfo $current -NoRestore
        foreach ($row in $script:State.Rows) {
            if ($values.ContainsKey($row.Parameter.Name)) { Set-RowValue -Row $row -Value $values[$row.Parameter.Name] }
        }
        Update-ParameterVisibility
        Update-CommandPreview
    }
}

function Switch-AccessibilitySetting {
    # Toggles one setting, remembers it, and repaints.
    param([Parameter(Mandatory)][string]$Key)

    # Named carefully: Edit-UserState binds its own $state, and dynamic scoping would make the
    # block below read that one instead of the preferences being edited.
    $userState = $script:State.UserState
    switch -Regex ($Key) {
        '^contrast$' { $userState.HighContrast = -not $userState.HighContrast }
        '^dyslexic$' { $userState.DyslexicFont = -not $userState.DyslexicFont }
        '^motion$' { $userState.ReduceMotion = -not $userState.ReduceMotion }
        '^focus$' { $userState.ThickFocus = -not $userState.ThickFocus }
        '^roomy$' { $userState.RoomyLayout = -not $userState.RoomyLayout }
        '^scale-(\d+)$' { $userState.FontScale = [double]$Matches[1] / 100 }
        default { return }
    }

    $contrast = [bool]$userState.HighContrast
    $scale = [double]$userState.FontScale
    $dyslexic = [bool]$userState.DyslexicFont
    $motion = [bool]$userState.ReduceMotion
    $focus = [bool]$userState.ThickFocus
    $roomy = [bool]$userState.RoomyLayout
    Edit-UserState {
        param($saved)
        $saved.HighContrast = $contrast
        $saved.FontScale = $scale
        $saved.DyslexicFont = $dyslexic
        $saved.ReduceMotion = $motion
        $saved.ThickFocus = $focus
        $saved.RoomyLayout = $roomy
    }
    Set-Accessibility
}

function Initialize-LanguageList {
    # Language selector: one entry per catalog, current language selected.
    $combo = $script:Ui.LanguageCombo
    $combo.Items.Clear()
    foreach ($code in Get-AvailableLanguage) {
        $item = [System.Windows.Controls.ComboBoxItem]::new()
        $item.Content = Get-UiLanguageName -Code $code
        $item.Tag = $code
        [void]$combo.Items.Add($item)
        if ($code -eq $script:Language) { $combo.SelectedItem = $item }
    }
}

function Switch-UiLanguage {
    # Language picked in the window: load the catalog, refresh the texts and keep the selected
    # script together with the values already typed. The choice is remembered for the next run.
    $item = $script:Ui.LanguageCombo.SelectedItem
    if ($null -eq $item) { return }
    $code = [string]$item.Tag
    if (-not $code -or $code -eq $script:Language) { return }

    Edit-UserState { param($state) $state.Language = $code }
    Set-UiLanguage -Language $code

    $current = $script:State.Current
    $values = @{}
    foreach ($row in $script:State.Rows) { $values[$row.Parameter.Name] = Get-RowValue -Row $row }

    Set-UiText
    Update-ScriptTree
    if ($current) {
        Show-ScriptDetail -ScriptInfo $current -NoRestore
        foreach ($row in $script:State.Rows) {
            if ($values.ContainsKey($row.Parameter.Name)) { Set-RowValue -Row $row -Value $values[$row.Parameter.Name] }
        }
        Update-ParameterVisibility
        Update-CommandPreview
    }
    Set-Status (Format-CatalogStatus -Count $script:State.Scripts.Count -Seconds $script:State.ScanSeconds `
        -Warnings $script:State.ScanWarnings -Errors $script:State.ScanErrors)
}

function Reset-ScriptDetail {
    # Right-hand side at rest: no script displayed (startup, or folder change).
    $ui = $script:Ui
    $script:State.Current = $null
    $script:State.CurrentSet = ''
    $script:State.Rows = @()
    $script:State.LastCommand = $null
    $ui.ScriptTitle.Text = Get-UiText 'window.empty.title'
    $ui.ScriptPath.Text = ''
    $ui.ScriptPath.ToolTip = $null
    $ui.ScriptSynopsis.Text = ''
    Set-OptionalText -Element $ui.ScriptInfo -Text ''
    Set-OptionalText -Element $ui.ScriptWarning -Text ''
    Set-OptionalText -Element $ui.HelpGapsText -Text ''
    $ui.ScriptDescription.Text = ''
    $ui.DescriptionPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.HelpText.Text = ''
    $ui.SearchMatchText.Text = ''
    $ui.SearchMatchText.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.SetCombo.Items.Clear()
    $ui.SetPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ExampleCombo.Items.Clear()
    $ui.ExamplePanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ParamPanel.Children.Clear()
    $ui.VerboseCheck.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.WhatIfCheck.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.CommandBox.Text = ''
    foreach ($button in @($ui.RunButton, $ui.CopyButton, $ui.LocateButton, $ui.EditButton, $ui.ResetButton)) { $button.IsEnabled = $false }
    $ui.FavoriteButton.IsEnabled = $false
    $ui.FavoriteButton.Content = Get-UiText 'window.favorite.off'
    $ui.DetailTabs.SelectedIndex = 0
}

function Show-ScriptDetail {
    # Displays a script: header, help, parameter form, launch options.
    # -NoRestore: empty form, without restoring the last remembered input.
    param([Parameter(Mandatory)]$ScriptInfo, [switch]$NoRestore)

    $ui = $script:Ui
    $restored = $false
    $script:State.Loading = $true
    try {
        $script:State.Current = $ScriptInfo
        $ui.ScriptTitle.Text = $ScriptInfo.BaseName
        $ui.ScriptPath.Text = $ScriptInfo.RelativePath
        $ui.ScriptPath.ToolTip = $ScriptInfo.Path
        if ($ScriptInfo.Synopsis) {
            $ui.ScriptSynopsis.Text = $ScriptInfo.Synopsis
            $ui.ScriptSynopsis.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
        }
        else {
            $ui.ScriptSynopsis.Text = Get-UiText 'window.detail.noHelp'
            $ui.ScriptSynopsis.Foreground = Get-ThemeBrush 'Muted'
        }
        Set-OptionalText -Element $ui.ScriptInfo -Text (Get-RequirementSummary -ScriptInfo $ScriptInfo)
        $warnings = @($ScriptInfo.Warnings) + @(Select-EngineForScript -ScriptInfo $ScriptInfo) | Where-Object { $_ }
        Set-OptionalText -Element $ui.ScriptWarning -Text (@($warnings) -join [Environment]::NewLine)
        $gaps = Format-HelpGapText -ScriptInfo $ScriptInfo
        Set-OptionalText -Element $ui.HelpGapsText -Text $(if ($gaps) { Get-UiText 'window.helpGaps.label' -Arguments @($gaps) } else { '' })
        Update-FavoriteButton

        $ui.ScriptDescription.Text = $ScriptInfo.Description
        $ui.DescriptionPanel.Visibility = if ($ScriptInfo.Description) { 'Visible' } else { 'Collapsed' }

        $ui.HelpText.Text = Format-ScriptHelp -ScriptInfo $ScriptInfo
        $ui.HelpText.ScrollToHome()

        # First match of the current search, highlighted in the help page. The selection stays
        # inactive, so the caret is not stolen from the search box.
        $ui.HelpText.IsInactiveSelectionHighlightEnabled = $true
        $searchTerms = @()
        if ($script:Ui.SearchBox) { $searchTerms = @(([string]$script:Ui.SearchBox.Text).Trim() -split '\s+' | Where-Object { $_ }) }
        $firstTerm = if ($searchTerms.Count -gt 0) { $searchTerms[0] } else { '' }
        $matchIndex = -1
        if ($firstTerm) {
            $matchIndex = $ui.HelpText.Text.IndexOf($firstTerm, [System.StringComparison]::CurrentCultureIgnoreCase)
        }
        if ($matchIndex -ge 0) { $ui.HelpText.Select($matchIndex, $firstTerm.Length) }
        else { $ui.HelpText.Select(0, 0) }

        # Why this script came up, spelled out under the synopsis with the sentence that matched
        $reason = ''
        $snippet = ''
        if ($firstTerm) {
            $reason = Get-ScriptMatchReason -ScriptInfo $ScriptInfo -Filter ([string]$ui.SearchBox.Text)
            if ($reason) { $snippet = Get-ScriptMatchSnippet -ScriptInfo $ScriptInfo -Filter ([string]$ui.SearchBox.Text) }
        }
        if ($reason) {
            $ui.SearchMatchText.Text = Get-UiText 'window.detail.matchIn' -Arguments @($reason, $snippet)
            $ui.SearchMatchText.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $ui.SearchMatchText.Text = ''
            $ui.SearchMatchText.Visibility = [System.Windows.Visibility]::Collapsed
        }

        $ui.SetCombo.Items.Clear()
        $script:State.CurrentSet = $ScriptInfo.DefaultParameterSet
        if ($ScriptInfo.ParameterSets.Count -gt 1) {
            foreach ($set in $ScriptInfo.ParameterSets) { [void]$ui.SetCombo.Items.Add($set) }
            $ui.SetCombo.SelectedItem = $ScriptInfo.DefaultParameterSet
            $ui.SetPanel.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $ui.SetPanel.Visibility = [System.Windows.Visibility]::Collapsed
        }

        # Examples usable to fill the form
        $ui.ExampleCombo.Items.Clear()
        [void]$ui.ExampleCombo.Items.Add((Get-UiText 'window.example.placeholder'))
        foreach ($example in $ScriptInfo.Examples) {
            $label = ($example.Code -split '\n')[0].Trim()
            $max = $script:Settings.MaxExampleLabel
            if ($label.Length -gt $max) { $label = $label.Substring(0, $max) + '...' }
            [void]$ui.ExampleCombo.Items.Add("Exemple $($example.Number) : $label")
        }
        $ui.ExampleCombo.SelectedIndex = 0
        $ui.ExamplePanel.Visibility = if (@($ScriptInfo.Examples).Count -gt 0) { 'Visible' } else { 'Collapsed' }

        $ui.ParamPanel.Children.Clear()
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($parameter in $ScriptInfo.Parameters) {
            if ($parameter.DontShow) { continue }
            $row = New-ParameterRow -Parameter $parameter
            $rows.Add($row)
            [void]$ui.ParamPanel.Children.Add($row.Panel)
        }
        $script:State.Rows = $rows.ToArray()
        if ($rows.Count -eq 0) {
            $none = [System.Windows.Controls.TextBlock]::new()
            $none.Text = Get-UiText 'window.detail.noParameter'
            $none.Foreground = [System.Windows.Media.Brushes]::Gray
            $none.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
            [void]$ui.ParamPanel.Children.Add($none)
        }

        $ui.VerboseCheck.IsChecked = $false
        $ui.VerboseCheck.Visibility = if ($ScriptInfo.IsAdvanced) { 'Visible' } else { 'Collapsed' }
        $ui.WhatIfCheck.IsChecked = $false
        $ui.WhatIfCheck.Visibility = if ($ScriptInfo.SupportsShouldProcess) { 'Visible' } else { 'Collapsed' }
        $ui.ExtraArgsBox.Text = ''
        $ui.ElevateCheck.IsChecked = [bool]$ScriptInfo.Requirements.RunAsAdmin
        foreach ($button in @($ui.RunButton, $ui.CopyButton, $ui.LocateButton, $ui.EditButton, $ui.ResetButton)) { $button.IsEnabled = $true }
        $ui.DetailTabs.SelectedIndex = 0

        if (-not $NoRestore) { $restored = Restore-RememberedInput -ScriptInfo $ScriptInfo }
    }
    finally {
        $script:State.Loading = $false
    }
    Update-ParameterVisibility
    if ($restored) { Set-Status (Get-UiText 'window.status.inputRestored') }
}

function Set-FormFromExample {
    # Fills the form with the arguments of one .EXAMPLE of the displayed script.
    param([Parameter(Mandatory)][int]$Number)

    $info = $script:State.Current
    $example = @($info.Examples | Where-Object { $_.Number -eq $Number }) | Select-Object -First 1
    if (-not $example) { return }
    $ignored = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $example.Ignored) { $ignored.Add($item) }

    $script:State.Loading = $true
    try {
        foreach ($row in $script:State.Rows) { Set-RowValue -Row $row -Value $null }

        # Parameter set: the first one that contains all the parameters of the example
        $names = @($example.Arguments.Keys)
        $candidates = @($info.DefaultParameterSet) + @($info.ParameterSets) | Where-Object { $_ } | Select-Object -Unique
        foreach ($set in $candidates) {
            $outside = @($info.Parameters | Where-Object {
                    $_.Name -in $names -and $null -eq (Get-ParameterSetMembership -Parameter $_ -ParameterSet $set)
                })
            if ($outside.Count -eq 0) {
                $script:State.CurrentSet = $set
                if ($info.ParameterSets.Count -gt 1) { $script:Ui.SetCombo.SelectedItem = $set }
                break
            }
        }

        foreach ($name in $names) {
            $row = @($script:State.Rows | Where-Object { $_.Parameter.Name -eq $name }) | Select-Object -First 1
            $argument = $example.Arguments[$name]
            if (-not $row) { $ignored.Add("-$name") }
            elseif (-not (Set-RowFromExample -Row $row -Argument $argument)) {
                $ignored.Add((Get-UiText 'window.example.toEnter' -Arguments @($name, $argument.Text)))
            }
        }
    }
    finally {
        $script:State.Loading = $false
    }
    Update-ParameterVisibility
    $message = Get-UiText 'window.example.applied' -Arguments @($Number)
    if ($ignored.Count -gt 0) { $message += ' ' + (Get-UiText 'window.example.ignored' -Arguments @(($ignored -join ' ; '))) }
    Set-Status $message
}

function Clear-ScriptForm {
    # Clears the form and forgets the remembered input for the displayed script.
    $current = $script:State.Current
    if (-not $current) { return }
    Edit-UserState { param($state) Remove-RememberedInput -State $state -ScriptPath $current.Path }
    Show-ScriptDetail -ScriptInfo $current -NoRestore
    Set-Status (Get-UiText 'window.status.inputCleared')
}

function Save-CurrentInput {
    # Remembers the input of the script just launched (non-sensitive values of the current set)
    # and puts it at the top of the recent scripts.
    $current = $script:State.Current
    $set = $script:State.CurrentSet
    $values = @{}
    foreach ($row in $script:State.Rows) {
        if ($null -eq (Get-ParameterSetMembership -Parameter $row.Parameter -ParameterSet $set)) { continue }
        $stored = ConvertTo-StoredValue -Parameter $row.Parameter -Value (Get-RowValue -Row $row)
        if ($null -ne $stored) { $values[$row.Parameter.Name] = $stored }
    }
    Edit-UserState {
        param($state)
        Set-RememberedInput -State $state -ScriptPath $current.Path -ParameterSet $set -Values $values
    }
    Update-ScriptTree
}

function Start-SelectedScript {
    # Launches the displayed script in a new console, after confirmation on incomplete input.
    $selected = $script:State.Current
    if ($null -eq $selected) { return }
    Update-CommandPreview
    $result = $script:State.LastCommand

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($result.Missing.Count -gt 0) {
        $issues.Add((Get-UiText 'window.confirm.missing' -Arguments @(($result.Missing -join ', '))) +
            [Environment]::NewLine + (Get-UiText 'window.confirm.willAsk'))
    }
    foreach ($name in $result.Errors.Keys) { $issues.Add("-$name : " + ($result.Errors[$name] -join ' ; ')) }
    if ($issues.Count -gt 0) {
        $blankLine = [Environment]::NewLine * 2
        $text = ($issues -join $blankLine) + $blankLine + (Get-UiText 'window.confirm.runAnyway')
        $answer = [System.Windows.MessageBox]::Show($script:Window, $text, (Get-UiText 'window.confirm.title'),
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $engineItem = $script:Ui.EngineCombo.SelectedItem
    if ($null -eq $engineItem) { throw (Get-UiText 'window.error.noEngine') }
    $elevate = ($script:Ui.ElevateCheck.IsChecked -eq $true)
    $scriptPath = $selected.Path
    $workingDirectory = $selected.Directory
    if ($elevate) {
        $scriptPath = Resolve-NetworkPath -Path $scriptPath
        $workingDirectory = Resolve-NetworkPath -Path $workingDirectory
    }
    $commandText = '& ' + (ConvertTo-PSQuotedString $scriptPath)
    if ($result.ArgumentText) { $commandText += ' ' + $result.ArgumentText }
    $launchParameters = @{
        CommandText      = $commandText
        Title            = $selected.BaseName
        WorkingDirectory = $workingDirectory
        NoExit           = ($script:Ui.NoExitCheck.IsChecked -eq $true)
        NoProfile        = ($script:Ui.NoProfileCheck.IsChecked -eq $true)
    }
    $arguments = New-LaunchArgumentString @launchParameters

    $enginePath = $engineItem.Tag.Path
    $length = $enginePath.Length + $arguments.Length + 3
    if ($length -gt $script:Settings.MaxCommandLineLength) {
        throw (Get-UiText 'window.error.commandTooLong' -Arguments @($length, $script:Settings.MaxCommandLineLength))
    }

    try {
        Start-ScriptProcess -FilePath $enginePath -Arguments $arguments -WorkingDirectory $workingDirectory `
            -Elevate:$elevate
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.ComponentModel.Win32Exception] -and $inner.NativeErrorCode -eq 1223) {
            Set-Status (Get-UiText 'window.status.elevationCancelled')
            return
        }
        throw
    }
    Save-CurrentInput
    Set-Status (Get-UiText 'window.status.scriptLaunched' -Arguments @($selected.Name, (Get-Date -Format 'HH:mm:ss')))
}

function Copy-CommandToClipboard {
    # Copies the generated command to the clipboard.
    $text = $script:Ui.CommandBox.Text
    if (-not $text) { return }
    [System.Windows.Clipboard]::SetDataObject($text, $true)     # retries if the clipboard is busy
    Set-Status (Get-UiText 'window.status.commandCopied')
}

function Get-ScriptEditor {
    # Editor used by Edit: VS Code when it is installed, notepad otherwise.
    foreach ($candidate in 'code', 'code-insiders') {
        if (Get-Command -Name $candidate -ErrorAction SilentlyContinue) { return $candidate }
    }
    'notepad.exe'
}

function Open-ScriptEditor {
    # Opens a script in the editor: the displayed one by default.
    param([string]$Path)

    if (-not $Path) {
        $current = $script:State.Current
        if ($null -eq $current) { return }
        $Path = $current.Path
    }
    Start-Process -FilePath (Get-ScriptEditor) -ArgumentList ('"' + $Path + '"') | Out-Null
    Set-Status (Get-UiText 'window.status.editing' -Arguments @((Split-Path -Leaf $Path)))
}

function Show-ScriptLocation {
    # Opens Explorer on the folder of a script (the displayed one by default), file selected.
    param([string]$Path)

    if (-not $Path) {
        $current = $script:State.Current
        if ($null -eq $current) { return }
        $Path = $current.Path
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'explorer.exe'
    $startInfo.Arguments = '/select,"' + $Path + '"'
    [void][System.Diagnostics.Process]::Start($startInfo)
}

function Register-UiEvent {
    # The handlers run after this function returns, so they only use
    # script-scoped variables.
    $ui = $script:Ui

    $script:State.SearchTimer.Add_Tick({
            $script:State.SearchTimer.Stop()
            Invoke-UiAction { Update-ScriptTree }
        })
    $ui.SearchBox.Add_TextChanged({
            $hasText = $script:Ui.SearchBox.Text.Length -gt 0
            $script:Ui.SearchHint.Visibility = if ($hasText) { 'Collapsed' } else { 'Visible' }
            $script:State.SearchTimer.Stop()
            $script:State.SearchTimer.Start()
        })
    $ui.ScriptTree.Add_SelectedItemChanged({
            Invoke-UiAction {
                $item = $script:Ui.ScriptTree.SelectedItem
                if ($null -eq $item -or $null -eq $item.Tag) { return }
                $entry = $item.Tag
                # Same script (tree rebuilt by the search): the values entered are kept
                if ($script:State.Current -and $script:State.Current.Path -eq $entry.Path) { return }
                # Full analysis on selection: also re-reads changes made since the inventory
                $selectedInfo = Get-ScriptInfo -LiteralPath $entry.Path -RelativePath $entry.RelativePath
                Show-ScriptDetail -ScriptInfo $selectedInfo
            }
        })
    $ui.SetCombo.Add_SelectionChanged({
            if ($script:State.Loading) { return }
            Invoke-UiAction {
                $script:State.CurrentSet = [string]$script:Ui.SetCombo.SelectedItem
                Update-ParameterVisibility
            }
        })
    $ui.VerboseCheck.Add_Click({ Invoke-UiAction { Update-CommandPreview } })
    $ui.WhatIfCheck.Add_Click({ Invoke-UiAction { Update-CommandPreview } })
    $ui.ExtraArgsBox.Add_TextChanged({ Invoke-UiAction { Update-CommandPreview } })
    $ui.RunButton.Add_Click({ Invoke-UiAction { Start-SelectedScript } })
    $ui.CopyButton.Add_Click({ Invoke-UiAction { Copy-CommandToClipboard } })
    $ui.LocateButton.Add_Click({ Invoke-UiAction { Show-ScriptLocation } })
    $ui.RefreshButton.Add_Click({ Invoke-UiAction { Start-CatalogScan } })
    $ui.FolderButton.Add_Click({ Invoke-UiAction { Select-LauncherRoot } })
    $ui.RecentButton.Add_Click({ Invoke-UiAction { Show-RecentRootMenu } })
    $ui.HelpFilterCombo.Add_SelectionChanged({
            if ($script:State.FilterLoading) { return }
            Invoke-UiAction { Set-HelpFilter }
        })
    $ui.HelpReportButton.Add_Click({ Invoke-UiAction { Show-HelpReport } })
    $ui.EditButton.Add_Click({ Invoke-UiAction { Open-ScriptEditor } })
    # Keyboard versus mouse: decides whether a focus ring is drawn
    $script:Window.Add_PreviewKeyDown({ Set-UiFocusRing -FromKeyboard $true })
    $script:Window.Add_PreviewMouseDown({ Set-UiFocusRing -FromKeyboard $false })

    $ui.AccessButton.Add_Click({ Invoke-UiAction { Show-AccessibilityMenu } })
    $ui.ShortcutsButton.Add_Click({ Invoke-UiAction { Show-ShortcutHelp } })
    $ui.ThemeCombo.Add_SelectionChanged({
            if ($script:State.FilterLoading) { return }
            Invoke-UiAction { Switch-UiTheme }
        })
    $ui.LanguageCombo.Add_SelectionChanged({
            if ($script:State.Loading) { return }
            Invoke-UiAction { Switch-UiLanguage }
        })
    $ui.FavoriteButton.Add_Click({ Invoke-UiAction { Switch-CurrentFavorite } })
    $ui.ResetButton.Add_Click({ Invoke-UiAction { Clear-ScriptForm } })
    $ui.ExampleCombo.Add_SelectionChanged({
            if ($script:State.Loading) { return }
            Invoke-UiAction {
                $index = $script:Ui.ExampleCombo.SelectedIndex
                if ($index -lt 1) { return }
                $example = @($script:State.Current.Examples)[$index - 1]
                Set-FormFromExample -Number $example.Number
            }
        })
    $script:State.ScanTimer.Add_Tick({ Invoke-UiAction { Update-CatalogScan } })
    $script:Window.Add_Closed({ Stop-CatalogScan })

    $script:Window.Add_PreviewKeyDown({
            $keyArgs = $args[1]
            $isControl = [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control
            if ($keyArgs.Key -eq [System.Windows.Input.Key]::F5) {
                $keyArgs.Handled = $true
                Invoke-UiAction { Start-CatalogScan }
            }
            elseif ($keyArgs.Key -eq [System.Windows.Input.Key]::O -and $isControl) {
                $keyArgs.Handled = $true
                Invoke-UiAction { Select-LauncherRoot }
            }
            elseif ($keyArgs.Key -eq [System.Windows.Input.Key]::F -and $isControl) {
                $keyArgs.Handled = $true
                [void]$script:Ui.SearchBox.Focus()
                $script:Ui.SearchBox.SelectAll()
            }
            elseif ($keyArgs.Key -eq [System.Windows.Input.Key]::Enter -and $isControl) {
                $keyArgs.Handled = $true
                Invoke-UiAction { Start-SelectedScript }
            }
        })
    $script:Window.Add_ContentRendered({
            if ($script:State.Loaded) { return }
            $script:State.Loaded = $true
            [void]$script:Ui.SearchBox.Focus()
            Invoke-UiAction { Start-CatalogScan }
        })
}

function Set-UiFocusRing {
    # A click leaves no ring; the keyboard draws one. With the thicker outline enabled the ring
    # stays on, which is what that setting is for.
    param([bool]$FromKeyboard)

    $script:KeyboardCues = $FromKeyboard
    if (-not $script:Window) { return }
    $ring = [System.Windows.Media.Brushes]::Transparent
    if ($FromKeyboard -or $script:ThickFocus) { $ring = Get-ThemeBrush 'Accent' }
    $script:Window.Resources['FocusRingBrush'] = $ring
}

function Initialize-LauncherWindow {
    # Loads the window (XAML), references its named elements and wires the events.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xamlPath = Join-Path $script:ModuleRoot 'MainWindow.xaml'
    $script:Window = [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($xamlPath))
    Add-UiStyle -Window $script:Window
    $script:Ui = @{}
    $names = @(
        'SearchBox', 'SearchHint', 'RootText', 'ScriptTree', 'StatusText', 'RefreshButton', 'FolderButton',
        'LanguageCombo', 'ThemeCombo', 'RecentButton', 'ScriptTitle', 'ScriptPath',
        'ScriptSynopsis', 'ScriptInfo', 'ScriptWarning', 'DetailTabs', 'DescriptionPanel', 'ScriptDescription',
        'SetPanel', 'SetCombo', 'ParamPanel', 'VerboseCheck', 'WhatIfCheck', 'ExtraArgsBox', 'HelpText',
        'CommandBox', 'EngineCombo', 'NoExitCheck', 'NoProfileCheck', 'ElevateCheck', 'LocateButton',
        'CopyButton', 'RunButton', 'ResetButton', 'FavoriteButton', 'ScanProgress', 'ExamplePanel', 'ExampleCombo',
        'ParamTab', 'HelpTab', 'SetLabel', 'ExampleLabel', 'ExtraArgsLabel', 'CommandLabel', 'EngineLabel',
        'HelpFilterCombo', 'HelpReportButton', 'HelpGapsText', 'EditButton', 'AccessButton', 'ShortcutsButton',
        'SearchMatchText'
    )
    foreach ($name in $names) {
        $element = $script:Window.FindName($name)
        if ($null -eq $element) { throw (Get-UiText 'window.error.uiElement' -Arguments @($name)) }
        $script:Ui[$name] = $element
    }
    $script:State.SearchTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.SearchTimer.Interval = [TimeSpan]::FromMilliseconds($script:Settings.SearchDelayMs)
    $script:State.ScanTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.ScanTimer.Interval = [TimeSpan]::FromMilliseconds($script:Settings.ScanPollMs)
    # A window smaller than the work area, so the buttons stay reachable on a small screen
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:Window.MaxHeight = [math]::Max(480, $workArea.Height - 40)
    $script:Window.MaxWidth = [math]::Max(800, $workArea.Width - 40)
    Initialize-EngineList
    Initialize-LanguageList
    Set-UiText
    Set-AccessibleLabel
    Set-Accessibility
    [void](Show-CachedCatalog)
    Register-UiEvent
}

function Assert-LauncherPrerequisite {
    # Checks what WPF needs; raises an explicit error otherwise.
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw (Get-UiText 'window.error.needsWindows')
    }
    $languageMode = $ExecutionContext.SessionState.LanguageMode
    if ($languageMode -ne [System.Management.Automation.PSLanguageMode]::FullLanguage) {
        throw (Get-UiText 'window.error.needsFullLanguage' -Arguments @($languageMode))
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        throw (Get-UiText 'window.error.needsSta' -Arguments @($PSCommandPath))
    }
}
