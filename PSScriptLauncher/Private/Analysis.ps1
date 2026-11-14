# Reads and analyzes scripts through the AST (no execution). No WPF dependency: this file is
# also loaded on its own in the inventory runspace.

function Read-ScriptText {
    # Reads a script with its own encoding: BOM when there is one, else strict UTF-8, else the
    # system ANSI code page (this is how Windows PowerShell 5.1 reads a file without a BOM).
    param([Parameter(Mandatory)][string]$LiteralPath)

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    try {
        return ([System.Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
    }
    catch {
        try {
            $codePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            $ansi = [System.Text.Encoding]::GetEncoding($codePage)
        }
        catch {
            $ansi = [System.Text.Encoding]::GetEncoding(28591)      # ISO-8859-1, always available
        }
        return $ansi.GetString($bytes)
    }
}

function Get-NormalizedAttributeName {
    # [System.Management.Automation.ParameterAttribute()] -> Parameter
    param([Parameter(Mandatory)][System.Management.Automation.Language.AttributeBaseAst]$Attribute)

    $name = $Attribute.TypeName.FullName -replace '^System\.Management\.Automation\.', ''
    $name -replace 'Attribute$', ''
}

function Get-AttributeArgument {
    # Value of a named attribute argument, read without running any code (SafeGetValue).
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.AttributeAst]$Attribute,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AsBoolean
    )

    foreach ($named in $Attribute.NamedArguments) {
        if ($named.ArgumentName -ne $Name) { continue }
        if ($AsBoolean) {
            if ($named.ExpressionOmitted) { return $true }     # [Parameter(Mandatory)]
            try { return [bool]$named.Argument.SafeGetValue() } catch { return $false }
        }
        try { return $named.Argument.SafeGetValue() } catch { return $null }
    }
    if ($AsBoolean) { return $false }
    $null
}

function Remove-CommonIndent {
    # Removes the indentation common to non-blank lines and the leading/trailing blank lines.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) { $lines[$i] = $lines[$i].TrimEnd() }
    $indent = [int]::MaxValue
    foreach ($line in $lines) {
        if ($line.Length -eq 0) { continue }
        $count = $line.Length - $line.TrimStart().Length
        if ($count -lt $indent) { $indent = $count }
    }
    $first = 0
    while ($lines[$first].Length -eq 0) { $first++ }
    $last = $lines.Count - 1
    while ($lines[$last].Length -eq 0) { $last-- }
    $kept = foreach ($index in $first..$last) {
        if ($lines[$index].Length -ge $indent) { $lines[$index].Substring($indent) } else { '' }
    }
    @($kept) -join "`n"
}

function ConvertFrom-CommentToken {
    # Text of a run of comment tokens, without delimiters and without #region/#endregion lines.
    param([System.Management.Automation.Language.Token[]]$Token)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Token) {
        $text = $item.Text
        if ($text.StartsWith('<#', [System.StringComparison]::Ordinal)) {
            $text = $text.Substring(2)
            if ($text.EndsWith('#>', [System.StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
            foreach ($line in ($text -split '\r?\n')) { $lines.Add($line) }
        }
        elseif ($text -notmatch '^#(end)?region\b') {
            $lines.Add($text.Substring(1))
        }
    }
    Remove-CommonIndent -Text ($lines -join "`n")
}

function Get-InlineParameterHelp {
    # Descriptions written as comments in the param() block, following the Get-Help rule:
    # last group of contiguous comment lines before the parameter, plus the comments placed
    # between its attributes and its name.
    param(
        [System.Management.Automation.Language.ParamBlockAst]$ParamBlock,
        [System.Management.Automation.Language.Token[]]$Tokens
    )

    $result = @{}
    if ($null -eq $ParamBlock -or $null -eq $Tokens) { return $result }

    $blockStart = $ParamBlock.Extent.StartOffset
    $blockEnd = $ParamBlock.Extent.EndOffset
    $blockTokens = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new()
    foreach ($token in $Tokens) {
        if ($token.Extent.EndOffset -le $blockStart) { continue }
        if ($token.Extent.StartOffset -ge $blockEnd) { break }
        $blockTokens.Add($token)
    }

    foreach ($parameter in $ParamBlock.Parameters) {
        $parameterStart = $parameter.Extent.StartOffset
        $nameStart = $parameter.Name.Extent.StartOffset
        $groups = [System.Collections.Generic.List[object]]::new()      # groups of contiguous comments
        $current = $null
        $lastLine = -1
        $inside = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new()

        foreach ($token in $blockTokens) {
            $start = $token.Extent.StartOffset
            if ($start -ge $nameStart) { break }
            $kind = [string]$token.Kind
            if ($start -ge $parameterStart) {
                if ($kind -eq 'Comment') { $inside.Add($token) }
                continue
            }
            if ($kind -eq 'Comment') {
                if ($null -eq $current -or $token.Extent.StartLineNumber -gt $lastLine + 1) {
                    $current = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new()
                    $groups.Add($current)
                }
                $current.Add($token)
                $lastLine = $token.Extent.EndLineNumber
            }
            elseif ($kind -ne 'NewLine' -and $kind -ne 'LineContinuation') {
                # Significant token ( '(' or ',' ): the preceding comments do not concern this parameter
                $groups.Clear()
                $current = $null
            }
        }

        $selected = [System.Collections.Generic.List[System.Management.Automation.Language.Token]]::new()
        if ($groups.Count -gt 0) { $selected.AddRange($groups[$groups.Count - 1]) }
        $selected.AddRange($inside)
        if ($selected.Count -gt 0) {
            $text = ConvertFrom-CommentToken -Token $selected.ToArray()
            if ($text) { $result[$parameter.Name.VariablePath.UserPath] = $text }
        }
    }
    $result
}

function Get-KnownHelpSection {
    # Section keywords Get-Help accepts in a comment-based help block. Anything else makes
    # GetHelpContent() return nothing at all, so the whole block is invisible.
    'SYNOPSIS', 'DESCRIPTION', 'PARAMETER', 'EXAMPLE', 'INPUTS', 'OUTPUTS', 'NOTES', 'LINK',
    'COMPONENT', 'ROLE', 'FUNCTIONALITY', 'FORWARDHELPTARGETNAME', 'FORWARDHELPCATEGORY',
    'REMOTEHELPRUNSPACE', 'EXTERNALHELP'
}

function Get-HelpSectionName {
    # Section keywords present in a help block, upper case, in the order they appear.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '(?im)^\s*\.([A-Za-z][A-Za-z0-9]*)')) {
        $name = $match.Groups[1].Value.ToUpperInvariant()
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    $names
}

function Find-HelpCommentToken {
    # The comment block that would carry the script help: before param() and before the first
    # statement, and holding at least one known section.
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [System.Management.Automation.Language.Token[]]$Tokens
    )

    if ($null -eq $Tokens) { return $null }
    $limit = [int]::MaxValue
    if ($Ast.ParamBlock) {
        $limit = $Ast.ParamBlock.Extent.StartOffset
        foreach ($attribute in $Ast.ParamBlock.Attributes) { $limit = [Math]::Min($limit, $attribute.Extent.StartOffset) }
    }
    $statements = @(
        @($Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) |
            Where-Object { $_ } |
            ForEach-Object { $_.Statements } |
            Sort-Object -Property { $_.Extent.StartOffset })
    if ($statements.Count -gt 0) { $limit = [Math]::Min($limit, $statements[0].Extent.StartOffset) }

    foreach ($token in $Tokens) {
        if ($token.Extent.StartOffset -ge $limit) { break }
        if ([string]$token.Kind -ne 'Comment') { continue }
        if (-not $token.Text.StartsWith('<#', [System.StringComparison]::Ordinal)) { continue }
        if ($token.Text -match '(?im)^\s*\.(SYNOPSIS|DESCRIPTION|PARAMETER|EXAMPLE|NOTES)\b') { return $token }
    }
    $null
}

function Get-IgnoredHelp {
    # A help block with an unknown section (.TAG, .BIDULE...) is rejected as a whole by PowerShell:
    # Get-Help then shows the generated syntax, as if the script had no help at all. We drop the
    # offending sections, read what remains, and name them so the user can fix the block.
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [System.Management.Automation.Language.Token[]]$Tokens
    )

    $token = Find-HelpCommentToken -Ast $Ast -Tokens $Tokens
    if ($null -eq $token) { return $null }

    $known = @(Get-KnownHelpSection)
    $unknown = @(Get-HelpSectionName -Text $token.Text | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -eq 0) { return $null }

    $cleaned = $token.Text
    foreach ($name in $unknown) {
        $pattern = '(?ims)^[ \t]*\.' + $name + '\b.*?(?=^[ \t]*\.[A-Za-z]|\z)'
        $cleaned = [regex]::Replace($cleaned, $pattern, '')
    }
    $miniTokens = $null
    $miniErrors = $null
    $miniAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $cleaned + [Environment]::NewLine + [Environment]::NewLine + 'param()', [ref]$miniTokens, [ref]$miniErrors)
    $help = $null
    try { $help = $miniAst.GetHelpContent() } catch { Write-Verbose 'Unknown help sections, nothing left to read.' }

    [pscustomobject]@{
        Help    = $help
        Unknown = $unknown
        Block   = $token.Text
        Reason  = (Get-UiText 'analysis.warning.unknownHelpSection' -Arguments @(($unknown | ForEach-Object { '.' + $_ }) -join ', '))
    }
}

function Find-MisplacedHelp {
    # Help block at the top of the script that Get-Help does not attach to it (formatting).
    # Returns the help, read separately, and the probable cause, to show it and report it.
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [System.Management.Automation.Language.Token[]]$Tokens
    )

    if ($null -eq $Tokens) { return $null }

    $statements = @(
        @($Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) |
            Where-Object { $_ } |
            ForEach-Object { $_.Statements } |
            Sort-Object -Property { $_.Extent.StartOffset }
    )

    # File that only contains definitions (a function library to dot-source): the help placed at
    # the top is the help of the first function, there is nothing to report.
    $definitions = @($statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $_ -is [System.Management.Automation.Language.TypeDefinitionAst]
        })
    if (-not $Ast.ParamBlock -and $statements.Count -gt 0 -and $definitions.Count -eq $statements.Count) { return $null }

    # Script help can only be found before param() and before the first statement
    $limit = [int]::MaxValue
    if ($Ast.ParamBlock) {
        $limit = $Ast.ParamBlock.Extent.StartOffset
        foreach ($attribute in $Ast.ParamBlock.Attributes) { $limit = [Math]::Min($limit, $attribute.Extent.StartOffset) }
    }
    if ($statements.Count -gt 0) { $limit = [Math]::Min($limit, $statements[0].Extent.StartOffset) }

    $index = -1
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = $Tokens[$i]
        if ($token.Extent.StartOffset -ge $limit) { break }
        $isHelpBlock = [string]$token.Kind -eq 'Comment' -and
            $token.Text.StartsWith('<#', [System.StringComparison]::Ordinal) -and
            $token.Text -match '(?im)^\s*\.(SYNOPSIS|DESCRIPTION|PARAMETER|EXAMPLE|NOTES)\b'
        if ($isHelpBlock) {
            $index = $i
            break
        }
    }
    if ($index -lt 0) { return $null }

    $candidate = $Tokens[$index]
    $miniTokens = $null
    $miniErrors = $null
    $miniAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $candidate.Text + "`n`nparam()", [ref]$miniTokens, [ref]$miniErrors)
    $help = $miniAst.GetHelpContent()
    if ($null -eq $help) { return $null }

    $previous = $null
    for ($i = $index - 1; $i -ge 0; $i--) {
        if ([string]$Tokens[$i].Kind -ne 'NewLine') {
            $previous = $Tokens[$i]
            break
        }
    }
    $isGluedToComment = $previous -and [string]$previous.Kind -eq 'Comment' -and
        $candidate.Extent.StartLineNumber - $previous.Extent.EndLineNumber -le 1
    $isAfterUsing = $Ast.UsingStatements.Count -gt 0 -and
        $Ast.UsingStatements[0].Extent.StartOffset -lt $candidate.Extent.StartOffset
    $firstFunction = $null
    if (-not $Ast.ParamBlock -and $statements.Count -gt 0 -and
        $statements[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $firstFunction = $statements[0]
    }

    $reason = Get-UiText 'analysis.warning.misplacedHelp'
    if ($isGluedToComment) {
        $label = ($previous.Text -split '\r?\n')[0].Trim()
        if ($label.Length -gt 45) { $label = $label.Substring(0, 45) + '...' }
        $reason = Get-UiText 'analysis.warning.misplacedHelpGlued' -Arguments @($label)
    }
    elseif ($isAfterUsing) {
        $reason = Get-UiText 'analysis.warning.misplacedHelpAfterUsing'
    }
    elseif ($firstFunction) {
        $reason = Get-UiText 'analysis.warning.misplacedHelpOnFunction' -Arguments @($firstFunction.Name)
    }
    [pscustomobject]@{ Help = $help; Reason = $reason }
}

function Get-ValueKind {
    # Conversion category of a scalar value: Number, Date or Text.
    param([type]$Type)

    if ($Type -in [datetime], [datetimeoffset]) { return 'Date' }
    if ((Test-IntegerType -Type $Type) -or $Type -in [single], [double], [decimal]) { return 'Number' }
    'Text'
}

function Test-IntegerType {
    # True for an integer type: input then refuses decimals.
    param([type]$Type)

    $Type -in [byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [bigint]
}

function Get-ParameterValidation {
    # [ValidateRange()] and [ValidatePattern()] constraints of a parameter, read without running
    # anything. Returns @{ Range = @{ Min; Max }; Pattern = @{ Regex; Options; Message } } (keys
    # are missing when the attribute does not exist or is not constant).
    param([System.Management.Automation.Language.AttributeAst[]]$Attribute)

    $validation = @{}
    foreach ($item in $Attribute) {
        $arguments = @($item.PositionalArguments)
        switch (Get-NormalizedAttributeName $item) {
            'ValidateRange' {
                if ($arguments.Count -eq 2) {
                    $bounds = foreach ($argument in $arguments) {
                        $text = $argument.Extent.Text.Trim("'", '"', ' ')
                        $bound = [decimal]0
                        $styles = [System.Globalization.NumberStyles]::Float
                        $culture = [System.Globalization.CultureInfo]::InvariantCulture
                        if ([decimal]::TryParse($text, $styles, $culture, [ref]$bound)) { $bound }
                    }
                    if (@($bounds).Count -eq 2) { $validation['Range'] = @{ Min = $bounds[0]; Max = $bounds[1] } }
                }
                elseif ($arguments.Count -eq 1) {
                    # PowerShell 7: [ValidateRange('Positive')] or [ValidateRange([ValidateRangeKind]::Positive)]
                    switch -Regex ($arguments[0].Extent.Text) {
                        'NonNegative' { $validation['Range'] = @{ Min = [decimal]0; Max = $null }; break }
                        'NonPositive' { $validation['Range'] = @{ Min = $null; Max = [decimal]0 }; break }
                        'Positive' { $validation['Range'] = @{ Min = [decimal]0; Max = $null; ExcludeMin = $true }; break }
                        'Negative' { $validation['Range'] = @{ Min = $null; Max = [decimal]0; ExcludeMax = $true }; break }
                    }
                }
            }
            'ValidatePattern' {
                if ($arguments.Count -ge 1) {
                    $regex = $null
                    try { $regex = [string]$arguments[0].SafeGetValue() }
                    catch { Write-Verbose "Non-constant ValidatePattern ignored: $($arguments[0].Extent.Text)" }
                    if ($regex) {
                        # Like PowerShell: case-insensitive, unless Options is explicit
                        $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                        $message = $null
                        foreach ($named in $item.NamedArguments) {
                            if ($named.ArgumentName -eq 'Options') {
                                $options = [System.Text.RegularExpressions.RegexOptions]::None
                                foreach ($name in [System.Enum]::GetNames([System.Text.RegularExpressions.RegexOptions])) {
                                    if ($named.Argument.Extent.Text -match "\b$name\b") {
                                        $options = $options -bor [System.Text.RegularExpressions.RegexOptions]$name
                                    }
                                }
                            }
                            elseif ($named.ArgumentName -eq 'ErrorMessage') {
                                try { $message = [string]$named.Argument.SafeGetValue() }
                                catch { Write-Verbose 'Non-constant ErrorMessage ignored.' }
                            }
                        }
                        $validation['Pattern'] = @{ Regex = $regex; Options = $options; Message = $message }
                    }
                }
            }
        }
    }
    $validation
}

function Format-ParameterValidation {
    # Readable labels of the constraints of a parameter ("Range: 1 to 10", "Pattern: ^\d+$").
    param([hashtable]$Validation)

    if (-not $Validation) { return }
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if ($Validation.ContainsKey('Range')) {
        $range = $Validation['Range']
        if ($null -ne $range['Min'] -and $null -ne $range['Max']) {
            Get-UiText 'analysis.validation.range' -Arguments @(
                $range['Min'].ToString($culture), $range['Max'].ToString($culture))
        }
        elseif ($null -ne $range['Min']) {
            $operator = if ($range['ExcludeMin']) { '>' } else { '≥' }
            Get-UiText 'analysis.validation.bound' -Arguments @($operator, $range['Min'].ToString($culture))
        }
        else {
            $operator = if ($range['ExcludeMax']) { '<' } else { '≤' }
            Get-UiText 'analysis.validation.bound' -Arguments @($operator, $range['Max'].ToString($culture))
        }
    }
    if ($Validation.ContainsKey('Pattern')) {
        Get-UiText 'analysis.validation.pattern' -Arguments @($Validation['Pattern'].Regex)
    }
}

function Get-ExampleArgumentValue {
    # Value of an argument read from an example: literal when possible (string, number, boolean,
    # array of literals), otherwise only its text (variable, subexpression...).
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Argument)

    $text = $Argument.Extent.Text
    if ($Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{ IsLiteral = $true; Value = $Argument.Value; Text = $text }
    }
    if ($Argument -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if ($Argument.NestedExpressions.Count -eq 0) {
            return [pscustomobject]@{ IsLiteral = $true; Value = $Argument.Value; Text = $text }
        }
    }
    elseif ($Argument -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return [pscustomobject]@{ IsLiteral = $true; Value = $text; Text = $text }
    }
    elseif ($Argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $Argument.VariablePath.UserPath
        if ($name -in 'true', 'false') {
            return [pscustomobject]@{ IsLiteral = $true; Value = ($name -eq 'true'); Text = $text }
        }
    }
    elseif ($Argument -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = @($Argument.Elements | ForEach-Object { Get-ExampleArgumentValue -Argument $_ })
        if (@($items | Where-Object { -not $_.IsLiteral }).Count -eq 0) {
            $values = [string[]]@($items | ForEach-Object { [string]$_.Value })
            return [pscustomobject]@{ IsLiteral = $true; Value = $values; Text = $text }
        }
    }
    [pscustomobject]@{ IsLiteral = $false; Value = $null; Text = $text }
}

function ConvertFrom-ExampleText {
    # Parses an .EXAMPLE: finds the call to the script and its named arguments, so that the form
    # can be filled in. $null when the example does not call this script.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$ScriptName,
        [object[]]$Parameter = @()
    )

    # The example code is its first paragraph; the rest is comment or output
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((Remove-CommonIndent -Text $Text) -split '\n')) {
        if (-not $line.Trim()) { break }
        $lines.Add($line)
    }
    if ($lines.Count -eq 0) { return $null }
    $lines[0] = $lines[0] -replace '^\s*PS(\s[^>]*)?>\s*', ''
    $code = $lines -join "`n"

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$parseErrors)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    $command = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object {
            $name = $_.GetCommandName()
            $name -and ($name -split '[\\/]')[-1] -in $ScriptName, $baseName
        } |
        Select-Object -First 1
    if (-not $command) { return $null }

    $arguments = [ordered]@{}
    $ignored = [System.Collections.Generic.List[string]]::new()
    $elements = @($command.CommandElements)
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $ignored.Add((Get-UiText 'analysis.example.unnamed' -Arguments @($element.Extent.Text)))
            continue
        }
        # Exact name, alias, then unambiguous prefix, like PowerShell parameter binding
        $name = $element.ParameterName
        $match = @($Parameter | Where-Object { $_.Name -eq $name -or $_.Aliases -contains $name })
        if ($match.Count -ne 1) { $match = @($Parameter | Where-Object { $_.Name -like "$name*" }) }
        if ($match.Count -ne 1) {
            if ($null -eq $element.Argument -and $i + 1 -lt $elements.Count -and
                $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $i++ }
            $ignored.Add((Get-UiText 'analysis.example.unknownParameter' -Arguments @($name)))
            continue
        }
        $target = $match[0]
        $argument = $element.Argument
        if ($null -eq $argument -and $target.Kind -ne 'Switch' -and $i + 1 -lt $elements.Count -and
            $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $i++
            $argument = $elements[$i]
        }
        if ($null -eq $argument) {
            $arguments[$target.Name] = [pscustomobject]@{ IsLiteral = $true; Value = $true; Text = '' }
        }
        else {
            $arguments[$target.Name] = Get-ExampleArgumentValue -Argument $argument
        }
    }
    [pscustomobject]@{ Code = $code; Arguments = $arguments; Ignored = $ignored.ToArray() }
}

function ConvertTo-ParameterInfo {
    # Metadata of a parameter read from the AST: type, input category, sets, help...
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.ParameterAst]$Parameter,
        [System.Management.Automation.Language.CommentHelpInfo]$Help,
        [hashtable]$InlineHelp = @{},
        [hashtable]$ScriptEnums = @{}
    )

    $name = $Parameter.Name.VariablePath.UserPath
    $attributes = @($Parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] })
    $typeConstraint = $Parameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } |
        Select-Object -First 1

    # StaticType is [object] when the type is missing or cannot be found in the session
    $type = $Parameter.StaticType
    $typeName = 'Object'
    $isArray = $false
    if ($typeConstraint) {
        $typeName = $typeConstraint.TypeName.FullName
        $isArray = [bool]$typeConstraint.TypeName.IsArray
    }
    $elementType = $type
    if ($type -eq [array]) {
        $isArray = $true
        $elementType = [object]
    }
    elseif ($type -and $type.IsArray) {
        $isArray = $true
        $elementType = $type.GetElementType()
    }

    $sets = [ordered]@{}
    $helpMessage = $null
    $dontShowCount = 0
    $parameterAttributes = @($attributes | Where-Object { (Get-NormalizedAttributeName $_) -eq 'Parameter' })
    foreach ($attribute in $parameterAttributes) {
        $setName = [string](Get-AttributeArgument -Attribute $attribute -Name 'ParameterSetName')
        if (-not $setName) { $setName = '__AllParameterSets' }
        $sets[$setName] = [bool](Get-AttributeArgument -Attribute $attribute -Name 'Mandatory' -AsBoolean)
        if (-not $helpMessage) {
            $helpMessage = [string](Get-AttributeArgument -Attribute $attribute -Name 'HelpMessage')
        }
        if (Get-AttributeArgument -Attribute $attribute -Name 'DontShow' -AsBoolean) { $dontShowCount++ }
    }
    if ($sets.Count -eq 0) { $sets['__AllParameterSets'] = $false }

    $aliases = [System.Collections.Generic.List[string]]::new()
    $validValues = $null
    foreach ($attribute in $attributes) {
        switch (Get-NormalizedAttributeName $attribute) {
            'Alias' {
                foreach ($argument in $attribute.PositionalArguments) {
                    try { foreach ($value in @($argument.SafeGetValue())) { $aliases.Add([string]$value) } }
                    catch { Write-Verbose "Non-static alias ignored: $($argument.Extent.Text)" }
                }
            }
            'ValidateSet' {
                $values = [System.Collections.Generic.List[string]]::new()
                $isStatic = $true
                foreach ($argument in $attribute.PositionalArguments) {
                    try { foreach ($value in @($argument.SafeGetValue())) { $values.Add([string]$value) } }
                    catch { $isStatic = $false }     # [ValidateSet([Class])]: values computed at run time
                }
                if ($isStatic -and $values.Count -gt 0) { $validValues = $values.ToArray() }
            }
        }
    }
    if (-not $validValues -and $elementType -and $elementType.IsEnum) {
        $validValues = [System.Enum]::GetNames($elementType)
    }
    if (-not $validValues -and $typeConstraint) {
        $baseTypeName = $typeConstraint.TypeName.FullName -replace '\[\]$', ''
        if ($ScriptEnums.ContainsKey($baseTypeName)) { $validValues = @($ScriptEnums[$baseTypeName]) }
    }

    if ($type -eq [System.Management.Automation.SwitchParameter]) { $kind = 'Switch' }
    elseif ($validValues) { $kind = if ($isArray) { 'MultiChoice' } else { 'Choice' } }
    elseif ($type -eq [bool]) { $kind = 'Bool' }
    elseif ($type -eq [System.Management.Automation.PSCredential]) { $kind = 'Credential' }
    elseif ($type -eq [System.Security.SecureString]) { $kind = 'SecureString' }
    elseif ($type -eq [scriptblock] -or ($type -and [System.Collections.IDictionary].IsAssignableFrom($type))) {
        $kind = 'Expression'
    }
    elseif ($isArray) { $kind = 'TextArray' }
    else { $kind = Get-ValueKind -Type $type }

    # Description: .PARAMETER, else a comment inside param(), else HelpMessage
    $description = $null
    if ($Help -and $Help.Parameters) {
        $key = $name.ToUpperInvariant()
        if ($Help.Parameters.ContainsKey($key)) { $description = Remove-CommonIndent -Text $Help.Parameters[$key] }
    }
    if (-not $description -and $InlineHelp.ContainsKey($name)) { $description = $InlineHelp[$name] }
    if (-not $description -and $helpMessage) { $description = $helpMessage }

    $defaultValue = $null
    if ($Parameter.DefaultValue) { $defaultValue = $Parameter.DefaultValue.Extent.Text }

    [pscustomobject]@{
        Name                  = $name
        TypeName              = $typeName
        Type                  = $type
        Kind                  = $kind
        IsArray               = $isArray
        ElementKind           = Get-ValueKind -Type $elementType
        IsInteger             = Test-IntegerType -Type $elementType
        IsDecimal             = ($null -ne $elementType -and $elementType -eq [decimal])
        ValidValues           = $validValues
        Sets                  = $sets
        HasParameterAttribute = ($parameterAttributes.Count -gt 0)
        Aliases               = $aliases.ToArray()
        DefaultValue          = $defaultValue
        Description           = $description
        DontShow              = ($parameterAttributes.Count -gt 0 -and $dontShowCount -eq $parameterAttributes.Count)
        Validation            = Get-ParameterValidation -Attribute $attributes
    }
}

function Get-ScriptInfo {
    # Reads a script (AST) and returns everything needed to show it and launch it: parameters and
    # examples included. The inventory always uses the full analysis; the cache is what keeps a
    # scan cheap, since unchanged files are never parsed again.
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$RelativePath
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $text = ''
    try { $text = Read-ScriptText -LiteralPath $LiteralPath }
    catch { $warnings.Add((Get-UiText 'analysis.warning.readFailed' -Arguments @($_.Exception.Message))) }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $text, $LiteralPath, [ref]$tokens, [ref]$parseErrors)
    $parseErrors = @($parseErrors | Where-Object { $_ })
    $shown = $script:Settings.MaxParseErrorShown
    foreach ($parseError in @($parseErrors | Select-Object -First $shown)) {
        $warnings.Add((Get-UiText 'analysis.warning.parseError' `
                -Arguments @($parseError.Extent.StartLineNumber, $parseError.Message)))
    }
    if ($parseErrors.Count -gt $shown) {
        $warnings.Add((Get-UiText 'analysis.warning.moreParseError' -Arguments @($parseErrors.Count - $shown)))
    }

    $help = $null
    try { $help = $ast.GetHelpContent() }
    catch { Write-Verbose "Unreadable help in ${LiteralPath}: $($_.Exception.Message)" }
    # The raw block feeds the help search, and tells us about unrecognised sections
    $helpToken = Find-HelpCommentToken -Ast $ast -Tokens $tokens
    $helpBlock = if ($helpToken) { $helpToken.Text } else { '' }
    if ($null -eq $help) {
        $misplaced = Find-MisplacedHelp -Ast $ast -Tokens $tokens
        if ($misplaced) {
            $help = $misplaced.Help
            $warnings.Add($misplaced.Reason)
        }
        else {
            $ignored = Get-IgnoredHelp -Ast $ast -Tokens $tokens
            if ($ignored) {
                if ($ignored.Help) { $help = $ignored.Help }
                $warnings.Add($ignored.Reason)
            }
        }
    }

    $paramBlock = $ast.ParamBlock
    $isAdvanced = $false
    $supportsShouldProcess = $false
    $defaultSet = ''
    if ($paramBlock) {
        foreach ($attribute in $paramBlock.Attributes) {
            if ((Get-NormalizedAttributeName $attribute) -eq 'CmdletBinding') {
                $isAdvanced = $true
                $supportsShouldProcess = [bool](
                    Get-AttributeArgument -Attribute $attribute -Name 'SupportsShouldProcess' -AsBoolean)
                $defaultSet = [string](Get-AttributeArgument -Attribute $attribute -Name 'DefaultParameterSetName')
            }
        }
    }

    $parameters = [System.Collections.Generic.List[object]]::new()
    $setNames = [System.Collections.Generic.List[string]]::new()
    if ($paramBlock) {
        # Like Get-Help: the comments of param() only count when the script has a help block
        $inlineHelp = @{}
        if ($help) { $inlineHelp = Get-InlineParameterHelp -ParamBlock $paramBlock -Tokens $tokens }

        $scriptEnums = @{}
        if ($text -match '(?im)^\s*enum\s+\w') {
            $enumAsts = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TypeDefinitionAst] -and $node.IsEnum
                }, $true)
            foreach ($enumAst in $enumAsts) {
                $scriptEnums[$enumAst.Name] = @($enumAst.Members | ForEach-Object { $_.Name })
            }
        }

        foreach ($parameter in $paramBlock.Parameters) {
            $info = ConvertTo-ParameterInfo -Parameter $parameter -Help $help -InlineHelp $inlineHelp `
                -ScriptEnums $scriptEnums
            $parameters.Add($info)
            if ($info.HasParameterAttribute) { $isAdvanced = $true }
            foreach ($setName in $info.Sets.Keys) {
                if ($setName -ne '__AllParameterSets' -and -not $setNames.Contains($setName)) { $setNames.Add($setName) }
            }
        }
    }
    $examples = [System.Collections.Generic.List[object]]::new()
    if ($help) {
        $scriptName = [System.IO.Path]::GetFileName($LiteralPath)
        $number = 0
        foreach ($exampleText in $help.Examples) {
            $number++
            $example = ConvertFrom-ExampleText -Text $exampleText -ScriptName $scriptName -Parameter $parameters.ToArray()
            if ($example) {
                $example | Add-Member -NotePropertyName Number -NotePropertyValue $number
                $examples.Add($example)
            }
        }
    }
    if ($defaultSet -and -not $setNames.Contains($defaultSet)) { $setNames.Insert(0, $defaultSet) }
    if (-not $defaultSet -and $setNames.Count -gt 0) { $defaultSet = $setNames[0] }
    if ($ast.DynamicParamBlock) {
        $warnings.Add((Get-UiText 'analysis.warning.dynamicParam'))
    }

    $requirements = [pscustomobject]@{ PSVersion = $null; PSEditions = @(); Modules = @(); RunAsAdmin = $false }
    $scriptRequirements = $ast.ScriptRequirements
    if ($scriptRequirements) {
        $requirements.PSVersion = $scriptRequirements.RequiredPSVersion
        $requirements.PSEditions = @($scriptRequirements.RequiredPSEditions | Where-Object { $_ })
        $requirements.Modules = @(
            $scriptRequirements.RequiredModules | Where-Object { $_ } | ForEach-Object { $_.Name })
        $requirements.RunAsAdmin = [bool]$scriptRequirements.IsElevationRequired
    }

    $synopsis = ''
    $description = ''
    if ($help) {
        $synopsis = Remove-CommonIndent -Text $help.Synopsis
        $description = Remove-CommonIndent -Text $help.Description
    }
    # What the launcher cannot show for this script, which is exactly what the window displays.
    $undocumented = [string[]]@($parameters |
            Where-Object { -not $_.DontShow -and [string]::IsNullOrWhiteSpace([string]$_.Description) } |
            ForEach-Object { $_.Name })
    $missingSynopsis = [string]::IsNullOrWhiteSpace($synopsis)
    $missingDescription = [string]::IsNullOrWhiteSpace($description)
    $missingExample = (@($examples).Count -eq 0)
    $helpStatus = if (-not ($missingSynopsis -or $missingDescription -or $missingExample -or $undocumented.Count -gt 0)) { 'full' }
    elseif ($missingSynopsis -and $missingDescription) { 'none' }
    else { 'partial' }
    if (-not $RelativePath) { $RelativePath = [System.IO.Path]::GetFileName($LiteralPath) }

    # Everything the window can display, as one searchable string: name, folder, synopsis,
    # description, parameters and their descriptions, examples, and the raw help block (.NOTES,
    # free comments, even sections Get-Help rejects). Kept in memory only, never in the cache.
    $searchParts = [System.Collections.Generic.List[string]]::new()
    $searchParts.Add($RelativePath)
    $searchParts.Add($synopsis)
    $searchParts.Add($description)
    foreach ($parameter in $parameters) {
        $searchParts.Add($parameter.Name)
        $searchParts.Add([string]$parameter.Description)
    }
    foreach ($example in $examples) { $searchParts.Add([string]$example.Code) }
    $searchParts.Add($helpBlock)
    $searchText = (@($searchParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ')

    [pscustomobject]@{
        Path                  = $LiteralPath
        Name                  = [System.IO.Path]::GetFileName($LiteralPath)
        BaseName              = [System.IO.Path]::GetFileNameWithoutExtension($LiteralPath)
        Directory             = [System.IO.Path]::GetDirectoryName($LiteralPath)
        RelativePath          = $RelativePath
        RelativeDirectory     = [System.IO.Path]::GetDirectoryName($RelativePath)
        Synopsis              = $synopsis
        Description           = $description
        HelpBlock             = $helpBlock
        SearchText            = $searchText
        HelpStatus            = $helpStatus
        Help                  = $help
        Examples              = $examples.ToArray()
        Parameters            = $parameters.ToArray()
        ParameterSets         = $setNames.ToArray()
        DefaultParameterSet   = $defaultSet
        IsAdvanced            = $isAdvanced
        SupportsShouldProcess = $supportsShouldProcess
        Requirements          = $requirements
        Warnings              = $warnings.ToArray()
        MissingSynopsis       = $missingSynopsis
        MissingDescription    = $missingDescription
        MissingExample        = $missingExample
        UndocumentedParameters = $undocumented
        UndocumentedCount     = $undocumented.Count
    }
}

function Get-HelpGap {
    # What the launcher cannot show for this script, in a stable order: 'synopsis', 'description',
    # 'example', 'parameters'. These are exactly the four things the window displays.
    param([Parameter(Mandatory)]$ScriptInfo)

    $gaps = [System.Collections.Generic.List[string]]::new()
    if ($ScriptInfo.MissingSynopsis) { $gaps.Add('synopsis') }
    if ($ScriptInfo.MissingDescription) { $gaps.Add('description') }
    if ($ScriptInfo.MissingExample) { $gaps.Add('example') }
    if ([int]$ScriptInfo.UndocumentedCount -gt 0) { $gaps.Add('parameters') }
    $gaps.ToArray()
}

function Test-IncompleteHelp {
    # True when the help lacks content: no synopsis, no description, or no example. Missing
    # parameter descriptions are far more common, so they are reported and filtered apart.
    param([Parameter(Mandatory)]$ScriptInfo)

    [bool]($ScriptInfo.MissingSynopsis -or $ScriptInfo.MissingDescription -or $ScriptInfo.MissingExample)
}

function Get-ScriptWarningCount {
    # Number of warnings of a script. A cached entry only keeps the count: the text is rebuilt
    # when the script is selected, in the current interface language.
    param([Parameter(Mandatory)]$ScriptInfo)

    if ($null -ne $ScriptInfo.WarningCount) { return [int]$ScriptInfo.WarningCount }
    @($ScriptInfo.Warnings).Count
}

function Get-ScriptCatalog {
    # Recursive inventory of the .ps1 scripts of the root folder.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ExcludePattern = @(),
        [string]$ExcludeFile,
        # Folders (full paths) to ignore entirely: the module of the launcher itself
        [string[]]$ExcludeDirectory = @(),
        # Synchronized table { Total; Done } updated as the analysis goes (background inventory)
        [hashtable]$Progress,
        # Per-folder cache (Private\Cache.ps1): files that did not change are not parsed again
        [hashtable]$Cache
    )

    $rootItem = Get-Item -LiteralPath $Root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw (Get-UiText 'analysis.error.notFolder' -Arguments @($Root)) }
    $rootFull = $rootItem.FullName.TrimEnd('\', '/')

    # Unreadable folders (rights) do not stop the inventory: they are counted and reported
    $scanErrors = $null
    $files = @(Get-ChildItem -LiteralPath $rootFull -Filter '*.ps1' -File -Recurse `
            -ErrorAction SilentlyContinue -ErrorVariable scanErrors)

    $excludedPrefixes = @($ExcludeDirectory | Where-Object { $_ } | ForEach-Object {
            $_.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        })
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        # -Filter '*.ps1' can return .ps1xml files (8.3 short names): the extension is checked again
        if ($file.Extension -ne '.ps1') { continue }
        $isExcludedFile = $ExcludeFile -and
            [string]::Equals($file.FullName, $ExcludeFile, [System.StringComparison]::OrdinalIgnoreCase)
        if ($isExcludedFile) { continue }

        $excluded = $false
        foreach ($prefix in $excludedPrefixes) {
            if ($file.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $excluded = $true
                break
            }
        }
        $relative = $file.Name
        if ($file.FullName.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        }
        foreach ($pattern in $ExcludePattern) {
            if ($relative -like $pattern -or $file.Name -like $pattern) {
                $excluded = $true
                break
            }
        }
        if (-not $excluded) { $selected.Add([pscustomobject]@{ FullName = $file.FullName; Relative = $relative; File = $file }) }
    }

    if ($Progress) { $Progress['Total'] = $selected.Count }
    $scripts = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($file in $selected) {
        $key = Get-CacheKey -Path $file.FullName
        $seen[$key] = $true
        $entry = $null
        if ($Cache -and $Cache.Entries.ContainsKey($key)) {
            $candidate = $Cache.Entries[$key]
            if (Test-CachedFile -Entry $candidate -File $file.File) { $entry = $candidate }
        }
        if ($entry) {
            # Unchanged file: the tree uses the cached synopsis, the detail pane re-reads the file
            $scripts.Add((ConvertFrom-CachedScript -Entry $entry -Root $rootFull))
        }
        else {
            $info = Get-ScriptInfo -LiteralPath $file.FullName -RelativePath $file.Relative
            $scripts.Add($info)
            if ($Cache) {
                $Cache.Entries[$key] = @{
                    Mtime        = $file.File.LastWriteTimeUtc.Ticks
                    Size         = [long]$file.File.Length
                    RelativePath = $file.Relative
                    Synopsis     = [string]$info.Synopsis
                    HelpBlock    = [string]$info.HelpBlock
                    HelpStatus   = [string]$info.HelpStatus
                    MissingSynopsis    = [bool]$info.MissingSynopsis
                    MissingDescription = [bool]$info.MissingDescription
                    MissingExample     = [bool]$info.MissingExample
                    Undocumented       = [string[]]@($info.UndocumentedParameters)
                    Warnings     = @($info.Warnings).Count
                }
            }
        }
        if ($Progress) { $Progress['Done'] = $scripts.Count }
    }

    # Entries of deleted or hidden files are dropped: the cache follows the folder
    if ($Cache) {
        foreach ($key in @($Cache.Entries.Keys)) {
            if (-not $seen.ContainsKey($key)) { $Cache.Entries.Remove($key) }
        }
    }

    [pscustomobject]@{
        Root       = $rootFull
        Scripts    = @($scripts | Sort-Object -Property RelativePath)
        ScanErrors = @($scanErrors | Where-Object { $_ })
        Cache      = $Cache
    }
}

function Get-HelpSectionText {
    # Text of one section of a raw help block (DESCRIPTION, NOTES...), for cached scripts that
    # keep only the block. Empty when the section is missing.
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $pattern = '(?ims)^[ \t]*\.' + $Name + '[ \t]*(.*?)(?=^[ \t]*\.[A-Za-z]|\z)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return '' }
    ($match.Groups[1].Value -replace '\s+', ' ').Trim()
}

function Get-HelpParameterSection {
    # Parameter descriptions read straight from a raw help block, as Name = text. Used for cached
    # scripts, where only the block is kept, so they can still say which parameter matched.
    param([AllowEmptyString()][string]$Text)

    $sections = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $sections }
    $pattern = '(?ims)^[ \t]*\.PARAMETER[ \t]+([A-Za-z0-9_-]+)[ \t]*(.*?)(?=^[ \t]*\.[A-Za-z]|\z)'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $name = $match.Groups[1].Value
        $body = ($match.Groups[2].Value -replace '\s+', ' ').Trim()
        if ($name -and -not $sections.ContainsKey($name)) { $sections[$name] = $body }
    }
    $sections
}

function Get-ScriptMatchSnippet {
    # A short excerpt around the first search term, so the user sees the sentence that matched,
    # not only the name of the field.
    param([Parameter(Mandatory)]$ScriptInfo, [string]$Filter)

    if ([string]::IsNullOrWhiteSpace($Filter)) { return '' }
    $term = @($Filter.Trim() -split '\s+' | Where-Object { $_ })[0]
    if (-not $term) { return '' }

    # Clean fields first: the raw block is only a fallback, and its section markers make a poor
    # excerpt
    $haystacks = @([string]$ScriptInfo.Description)
    if ($ScriptInfo.ParameterHelp -is [hashtable]) {
        foreach ($text in $ScriptInfo.ParameterHelp.Values) { $haystacks += [string]$text }
    }
    foreach ($parameter in @($ScriptInfo.Parameters)) { $haystacks += [string]$parameter.Description }
    foreach ($example in @($ScriptInfo.Examples)) { $haystacks += [string]$example.Code }
    $haystacks += [string]$ScriptInfo.HelpBlock

    $compareInfo = [System.Globalization.CultureInfo]::CurrentCulture.CompareInfo
    $options = [System.Globalization.CompareOptions]'IgnoreCase, IgnoreNonSpace'
    foreach ($haystack in $haystacks) {
        if ([string]::IsNullOrWhiteSpace($haystack)) { continue }
        $index = $compareInfo.IndexOf($haystack, $term, $options)
        if ($index -lt 0) { continue }
        $text = $haystack -replace '\s+', ' '
        $flat = $compareInfo.IndexOf($text, $term, $options)
        if ($flat -lt 0) { $flat = 0 }
        $start = [Math]::Max(0, $flat - 40)
        $length = [Math]::Min($text.Length - $start, [Math]::Max($term.Length + 60, 60))
        $snippet = $text.Substring($start, $length).Trim()
        $snippet = [regex]::Replace($snippet, '\.(SYNOPSIS|DESCRIPTION|PARAMETER|EXAMPLE|NOTES|INPUTS|OUTPUTS|LINK)\b', ' ')
        $snippet = [regex]::Replace($snippet, '\s{2,}', ' ').Trim()
        if ($start -gt 0) { $snippet = '…' + $snippet }
        if ($start + $length -lt $text.Length) { $snippet = $snippet + '…' }
        return $snippet
    }
    ''
}

function Get-ScriptMatchField {
    # Where the search matched, once: Kind is name, description, parameter, example or help (empty
    # when nothing matched), Name carries the parameter name when there is one.
    param([Parameter(Mandatory)]$ScriptInfo, [string]$Filter)

    if ([string]::IsNullOrWhiteSpace($Filter)) { return $null }
    $terms = @($Filter.Trim() -split '\s+' | Where-Object { $_ })
    if ($terms.Count -eq 0) { return $null }
    $compareInfo = [System.Globalization.CultureInfo]::CurrentCulture.CompareInfo
    $options = [System.Globalization.CompareOptions]'IgnoreCase, IgnoreNonSpace'
    $found = {
        param([string]$Haystack, [string]$Term)
        if ([string]::IsNullOrWhiteSpace($Haystack)) { return $false }
        $compareInfo.IndexOf($Haystack, $Term, $options) -ge 0
    }

    # Name and synopsis are already visible in the tree: their own group
    $identity = $ScriptInfo.RelativePath + ' ' + $ScriptInfo.Synopsis
    $allInIdentity = $true
    foreach ($term in $terms) {
        if (-not (& $found $identity $term)) { $allInIdentity = $false; break }
    }
    if ($allInIdentity) { return @{ Kind = 'name'; Name = '' } }

    foreach ($term in $terms) {
        if (& $found ([string]$ScriptInfo.Description) $term) { return @{ Kind = 'description'; Name = '' } }
    }

    # Parameters of a freshly analysed script, or the ones the cache rebuilt from the help block
    $parameterHelp = @{}
    if ($ScriptInfo.ParameterHelp -is [hashtable]) { $parameterHelp = $ScriptInfo.ParameterHelp }
    if ($parameterHelp.Count -eq 0) {
        foreach ($parameter in @($ScriptInfo.Parameters)) {
            if ($parameter -and $parameter.PSObject.Properties['Name']) {
                $parameterHelp[[string]$parameter.Name] = [string]$parameter.Description
            }
        }
    }
    if ($parameterHelp.Count -eq 0 -and $ScriptInfo.HelpBlock) {
        $parameterHelp = Get-HelpParameterSection -Text ([string]$ScriptInfo.HelpBlock)
    }
    foreach ($term in $terms) {
        foreach ($name in $parameterHelp.Keys) {
            if ((& $found ([string]$name) $term) -or (& $found ([string]$parameterHelp[$name]) $term)) {
                return @{ Kind = 'parameter'; Name = [string]$name }
            }
        }
    }

    foreach ($term in $terms) {
        foreach ($example in @($ScriptInfo.Examples)) {
            if (& $found ([string]$example.Code) $term) { return @{ Kind = 'example'; Name = '' } }
        }
    }
    foreach ($term in $terms) {
        if (& $found ([string]$ScriptInfo.HelpBlock) $term) { return @{ Kind = 'help'; Name = '' } }
    }
    @{ Kind = ''; Name = '' }
}

function Get-ScriptMatchKind {
    # Group a result belongs to while searching: name, description, parameter, example or help.
    param([Parameter(Mandatory)]$ScriptInfo, [string]$Filter)

    $field = Get-ScriptMatchField -ScriptInfo $ScriptInfo -Filter $Filter
    if ($null -eq $field) { return '' }
    [string]$field.Kind
}

function Get-ScriptMatchReason {
    # Label of the match, for the detail pane: never empty when the search matched outside the name.
    param([Parameter(Mandatory)]$ScriptInfo, [string]$Filter)

    $field = Get-ScriptMatchField -ScriptInfo $ScriptInfo -Filter $Filter
    if ($null -eq $field) { return '' }
    switch ([string]$field.Kind) {
        'description' { return (Get-UiText 'search.match.description') }
        'parameter' { return (Get-UiText 'search.match.parameter' -Arguments @($field.Name)) }
        'example' { return (Get-UiText 'search.match.example') }
        'help' { return (Get-UiText 'search.match.help') }
        default { return '' }
    }
}
function Test-ScriptFilter {
    # Multi-term search (AND), case- and accent-insensitive.
    param(
        [Parameter(Mandatory)]$ScriptInfo,
        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) { return $true }
    $compareInfo = [System.Globalization.CultureInfo]::CurrentCulture.CompareInfo
    $options = [System.Globalization.CompareOptions]'IgnoreCase, IgnoreNonSpace'
    # Full help text when the script was analysed in this session, name and synopsis otherwise
    $haystack = [string]$ScriptInfo.SearchText
    if ([string]::IsNullOrWhiteSpace($haystack)) { $haystack = $ScriptInfo.RelativePath + ' ' + $ScriptInfo.Synopsis }
    foreach ($term in ($Filter.Trim() -split '\s+')) {
        if ($compareInfo.IndexOf($haystack, $term, $options) -lt 0) { return $false }
    }
    $true
}
