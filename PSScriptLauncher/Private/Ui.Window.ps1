# Fenêtre principale : arborescence, détail du script, lancement, événements.

function Show-ErrorDialog {
    # Boîte d'erreur modale, rattachée à la fenêtre du lanceur si elle existe.
    param([Parameter(Mandatory)][string]$Message)

    $button = [System.Windows.MessageBoxButton]::OK
    $icon = [System.Windows.MessageBoxImage]::Error
    if ($script:Window) {
        [void][System.Windows.MessageBox]::Show($script:Window, $Message, 'Lanceur de scripts', $button, $icon)
    }
    else {
        [void][System.Windows.MessageBox]::Show($Message, 'Lanceur de scripts', $button, $icon)
    }
}

function Invoke-UiAction {
    # Exécute le corps d'un gestionnaire d'événement : une erreur est affichée (avec la ligne du
    # lanceur où elle s'est produite) au lieu de faire tomber la fenêtre.
    param([Parameter(Mandatory)][scriptblock]$Action)

    try { & $Action }
    catch {
        # Message de l'erreur d'origine, sans les enveloppes « Exception calling ... »
        $message = $_.Exception.GetBaseException().Message
        $file = Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)
        $origin = '{0}, ligne {1}' -f $file, $_.InvocationInfo.ScriptLineNumber
        Show-ErrorDialog -Message "Erreur : $message$([Environment]::NewLine)($origin)"
    }
}

function Set-Status {
    # Message de la barre d'état (repris en infobulle : le texte peut être tronqué).
    param([string]$Message)

    $script:Ui.StatusText.Text = $Message
    $script:Ui.StatusText.ToolTip = $Message
}

function Set-OptionalText {
    # Affecte le texte d'un TextBlock et le masque s'il est vide.
    param([Parameter(Mandatory)]$Element, [string]$Text)

    $Element.Text = $Text
    $Element.Visibility = if ([string]::IsNullOrWhiteSpace($Text)) { 'Collapsed' } else { 'Visible' }
}

function New-LauncherState {
    # État de la fenêtre pour une session du lanceur.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludePattern = @(),
        [string]$StatePath
    )

    if (-not $StatePath) { $StatePath = Get-DefaultStatePath }
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
        Loading        = $false
        Loaded         = $false
        Engines        = @()
        SearchTimer    = $null
        ScanTimer      = $null
        Scan           = $null
        TreeFolders    = @{}
        TreeFiltered   = $false
    }
}

function Edit-UserState {
    # Applique une modification à l'état de l'utilisateur et l'enregistre. L'état est relu juste
    # avant, pour ne pas écraser ce qu'une autre fenêtre du lanceur aurait enregistré entre-temps.
    # Un échec d'écriture n'interrompt rien : il est seulement signalé dans la barre d'état.
    param([Parameter(Mandatory)][scriptblock]$Change)

    $state = Read-UserState -Path $script:State.StatePath
    & $Change $state
    $script:State.UserState = $state
    try { Save-UserState -Path $script:State.StatePath -State $state }
    catch { Set-Status "Préférences non enregistrées : $($_.Exception.Message)" }
}

function Get-TreeFolderNode {
    # Nœud d'un dossier dans l'arborescence, créé à la demande avec ses dossiers parents.
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$RelativeDirectory,
        [bool]$Expand
    )

    if ($Cache.ContainsKey($RelativeDirectory)) { return $Cache[$RelativeDirectory] }
    $item = [System.Windows.Controls.TreeViewItem]::new()
    # Gras sur l'en-tête seulement : appliqué au nœud, FontWeight s'hériterait dans les scripts
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
    # Nœud d'un script : nom, couleur selon son état (avertissement, sans aide), infobulle.
    param([Parameter(Mandatory)]$Entry, [switch]$ShowLocation)

    $item = [System.Windows.Controls.TreeViewItem]::new()
    $header = [System.Windows.Controls.TextBlock]::new()
    $header.Text = $Entry.BaseName
    if ($Entry.Warnings.Count -gt 0) { $header.Foreground = [System.Windows.Media.Brushes]::DarkOrange }
    elseif (-not $Entry.Synopsis) { $header.Foreground = [System.Windows.Media.Brushes]::Gray }
    $item.Header = $header
    $item.Tag = $Entry
    $toolTip = if ($Entry.Synopsis) { $Entry.Synopsis } else { 'Aucune aide' }
    if ($ShowLocation) { $toolTip = $Entry.RelativePath + [Environment]::NewLine + $toolTip }
    $item.ToolTip = $toolTip
    $item
}

function Add-PinnedSection {
    # Section en tête d'arborescence (Favoris, Récents) : raccourcis vers des scripts de l'inventaire.
    # Les chemins qui ne sont plus dans l'inventaire sont simplement ignorés.
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

function Update-ScriptTree {
    # Reconstruit l'arborescence à partir de l'inventaire, du filtre de recherche et des favoris.
    $tree = $script:Ui.ScriptTree
    $filter = $script:Ui.SearchBox.Text
    $isFiltered = -not [string]::IsNullOrWhiteSpace($filter)

    # Dossiers que l'utilisateur avait ouverts ou repliés : conservés d'une reconstruction à l'autre
    $previousExpansion = @{}
    if (-not $isFiltered -and -not $script:State.TreeFiltered) {
        foreach ($key in $script:State.TreeFolders.Keys) {
            $previousExpansion[$key] = $script:State.TreeFolders[$key].IsExpanded
        }
    }

    $tree.Items.Clear()
    $scripts = @($script:State.Scripts | Where-Object { Test-ScriptFilter -ScriptInfo $_ -Filter $filter })
    $expand = $isFiltered -or ($scripts.Count -le $script:Settings.AutoExpandLimit)
    $folders = @{}

    if (-not $isFiltered) {
        $scriptByPath = @{}
        foreach ($entry in $scripts) { $scriptByPath[$entry.Path.ToLowerInvariant()] = $entry }
        $userState = $script:State.UserState
        Add-PinnedSection -Title '★ Favoris' -Path $userState.Favorites.ToArray() -ScriptByPath $scriptByPath -Sort
        Add-PinnedSection -Title 'Récents' -Path $userState.Recents.ToArray() -ScriptByPath $scriptByPath
    }

    # Dossiers d'abord, triés segment par segment, puis les scripts de chaque dossier
    $directories = [string[]]@(
        $scripts | ForEach-Object { $_.RelativeDirectory } | Where-Object { $_ } | Select-Object -Unique)
    if ($directories.Count -gt 0) {
        # Clé de tri : séparateur remplacé par U+0001, pour que « A\B » se classe avant « A-C »
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
    foreach ($key in $previousExpansion.Keys) {
        if ($folders.ContainsKey($key)) { $folders[$key].IsExpanded = $previousExpansion[$key] }
    }
    $script:State.TreeFolders = $folders
    $script:State.TreeFiltered = $isFiltered

    # Le script affiché reste sélectionné dans l'arbre reconstruit (le gestionnaire de sélection
    # reconnaît le même script et conserve les valeurs saisies)
    if ($currentItem) { $currentItem.IsSelected = $true }
    if ($scripts.Count -eq 0) {
        $empty = [System.Windows.Controls.TreeViewItem]::new()
        $empty.Header = if ($filter) { 'Aucun script ne correspond.' } else { 'Aucun script trouvé.' }
        $empty.IsEnabled = $false
        [void]$tree.Items.Add($empty)
    }
}

function Stop-CatalogScan {
    # Abandonne l'inventaire en cours, s'il y en a un, et libère son runspace.
    if (-not $script:State) { return }
    if ($script:State.ScanTimer) { $script:State.ScanTimer.Stop() }
    $scan = $script:State.Scan
    $script:State.Scan = $null
    if ($script:Ui -and $script:Ui.ScanProgress) { $script:Ui.ScanProgress.Visibility = [System.Windows.Visibility]::Collapsed }
    if (-not $scan) { return }
    try { $scan.PowerShell.Stop() }
    catch { Write-Verbose "Arrêt de l'inventaire : $($_.Exception.Message)" }
    $scan.PowerShell.Dispose()
}

function Start-CatalogScan {
    # Lance l'inventaire des scripts dans un runspace d'arrière-plan : la fenêtre reste utilisable.
    # Un minuteur (Update-CatalogScan) suit la progression et récupère le résultat.
    Stop-CatalogScan

    $progress = [hashtable]::Synchronized(@{ Total = 0; Done = 0 })
    $arguments = @{
        Root             = $script:State.Root
        ExcludePattern   = $script:State.ExcludePattern
        ExcludeFile      = $script:State.LauncherPath
        ExcludeDirectory = @($script:ModuleRoot)
        Summary          = $true
        Progress         = $progress
    }
    # Le runspace ne partage rien avec la fenêtre : il charge lui-même les fonctions d'analyse
    $private = Join-Path $script:ModuleRoot 'Private'
    $files = @((Join-Path $private 'Settings.ps1'), (Join-Path $private 'Analysis.ps1'))
    $scanScript = {
        param($Files, $Arguments)
        $ErrorActionPreference = 'Stop'
        foreach ($file in $Files) { . $file }
        Get-ScriptCatalog @Arguments
    }
    $powerShell = [powershell]::Create()
    [void]$powerShell.AddScript($scanScript.ToString()).AddArgument($files).AddArgument($arguments)
    $script:State.Scan = @{
        PowerShell = $powerShell
        Handle     = $powerShell.BeginInvoke()
        Progress   = $progress
        Watch      = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $bar = $script:Ui.ScanProgress
    $bar.IsIndeterminate = $true
    $bar.Visibility = [System.Windows.Visibility]::Visible
    Set-Status 'Analyse des scripts...'
    $script:State.ScanTimer.Start()
}

function Update-CatalogScan {
    # Appelé par le minuteur : affiche la progression, ou termine l'inventaire s'il est fini.
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
            Set-Status "Analyse des scripts... $done / $total"
        }
        return
    }
    Complete-CatalogScan
}

function Complete-CatalogScan {
    # Récupère le résultat de l'inventaire terminé et met l'interface à jour.
    $scan = $script:State.Scan
    $script:State.ScanTimer.Stop()
    $script:State.Scan = $null
    $script:Ui.ScanProgress.Visibility = [System.Windows.Visibility]::Collapsed
    try {
        $catalog = @($scan.PowerShell.EndInvoke($scan.Handle)) | Select-Object -First 1
        if (-not $catalog) { throw "l'inventaire n'a renvoyé aucun résultat." }
    }
    catch {
        Set-Status "Échec de l'analyse : $($_.Exception.GetBaseException().Message)"
        throw
    }
    finally {
        $scan.PowerShell.Dispose()
    }

    $script:State.Scripts = @($catalog.Scripts)
    $script:Window.Title = "Lanceur de scripts - $($catalog.Root)"
    $script:Ui.RootText.Text = $catalog.Root
    $script:Ui.RootText.ToolTip = $catalog.Root
    Update-ScriptTree

    $message = '{0} script(s) · {1:N1} s' -f $script:State.Scripts.Count, $scan.Watch.Elapsed.TotalSeconds
    $flagged = @($script:State.Scripts | Where-Object { $_.Warnings.Count -gt 0 }).Count
    if ($flagged -gt 0) { $message += " · $flagged avec avertissement" }
    $scanErrors = @($catalog.ScanErrors).Count
    if ($scanErrors -gt 0) { $message += " · $scanErrors élément(s) illisible(s)" }
    Set-Status $message

    # Actualiser recharge aussi le script affiché (paramètres ou aide modifiés entre-temps)
    $current = $script:State.Current
    if ($current -and (Test-Path -LiteralPath $current.Path)) {
        $refreshed = Get-ScriptInfo -LiteralPath $current.Path -RelativePath $current.RelativePath
        Show-ScriptDetail -ScriptInfo $refreshed
    }
}

function Select-LauncherRoot {
    # « Dossier... » : choisit le dossier à analyser et relance l'inventaire.
    $selected = Select-FolderPath -InitialDirectory $script:State.Root
    if (-not $selected) { return }
    $root = (Resolve-Path -LiteralPath $selected).ProviderPath
    if ($root -eq $script:State.Root) {
        Set-Status 'Ce dossier est déjà affiché.'
        return
    }

    # Tout ce qui vient de l'ancien dossier disparaît : arborescence, sélection, filtre
    $script:State.Root = $root
    $script:State.TreeFolders = @{}
    $script:Ui.ScriptTree.Items.Clear()
    $script:Ui.SearchBox.Text = ''
    Reset-ScriptDetail
    $script:Window.Title = "Lanceur de scripts - $root"
    $script:Ui.RootText.Text = $root
    $script:Ui.RootText.ToolTip = $root
    Start-CatalogScan
}

function Initialize-EngineList {
    # Remplit la liste des moteurs PowerShell disponibles sur le poste.
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
    # Choisit le moteur exigé par #Requires, sinon celui qui exécute le lanceur. Renvoie un
    # avertissement si le moteur exigé est absent.
    param([Parameter(Mandatory)]$ScriptInfo)

    $preferred = Get-PreferredEdition -ScriptInfo $ScriptInfo
    $wanted = if ($preferred) { $preferred } else { $script:State.DefaultEdition }
    foreach ($item in $script:Ui.EngineCombo.Items) {
        if ($item.Tag.Edition -eq $wanted) {
            $script:Ui.EngineCombo.SelectedItem = $item
            return ''
        }
    }
    if ($preferred -eq 'Core') { return 'Ce script exige PowerShell 7+, introuvable sur ce poste (pwsh.exe).' }
    ''
}

function Update-FavoriteButton {
    # Libellé du bouton Favori selon l'état du script affiché.
    $button = $script:Ui.FavoriteButton
    $current = $script:State.Current
    if (-not $current) {
        $button.IsEnabled = $false
        return
    }
    $button.IsEnabled = $true
    $isFavorite = Test-FavoriteScript -State $script:State.UserState -ScriptPath $current.Path
    $button.Content = if ($isFavorite) { '★ Favori' } else { '☆ Favori' }
    $button.ToolTip = if ($isFavorite) { 'Retirer de mes favoris' } else { 'Ajouter à mes favoris' }
}

function Switch-CurrentFavorite {
    # Ajoute le script affiché aux favoris de l'utilisateur, ou l'en retire.
    $current = $script:State.Current
    if (-not $current) { return }
    Edit-UserState { param($state) [void](Switch-FavoriteScript -State $state -ScriptPath $current.Path) }
    Update-FavoriteButton
    Update-ScriptTree
}

function Restore-RememberedInput {
    # Remet dans le formulaire la dernière saisie lancée pour ce script. À appeler pendant le
    # chargement ($script:State.Loading) : l'aperçu de commande est recalculé ensuite.
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

function Reset-ScriptDetail {
    # Partie droite au repos : aucun script affiché (démarrage, ou changement de dossier).
    $ui = $script:Ui
    $script:State.Current = $null
    $script:State.CurrentSet = ''
    $script:State.Rows = @()
    $script:State.LastCommand = $null
    $ui.ScriptTitle.Text = 'Sélectionnez un script'
    $ui.ScriptPath.Text = ''
    $ui.ScriptPath.ToolTip = $null
    $ui.ScriptSynopsis.Text = ''
    Set-OptionalText -Element $ui.ScriptInfo -Text ''
    Set-OptionalText -Element $ui.ScriptWarning -Text ''
    $ui.ScriptDescription.Text = ''
    $ui.DescriptionPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.HelpText.Text = ''
    $ui.SetCombo.Items.Clear()
    $ui.SetPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ExampleCombo.Items.Clear()
    $ui.ExamplePanel.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.ParamPanel.Children.Clear()
    $ui.VerboseCheck.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.WhatIfCheck.Visibility = [System.Windows.Visibility]::Collapsed
    $ui.CommandBox.Text = ''
    foreach ($button in @($ui.RunButton, $ui.CopyButton, $ui.LocateButton, $ui.ResetButton)) { $button.IsEnabled = $false }
    $ui.FavoriteButton.IsEnabled = $false
    $ui.FavoriteButton.Content = '☆ Favori'
    $ui.DetailTabs.SelectedIndex = 0
}

function Show-ScriptDetail {
    # Affiche un script : en-tête, aide, formulaire de paramètres, options de lancement.
    # -NoRestore : formulaire vide, sans reprendre la dernière saisie mémorisée.
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
            $ui.ScriptSynopsis.Text = 'Aucune aide (comment-based help) trouvée dans ce script.'
            $ui.ScriptSynopsis.Foreground = [System.Windows.Media.Brushes]::Gray
        }
        Set-OptionalText -Element $ui.ScriptInfo -Text (Get-RequirementSummary -ScriptInfo $ScriptInfo)
        $warnings = @($ScriptInfo.Warnings) + @(Select-EngineForScript -ScriptInfo $ScriptInfo) | Where-Object { $_ }
        Set-OptionalText -Element $ui.ScriptWarning -Text (@($warnings) -join [Environment]::NewLine)
        Update-FavoriteButton

        $ui.ScriptDescription.Text = $ScriptInfo.Description
        $ui.DescriptionPanel.Visibility = if ($ScriptInfo.Description) { 'Visible' } else { 'Collapsed' }

        $ui.HelpText.Text = Format-ScriptHelp -ScriptInfo $ScriptInfo
        $ui.HelpText.ScrollToHome()

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

        # Exemples utilisables pour remplir le formulaire
        $ui.ExampleCombo.Items.Clear()
        [void]$ui.ExampleCombo.Items.Add('(remplir depuis un exemple)')
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
            $none.Text = 'Ce script ne déclare aucun paramètre.'
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
        foreach ($button in @($ui.RunButton, $ui.CopyButton, $ui.LocateButton, $ui.ResetButton)) { $button.IsEnabled = $true }
        $ui.DetailTabs.SelectedIndex = 0

        if (-not $NoRestore) { $restored = Restore-RememberedInput -ScriptInfo $ScriptInfo }
    }
    finally {
        $script:State.Loading = $false
    }
    Update-ParameterVisibility
    if ($restored) { Set-Status 'Dernière saisie restaurée (« Effacer la saisie » pour repartir de zéro).' }
}

function Set-FormFromExample {
    # Remplit le formulaire avec les arguments d'un .EXAMPLE du script affiché.
    param([Parameter(Mandatory)][int]$Number)

    $info = $script:State.Current
    $example = @($info.Examples | Where-Object { $_.Number -eq $Number }) | Select-Object -First 1
    if (-not $example) { return }
    $ignored = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $example.Ignored) { $ignored.Add($item) }

    $script:State.Loading = $true
    try {
        foreach ($row in $script:State.Rows) { Set-RowValue -Row $row -Value $null }

        # Jeu de paramètres : le premier qui contient tous les paramètres de l'exemple
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
                $ignored.Add("-$name $($argument.Text) (à saisir)")
            }
        }
    }
    finally {
        $script:State.Loading = $false
    }
    Update-ParameterVisibility
    $message = "Exemple $Number appliqué."
    if ($ignored.Count -gt 0) { $message += ' Non repris : ' + ($ignored -join ' ; ') }
    Set-Status $message
}

function Clear-ScriptForm {
    # Vide le formulaire et oublie la saisie mémorisée pour le script affiché.
    $current = $script:State.Current
    if (-not $current) { return }
    Edit-UserState { param($state) Remove-RememberedInput -State $state -ScriptPath $current.Path }
    Show-ScriptDetail -ScriptInfo $current -NoRestore
    Set-Status 'Saisie effacée.'
}

function Save-CurrentInput {
    # Mémorise la saisie du script qui vient d'être lancé (valeurs non sensibles du jeu courant)
    # et le place en tête des scripts récents.
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
    # Lance le script affiché dans une nouvelle console, après confirmation si la saisie est incomplète.
    $selected = $script:State.Current
    if ($null -eq $selected) { return }
    Update-CommandPreview
    $result = $script:State.LastCommand

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($result.Missing.Count -gt 0) {
        $issues.Add('Paramètres obligatoires non renseignés : ' + ($result.Missing -join ', ') +
            [Environment]::NewLine + '(PowerShell les demandera dans la console.)')
    }
    foreach ($name in $result.Errors.Keys) { $issues.Add("-$name : " + ($result.Errors[$name] -join ' ; ')) }
    if ($issues.Count -gt 0) {
        $blankLine = [Environment]::NewLine * 2
        $text = ($issues -join $blankLine) + $blankLine + 'Lancer quand même ?'
        $answer = [System.Windows.MessageBox]::Show($script:Window, $text, 'Vérification',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $engineItem = $script:Ui.EngineCombo.SelectedItem
    if ($null -eq $engineItem) { throw 'Aucun moteur PowerShell disponible.' }
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
        throw ("La commande est trop longue pour être lancée ($length caractères, limite de Windows : " +
            "$($script:Settings.MaxCommandLineLength)). Réduisez les valeurs saisies, ou copiez la commande " +
            'et exécutez-la dans une console.')
    }

    try {
        Start-ScriptProcess -FilePath $enginePath -Arguments $arguments -WorkingDirectory $workingDirectory `
            -Elevate:$elevate
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.ComponentModel.Win32Exception] -and $inner.NativeErrorCode -eq 1223) {
            Set-Status 'Élévation annulée.'
            return
        }
        throw
    }
    Save-CurrentInput
    Set-Status ('Lancé : {0} ({1})' -f $selected.Name, (Get-Date -Format 'HH:mm:ss'))
}

function Copy-CommandToClipboard {
    # Copie la commande générée dans le presse-papiers.
    $text = $script:Ui.CommandBox.Text
    if (-not $text) { return }
    [System.Windows.Clipboard]::SetDataObject($text, $true)     # réessaie si le presse-papiers est occupé
    Set-Status 'Commande copiée dans le presse-papiers.'
}

function Show-ScriptLocation {
    # Ouvre l'Explorateur sur le dossier du script, fichier sélectionné.
    $selected = $script:State.Current
    if ($null -eq $selected) { return }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'explorer.exe'
    $startInfo.Arguments = '/select,"' + $selected.Path + '"'
    [void][System.Diagnostics.Process]::Start($startInfo)
}

function Register-UiEvent {
    # Les gestionnaires s'exécutent après le retour de cette fonction : ils n'utilisent que des
    # variables de portée script.
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
                # Même script (arbre reconstruit par la recherche) : on garde les valeurs saisies
                if ($script:State.Current -and $script:State.Current.Path -eq $entry.Path) { return }
                # Analyse complète à la sélection : relit aussi les modifications faites depuis l'inventaire
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
            Invoke-UiAction { Start-CatalogScan }
        })
}

function Initialize-LauncherWindow {
    # Charge la fenêtre (XAML), référence ses éléments nommés et branche les événements.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xamlPath = Join-Path $script:ModuleRoot 'MainWindow.xaml'
    $script:Window = [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($xamlPath))
    $script:Ui = @{}
    $names = @(
        'SearchBox', 'SearchHint', 'RootText', 'ScriptTree', 'StatusText', 'RefreshButton', 'FolderButton', 'ScriptTitle', 'ScriptPath',
        'ScriptSynopsis', 'ScriptInfo', 'ScriptWarning', 'DetailTabs', 'DescriptionPanel', 'ScriptDescription',
        'SetPanel', 'SetCombo', 'ParamPanel', 'VerboseCheck', 'WhatIfCheck', 'ExtraArgsBox', 'HelpText',
        'CommandBox', 'EngineCombo', 'NoExitCheck', 'NoProfileCheck', 'ElevateCheck', 'LocateButton',
        'CopyButton', 'RunButton', 'ResetButton', 'FavoriteButton', 'ScanProgress', 'ExamplePanel', 'ExampleCombo'
    )
    foreach ($name in $names) {
        $element = $script:Window.FindName($name)
        if ($null -eq $element) { throw "Élément d'interface introuvable : $name" }
        $script:Ui[$name] = $element
    }
    $script:State.SearchTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.SearchTimer.Interval = [TimeSpan]::FromMilliseconds($script:Settings.SearchDelayMs)
    $script:State.ScanTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:State.ScanTimer.Interval = [TimeSpan]::FromMilliseconds($script:Settings.ScanPollMs)
    Initialize-EngineList
    Register-UiEvent
}

function Assert-LauncherPrerequisite {
    # Vérifie ce dont WPF a besoin ; lève une erreur explicite sinon.
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'Ce lanceur utilise WPF : il ne fonctionne que sous Windows.'
    }
    $languageMode = $ExecutionContext.SessionState.LanguageMode
    if ($languageMode -ne [System.Management.Automation.PSLanguageMode]::FullLanguage) {
        throw "Mode de langage $languageMode : WPF exige FullLanguage (stratégie AppLocker/WDAC ?)."
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        throw "WPF exige un thread STA. Relancez avec : powershell.exe -STA -File `"$PSCommandPath`""
    }
}
