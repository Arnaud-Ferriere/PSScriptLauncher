# Formatting of the full help (Help tab).

function Format-IndentedText {
    # Indents every non-empty line.
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Spaces = 4)

    $pad = ' ' * $Spaces
    $lines = foreach ($line in ([string]$Text -split '\r?\n')) {
        if ($line.Trim()) { $pad + $line } else { '' }
    }
    @($lines) -join [Environment]::NewLine
}

function Get-ParameterSyntax {
    # "-Name <Type>", or "-Name" for a switch.
    param([Parameter(Mandatory)]$Parameter)

    if ($Parameter.Kind -eq 'Switch') { return "-$($Parameter.Name)" }
    "-$($Parameter.Name) <$($Parameter.TypeName)>"
}

function Get-SyntaxLine {
    # Syntax line of the script for one parameter set (like the SYNTAX section of Get-Help).
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
    # One-line summary of the #Requires requirements of the script ('' when there is none).
    param([Parameter(Mandatory)]$ScriptInfo)

    $requirements = $ScriptInfo.Requirements
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($requirements.PSVersion) { $parts.Add("PowerShell $($requirements.PSVersion)+") }
    if ($requirements.PSEditions.Count -gt 0) {
        $parts.Add((Get-UiText 'help.requirement.edition' -Arguments @($requirements.PSEditions -join '/')))
    }
    if ($requirements.Modules.Count -gt 0) {
        $parts.Add((Get-UiText 'help.requirement.modules' -Arguments @(($requirements.Modules -join ', '))))
    }
    if ($requirements.RunAsAdmin) { $parts.Add((Get-UiText 'help.requirement.admin')) }
    if ($parts.Count -eq 0) { return '' }
    Get-UiText 'help.requirement.summary' -Arguments @(($parts -join ' · '))
}

function Add-HelpSection {
    # Adds a "TITLE + indented body" section to the help text; nothing when the body is empty.
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
    # Help block of one parameter: syntax, description, then a line of characteristics.
    param([Parameter(Mandatory)]$Parameter)

    $newLine = [Environment]::NewLine
    $text = (Format-IndentedText (Get-ParameterSyntax -Parameter $Parameter)) + $newLine
    if ($Parameter.Description) { $text += (Format-IndentedText $Parameter.Description 8) + $newLine }

    $details = [System.Collections.Generic.List[string]]::new()
    $sets = $Parameter.Sets
    $mandatorySets = @($sets.Keys | Where-Object { $sets[$_] })
    if ($mandatorySets -contains '__AllParameterSets') {
        $details.Add((Get-UiText 'help.detail.mandatory'))
    }
    elseif ($mandatorySets.Count -gt 0) {
        $details.Add((Get-UiText 'help.detail.mandatorySets' -Arguments @(($mandatorySets -join ', '))))
    }
    else {
        $details.Add((Get-UiText 'help.detail.optional'))
    }
    $namedSets = @($sets.Keys | Where-Object { $_ -ne '__AllParameterSets' })
    $isSetSpecific = $namedSets.Count -gt 0 -and -not $sets.Contains('__AllParameterSets')
    if ($isSetSpecific -and $namedSets.Count -ne $mandatorySets.Count) {
        $details.Add((Get-UiText 'help.detail.sets' -Arguments @(($namedSets -join ', '))))
    }
    if ($Parameter.DefaultValue) {
        $details.Add((Get-UiText 'help.detail.default' -Arguments @($Parameter.DefaultValue)))
    }
    if ($Parameter.Aliases.Count -gt 0) {
        $details.Add((Get-UiText 'help.detail.alias' -Arguments @(($Parameter.Aliases -join ', '))))
    }
    if ($Parameter.ValidValues) {
        $details.Add((Get-UiText 'help.detail.values' -Arguments @(($Parameter.ValidValues -join ', '))))
    }
    foreach ($constraint in @(Format-ParameterValidation -Validation $Parameter.Validation)) { $details.Add($constraint) }
    $text + (Format-IndentedText ($details -join ' · ') 8) + $newLine
}

function Format-ScriptHelp {
    # Full help, Get-Help -Full style.
    param([Parameter(Mandatory)]$ScriptInfo)

    $newLine = [Environment]::NewLine
    $blankLine = $newLine + $newLine
    $help = $ScriptInfo.Help
    $output = [System.Text.StringBuilder]::new()

    Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.name') -Body $ScriptInfo.RelativePath
    Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.synopsis') -Body $ScriptInfo.Synopsis

    $sets = @($ScriptInfo.ParameterSets)
    if ($sets.Count -eq 0) { $sets = @('') }
    $syntax = foreach ($set in $sets) { Get-SyntaxLine -ScriptInfo $ScriptInfo -ParameterSet $set }
    Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.syntax') `
        -Body (@($syntax) -join $blankLine)

    Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.description') `
        -Body $ScriptInfo.Description

    $visible = @($ScriptInfo.Parameters | Where-Object { -not $_.DontShow })
    if ($visible.Count -gt 0) {
        [void]$output.Append((Get-UiText 'help.section.parameters') + $newLine)
        foreach ($parameter in $visible) {
            [void]$output.Append((Format-ParameterHelp -Parameter $parameter) + $newLine)
        }
    }

    if ($help) {
        $index = 0
        $examples = foreach ($example in $help.Examples) {
            $index++
            (Get-UiText 'help.example.label' -Arguments @($index)) + $newLine +
                (Remove-CommonIndent -Text $example)
        }
        Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.examples') `
            -Body (@($examples) -join $blankLine)

        $inputs = @($help.Inputs | ForEach-Object { Remove-CommonIndent -Text $_ }) -join $newLine
        $outputs = @($help.Outputs | ForEach-Object { Remove-CommonIndent -Text $_ }) -join $newLine
        $links = @($help.Links | ForEach-Object { ([string]$_).Trim() }) -join $newLine
        Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.inputs') -Body $inputs
        Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.outputs') -Body $outputs
        Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.notes') `
            -Body (Remove-CommonIndent -Text $help.Notes)
        Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.links') -Body $links
    }

    Add-HelpSection -Builder $output -Title (Get-UiText 'help.section.requirements') `
        -Body (Get-RequirementSummary -ScriptInfo $ScriptInfo)
    $output.ToString().TrimEnd()
}
