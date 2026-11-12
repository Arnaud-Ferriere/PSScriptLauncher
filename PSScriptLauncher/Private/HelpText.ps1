# Mise en forme de l'aide complète (onglet Aide).

function Format-IndentedText {
    # Indente chaque ligne non vide.
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Spaces = 4)

    $pad = ' ' * $Spaces
    $lines = foreach ($line in ([string]$Text -split '\r?\n')) {
        if ($line.Trim()) { $pad + $line } else { '' }
    }
    @($lines) -join [Environment]::NewLine
}

function Get-ParameterSyntax {
    # « -Nom <Type> », ou « -Nom » pour un switch.
    param([Parameter(Mandatory)]$Parameter)

    if ($Parameter.Kind -eq 'Switch') { return "-$($Parameter.Name)" }
    "-$($Parameter.Name) <$($Parameter.TypeName)>"
}

function Get-SyntaxLine {
    # Ligne de syntaxe du script pour un jeu de paramètres (comme la section SYNTAX de Get-Help).
    param([Parameter(Mandatory)]$ScriptInfo, [string]$ParameterSet)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($ScriptInfo.Name)
    foreach ($parameter in $ScriptInfo.Parameters) {
        if ($parameter.DontShow) { continue }
        $mandatory = Get-ParameterSetMembership -Parameter $parameter -ParameterSet $ParameterSet
        if ($null -eq $mandatory) { continue }
        $syntax = Get-ParameterSyntax -Parameter $parameter
        if ($mandatory) { $parts.Add($syntax) } else { $parts.Add("[$syntax]") }
    }
    if ($ScriptInfo.IsAdvanced) { $parts.Add('[<CommonParameters>]') }
    $parts -join ' '
}

function Get-RequirementSummary {
    # Résumé d'une ligne des exigences #Requires du script ('' s'il n'y en a pas).
    param([Parameter(Mandatory)]$ScriptInfo)

    $requirements = $ScriptInfo.Requirements
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($requirements.PSVersion) { $parts.Add("PowerShell $($requirements.PSVersion)+") }
    if ($requirements.PSEditions.Count -gt 0) { $parts.Add('édition ' + ($requirements.PSEditions -join '/')) }
    if ($requirements.Modules.Count -gt 0) { $parts.Add('module(s) ' + ($requirements.Modules -join ', ')) }
    if ($requirements.RunAsAdmin) { $parts.Add('droits administrateur') }
    if ($parts.Count -eq 0) { return '' }
    'Requiert : ' + ($parts -join ' · ')
}

function Add-HelpSection {
    # Ajoute une section « TITRE + corps indenté » au texte d'aide ; rien si le corps est vide.
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return }
    $newLine = [Environment]::NewLine
    [void]$Builder.Append($Title + $newLine + (Format-IndentedText $Body) + $newLine + $newLine)
}

function Format-ParameterHelp {
    # Bloc d'aide d'un paramètre : syntaxe, description, puis une ligne de caractéristiques.
    param([Parameter(Mandatory)]$Parameter)

    $newLine = [Environment]::NewLine
    $text = (Format-IndentedText (Get-ParameterSyntax -Parameter $Parameter)) + $newLine
    if ($Parameter.Description) { $text += (Format-IndentedText $Parameter.Description 8) + $newLine }

    $details = [System.Collections.Generic.List[string]]::new()
    $sets = $Parameter.Sets
    $mandatorySets = @($sets.Keys | Where-Object { $sets[$_] })
    if ($mandatorySets -contains '__AllParameterSets') { $details.Add('Obligatoire') }
    elseif ($mandatorySets.Count -gt 0) { $details.Add('Obligatoire (jeu ' + ($mandatorySets -join ', ') + ')') }
    else { $details.Add('Facultatif') }
    $namedSets = @($sets.Keys | Where-Object { $_ -ne '__AllParameterSets' })
    $isSetSpecific = $namedSets.Count -gt 0 -and -not $sets.Contains('__AllParameterSets')
    if ($isSetSpecific -and $namedSets.Count -ne $mandatorySets.Count) {
        $details.Add('Jeux : ' + ($namedSets -join ', '))
    }
    if ($Parameter.DefaultValue) { $details.Add('Défaut : ' + $Parameter.DefaultValue) }
    if ($Parameter.Aliases.Count -gt 0) { $details.Add('Alias : ' + ($Parameter.Aliases -join ', ')) }
    if ($Parameter.ValidValues) { $details.Add('Valeurs : ' + ($Parameter.ValidValues -join ', ')) }
    foreach ($constraint in @(Format-ParameterValidation -Validation $Parameter.Validation)) { $details.Add($constraint) }
    $text + (Format-IndentedText ($details -join ' · ') 8) + $newLine
}

function Format-ScriptHelp {
    # Aide complète façon Get-Help -Full.
    param([Parameter(Mandatory)]$ScriptInfo)

    $newLine = [Environment]::NewLine
    $blankLine = $newLine + $newLine
    $help = $ScriptInfo.Help
    $output = [System.Text.StringBuilder]::new()

    Add-HelpSection -Builder $output -Title 'NOM' -Body $ScriptInfo.RelativePath
    Add-HelpSection -Builder $output -Title 'SYNOPSIS' -Body $ScriptInfo.Synopsis

    $sets = @($ScriptInfo.ParameterSets)
    if ($sets.Count -eq 0) { $sets = @('') }
    $syntax = foreach ($set in $sets) { Get-SyntaxLine -ScriptInfo $ScriptInfo -ParameterSet $set }
    Add-HelpSection -Builder $output -Title 'SYNTAXE' -Body (@($syntax) -join $blankLine)

    Add-HelpSection -Builder $output -Title 'DESCRIPTION' -Body $ScriptInfo.Description

    $visible = @($ScriptInfo.Parameters | Where-Object { -not $_.DontShow })
    if ($visible.Count -gt 0) {
        [void]$output.Append('PARAMÈTRES' + $newLine)
        foreach ($parameter in $visible) {
            [void]$output.Append((Format-ParameterHelp -Parameter $parameter) + $newLine)
        }
    }

    if ($help) {
        $index = 0
        $examples = foreach ($example in $help.Examples) {
            $index++
            "--- Exemple $index ---" + $newLine + (Remove-CommonIndent -Text $example)
        }
        Add-HelpSection -Builder $output -Title 'EXEMPLES' -Body (@($examples) -join $blankLine)

        $inputs = @($help.Inputs | ForEach-Object { Remove-CommonIndent -Text $_ }) -join $newLine
        $outputs = @($help.Outputs | ForEach-Object { Remove-CommonIndent -Text $_ }) -join $newLine
        $links = @($help.Links | ForEach-Object { ([string]$_).Trim() }) -join $newLine
        Add-HelpSection -Builder $output -Title 'ENTRÉES' -Body $inputs
        Add-HelpSection -Builder $output -Title 'SORTIES' -Body $outputs
        Add-HelpSection -Builder $output -Title 'NOTES' -Body (Remove-CommonIndent -Text $help.Notes)
        Add-HelpSection -Builder $output -Title 'LIENS' -Body $links
    }

    Add-HelpSection -Builder $output -Title 'EXIGENCES (#Requires)' -Body (Get-RequirementSummary -ScriptInfo $ScriptInfo)
    $output.ToString().TrimEnd()
}
