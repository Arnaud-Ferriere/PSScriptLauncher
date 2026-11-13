# Conversion of typed values, command building and launch.

function ConvertTo-PSQuotedString {
    # Single-quoted literal. CodeGeneration also doubles typographic apostrophes
    # (’ ‘ ‚ ‛), which PowerShell treats as straight apostrophes.
    param([AllowNull()][AllowEmptyString()][string]$Value)

    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Value) + "'"
}

function ConvertTo-InvariantNumber {
    # Reads the number in the user's culture (3,5 in fr-FR), or else in the invariant culture
    # (3.5), and rewrites it in invariant notation. $null if the input is not a valid number.
    param([string]$Text, [switch]$Integer)

    $styles = [System.Globalization.NumberStyles]::Float
    $value = [decimal]0
    $parsed = $false
    $cultures = [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($culture in $cultures) {
        if ([decimal]::TryParse($Text.Trim(), $styles, $culture, [ref]$value)) {
            $parsed = $true
            break
        }
    }
    if (-not $parsed) { return $null }
    if ($Integer) {
        if ($value -ne [decimal]::Truncate($value)) { return $null }
        return [decimal]::Truncate($value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    $value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-InvariantDate {
    # Reads the date in the user's culture and rewrites it in ISO 8601 (unambiguous).
    param([string]$Text)

    $value = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if (-not [datetime]::TryParse($Text.Trim(), $culture, $styles, [ref]$value)) { return $null }
    $format = if ($value.TimeOfDay -eq [timespan]::Zero) { 'yyyy-MM-dd' } else { "yyyy-MM-dd'T'HH:mm:ss" }
    $value.ToString($format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-ArgumentValue {
    # Typed scalar value -> PowerShell argument text, plus a message when it is not valid.
    param([string]$Text, [string]$ValueKind, [switch]$Integer, [switch]$Decimal)

    if ($ValueKind -eq 'Number') {
        $number = ConvertTo-InvariantNumber -Text $Text -Integer:$Integer
        if ($null -ne $number) {
            # Number as a literal. For a [decimal], d suffix: a string ('1234.10') would be
            # converted through a [double] (15 significant digits, scale lost).
            if ($Decimal) { $number += 'd' }
            return [pscustomobject]@{ Text = $number; Error = $null }
        }
        $expected = if ($Integer) {
            Get-UiText 'command.error.integerExpected'
        }
        else {
            Get-UiText 'command.error.numberExpected'
        }
        return [pscustomobject]@{
            Text  = (ConvertTo-PSQuotedString $Text)
            Error = (Get-UiText 'command.error.valueRejected' -Arguments @($Text, $expected))
        }
    }
    if ($ValueKind -eq 'Date') {
        $date = ConvertTo-InvariantDate -Text $Text
        if ($null -ne $date) { return [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $date); Error = $null } }
        return [pscustomobject]@{
            Text  = (ConvertTo-PSQuotedString $Text)
            Error = (Get-UiText 'command.error.dateNotRecognized' -Arguments @($Text))
        }
    }
    [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $Text); Error = $null }
}

function Test-ParameterValidation {
    # Applies [ValidateRange()] and [ValidatePattern()] to a typed value. Returns the error
    # message, or $null when the value is acceptable (or nothing can be checked).
    param(
        [Parameter(Mandatory)]$Parameter,
        [AllowEmptyString()][string]$Text
    )

    $validation = $Parameter.Validation
    if (-not $validation -or $validation.Count -eq 0) { return $null }

    if ($validation.ContainsKey('Range') -and $Parameter.ElementKind -eq 'Number') {
        $number = ConvertTo-InvariantNumber -Text $Text
        if ($null -ne $number) {
            $value = [decimal]::Parse($number, [System.Globalization.CultureInfo]::InvariantCulture)
            $range = $validation['Range']
            $min = $range['Min']
            $max = $range['Max']
            $tooLow = $null -ne $min -and ($value -lt $min -or ($range['ExcludeMin'] -and $value -eq $min))
            $tooHigh = $null -ne $max -and ($value -gt $max -or ($range['ExcludeMax'] -and $value -eq $max))
            if ($tooLow -or $tooHigh) {
                $expected = (@(Format-ParameterValidation -Validation @{ Range = $range }) -join '').ToLower()
                return (Get-UiText 'command.error.outOfRange' -Arguments @($Text, $expected))
            }
        }
    }
    if ($validation.ContainsKey('Pattern')) {
        $pattern = $validation['Pattern']
        $isMatch = $true
        try { $isMatch = [regex]::IsMatch($Text, $pattern.Regex, $pattern.Options) }
        catch { Write-Verbose "Invalid ValidatePattern pattern, not checked: $($pattern.Regex)" }
        if (-not $isMatch) {
            if ($pattern.Message) {
                return (Get-UiText 'command.error.valueRejected' -Arguments @(
                        $Text, ($pattern.Message -f $Text, $pattern.Regex)))
            }
            return (Get-UiText 'command.error.patternMismatch' -Arguments @($Text, $pattern.Regex))
        }
    }
    $null
}

function ConvertTo-ParameterArgument {
    # Typed value for one parameter -> command-line argument ($null when it is not filled in).
    param([Parameter(Mandatory)]$Parameter, $Value)

    $name = $Parameter.Name
    $errors = [System.Collections.Generic.List[string]]::new()
    $text = $null

    switch ($Parameter.Kind) {
        'Switch' {
            if ($Value -eq $true) { $text = "-$name" }
        }
        'Bool' {
            if ($Value -eq 'true') { $text = "-${name}:`$true" }
            elseif ($Value -eq 'false') { $text = "-${name}:`$false" }
        }
        'SecureString' {
            if ($Value -eq $true) {
                $text = "-$name (Read-Host -AsSecureString -Prompt $(ConvertTo-PSQuotedString $name))"
            }
        }
        'Credential' {
            if ($Value -and $Value.Prompt) {
                # -Message is required by Windows PowerShell 5.1 as soon as -UserName is given
                $message = ConvertTo-PSQuotedString (
                    Get-UiText 'command.credential.message' -Arguments @($name))
                if ([string]::IsNullOrWhiteSpace($Value.UserName)) {
                    $text = "-$name (Get-Credential -Message $message)"
                }
                else {
                    $userName = ConvertTo-PSQuotedString $Value.UserName.Trim()
                    $text = "-$name (Get-Credential -UserName $userName -Message $message)"
                }
            }
        }
        { $_ -in 'Choice', 'MultiChoice', 'TextArray' } {
            $items = @(
                @($Value) |
                    ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } |
                    Where-Object { $_ -ne '' }
            )
            if ($items.Count -gt 0) {
                $parts = foreach ($item in $items) {
                    $converted = ConvertTo-ArgumentValue -Text $item -ValueKind $Parameter.ElementKind `
                        -Integer:([bool]$Parameter.IsInteger) -Decimal:([bool]$Parameter.IsDecimal)
                    if ($converted.Error) { $errors.Add($converted.Error) }
                    elseif ($Parameter.Kind -eq 'TextArray') {
                        $invalid = Test-ParameterValidation -Parameter $Parameter -Text $item
                        if ($invalid) { $errors.Add($invalid) }
                    }
                    $converted.Text
                }
                $text = "-$name " + (@($parts) -join ',')
            }
        }
        'Expression' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
                $expression = ([string]$Value).Trim()
                $needsBraces = $Parameter.Type -eq [scriptblock] -and
                    -not $expression.StartsWith('{', [System.StringComparison]::Ordinal)
                if ($needsBraces) { $expression = '{ ' + $expression + ' }' }
                $text = "-$name $expression"
            }
        }
        default {
            if (-not [string]::IsNullOrEmpty([string]$Value)) {
                $converted = ConvertTo-ArgumentValue -Text ([string]$Value) -ValueKind $Parameter.Kind `
                    -Integer:([bool]$Parameter.IsInteger) -Decimal:([bool]$Parameter.IsDecimal)
                if ($converted.Error) { $errors.Add($converted.Error) }
                elseif ($Parameter.Kind -in 'Text', 'Number') {
                    $invalid = Test-ParameterValidation -Parameter $Parameter -Text ([string]$Value).Trim()
                    if ($invalid) { $errors.Add($invalid) }
                }
                $text = "-$name " + $converted.Text
            }
        }
    }
    [pscustomobject]@{ Text = $text; Errors = $errors.ToArray() }
}

function Get-ParameterSetMembership {
    # $null when the parameter does not belong to the set; otherwise $true (mandatory) or $false.
    param([Parameter(Mandatory)]$Parameter, [string]$ParameterSet)

    $sets = $Parameter.Sets
    if (-not $ParameterSet) { return (@($sets.Values) -contains $true) }
    if ($sets.Contains($ParameterSet)) { return [bool]$sets[$ParameterSet] }
    if ($sets.Contains('__AllParameterSets')) { return [bool]$sets['__AllParameterSets'] }
    $null
}

function New-ScriptCommand {
    # Builds the script call command from the typed values.
    param(
        [Parameter(Mandatory)]$ScriptInfo,
        [string]$ParameterSet,
        [hashtable]$Values = @{},
        [string[]]$CommonParameter = @(),
        [string]$ExtraArguments
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $errors = @{}
    foreach ($parameter in $ScriptInfo.Parameters) {
        if ($parameter.DontShow) { continue }
        $mandatory = Get-ParameterSetMembership -Parameter $parameter -ParameterSet $ParameterSet
        if ($null -eq $mandatory) { continue }
        $value = $null
        if ($Values.ContainsKey($parameter.Name)) { $value = $Values[$parameter.Name] }
        $argument = ConvertTo-ParameterArgument -Parameter $parameter -Value $value
        if ($argument.Text) { $arguments.Add($argument.Text) }
        elseif ($mandatory -and $parameter.Kind -ne 'Switch') { $missing.Add($parameter.Name) }
        if ($argument.Errors.Count -gt 0) { $errors[$parameter.Name] = $argument.Errors }
    }
    foreach ($common in $CommonParameter) { $arguments.Add("-$common") }
    if (-not [string]::IsNullOrWhiteSpace($ExtraArguments)) { $arguments.Add($ExtraArguments.Trim()) }

    $argumentText = $arguments -join ' '
    $commandText = '& ' + (ConvertTo-PSQuotedString $ScriptInfo.Path)
    if ($argumentText) { $commandText += ' ' + $argumentText }
    [pscustomobject]@{
        CommandText  = $commandText
        ArgumentText = $argumentText
        Missing      = $missing.ToArray()
        Errors       = $errors
    }
}

function ConvertTo-ProcessArgument {
    # Escapes an argument for the Windows command line (CommandLineToArgvW/MSVCRT rules:
    # 2n backslashes + a quote -> n backslashes + end of string; 2n+1 -> n + quote).
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') { [void]$builder.Append([char]'\', 2 * $backslashes + 1) }
        elseif ($backslashes -gt 0) { [void]$builder.Append([char]'\', $backslashes) }
        [void]$builder.Append($character)
        $backslashes = 0
    }
    [void]$builder.Append([char]'\', 2 * $backslashes)
    [void]$builder.Append('"')
    $builder.ToString()
}

function New-LaunchArgumentString {
    # Arguments of powershell.exe / pwsh.exe to run the command in a new console.
    # No -EncodedCommand: often flagged by EDR, and unreadable in the logs.
    param(
        [Parameter(Mandatory)][string]$CommandText,
        [string]$Title,
        [string]$WorkingDirectory,
        [switch]$NoExit,
        [switch]$NoProfile
    )

    $statements = [System.Collections.Generic.List[string]]::new()
    if ($Title) { $statements.Add('$Host.UI.RawUI.WindowTitle = ' + (ConvertTo-PSQuotedString $Title)) }
    # -WorkingDirectory is ignored by an elevated launch: the location is set explicitly
    if ($WorkingDirectory) {
        $statements.Add('Set-Location -LiteralPath ' + (ConvertTo-PSQuotedString $WorkingDirectory))
    }
    # Echo of the command in the console (Write-Host: display only, nothing in the pipeline).
    # Truncated beyond a certain length: the command appears twice on the command line.
    $echo = 'PS> ' + $CommandText
    $maxEcho = $script:Settings.MaxEchoLength
    if ($echo.Length -gt $maxEcho) { $echo = $echo.Substring(0, $maxEcho) + ' [...]' }
    $statements.Add('Write-Host ' + (ConvertTo-PSQuotedString $echo) + ' -ForegroundColor DarkGray')
    $statements.Add($CommandText)

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoLogo')
    if ($NoProfile) { $arguments.Add('-NoProfile') }
    if ($NoExit) { $arguments.Add('-NoExit') }
    $arguments.Add('-Command')
    $arguments.Add((ConvertTo-ProcessArgument ($statements -join '; ')))
    $arguments -join ' '
}

function Get-PreferredEdition {
    # Edition forced by #Requires (Core, Desktop), or $null.
    param([Parameter(Mandatory)]$ScriptInfo)

    $requirements = $ScriptInfo.Requirements
    $needsCore = $requirements.PSEditions -contains 'Core' -or
        ($requirements.PSVersion -and $requirements.PSVersion.Major -ge 6)
    if ($needsCore) { return 'Core' }
    if ($requirements.PSEditions -contains 'Desktop') { return 'Desktop' }
    $null
}

function Get-PowerShellEngine {
    # Available engines: Windows PowerShell 5.1, and PowerShell 7+ (pwsh) when it is installed.
    $engines = [System.Collections.Generic.List[object]]::new()
    if ($env:SystemRoot) {
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $windowsPowerShell) {
            $engines.Add([pscustomobject]@{
                    Name    = 'Windows PowerShell 5.1'
                    Path    = $windowsPowerShell
                    Edition = 'Desktop'
                })
        }
    }
    $pwshPath = $null
    $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pwsh) { $pwshPath = $pwsh.Path }
    elseif ($PSVersionTable.PSEdition -eq 'Core') { $pwshPath = (Get-Process -Id $PID).Path }
    if ($pwshPath) {
        $label = 'PowerShell 7'
        try {
            $version = (Get-Item -LiteralPath $pwshPath).VersionInfo.ProductVersion -replace '[\s+].*$', ''
            if ($version) { $label = "PowerShell $version" }
        }
        catch { Write-Verbose "Unreadable pwsh version: $($_.Exception.Message)" }
        $engines.Add([pscustomobject]@{ Name = $label; Path = $pwshPath; Edition = 'Core' })
    }
    $engines.ToArray()
}

function Resolve-NetworkPath {
    # Mapped network drive -> UNC path: an elevated console does not see the mapped drives of
    # the non-elevated session (different token).
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '^([A-Za-z]):') {
        $drive = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\', [System.StringComparison]::Ordinal)) {
            return $drive.DisplayRoot.TrimEnd('\') + $Path.Substring(2)
        }
    }
    $Path
}

function Start-ScriptProcess {
    # Starts the PowerShell engine in a new console (ShellExecute), elevated when requested.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WorkingDirectory,
        [switch]$Elevate
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $true          # new console window + runas verb
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($Elevate) { $startInfo.Verb = 'runas' }
    [void][System.Diagnostics.Process]::Start($startInfo)
}
