# Conversion des valeurs saisies, construction de la commande et lancement.

function ConvertTo-PSQuotedString {
    # Littéral entre apostrophes. CodeGeneration double aussi les apostrophes typographiques
    # (’ ‘ ‚ ‛), que PowerShell traite comme des apostrophes droites.
    param([AllowNull()][AllowEmptyString()][string]$Value)

    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Value) + "'"
}

function ConvertTo-InvariantNumber {
    # Lit le nombre dans la culture de l'utilisateur (3,5 en fr-FR), à défaut en culture invariante
    # (3.5), et le réécrit en notation invariante. $null si la saisie n'est pas un nombre valide.
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
    # Lit la date dans la culture de l'utilisateur et la réécrit en ISO 8601 (sans ambiguïté).
    param([string]$Text)

    $value = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if (-not [datetime]::TryParse($Text.Trim(), $culture, $styles, [ref]$value)) { return $null }
    $format = if ($value.TimeOfDay -eq [timespan]::Zero) { 'yyyy-MM-dd' } else { "yyyy-MM-dd'T'HH:mm:ss" }
    $value.ToString($format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-ArgumentValue {
    # Valeur scalaire saisie -> texte d'argument PowerShell, plus un message si elle est invalide.
    param([string]$Text, [string]$ValueKind, [switch]$Integer, [switch]$Decimal)

    if ($ValueKind -eq 'Number') {
        $number = ConvertTo-InvariantNumber -Text $Text -Integer:$Integer
        if ($null -ne $number) {
            # Nombre en littéral. Pour un [decimal], suffixe d : une chaîne ('1234.10') serait
            # convertie en passant par un [double] (15 chiffres significatifs, échelle perdue).
            if ($Decimal) { $number += 'd' }
            return [pscustomobject]@{ Text = $number; Error = $null }
        }
        $expected = if ($Integer) { 'nombre entier attendu' } else { 'nombre attendu' }
        return [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $Text); Error = "« $Text » : $expected" }
    }
    if ($ValueKind -eq 'Date') {
        $date = ConvertTo-InvariantDate -Text $Text
        if ($null -ne $date) { return [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $date); Error = $null } }
        return [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $Text); Error = "« $Text » : date non reconnue" }
    }
    [pscustomobject]@{ Text = (ConvertTo-PSQuotedString $Text); Error = $null }
}

function Test-ParameterValidation {
    # Applique [ValidateRange()] et [ValidatePattern()] à une valeur saisie. Renvoie le message
    # d'erreur, ou $null si la valeur est acceptable (ou si rien n'est vérifiable).
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
                return "« $Text » : hors limites ($expected)"
            }
        }
    }
    if ($validation.ContainsKey('Pattern')) {
        $pattern = $validation['Pattern']
        $isMatch = $true
        try { $isMatch = [regex]::IsMatch($Text, $pattern.Regex, $pattern.Options) }
        catch { Write-Verbose "Motif ValidatePattern invalide, non vérifié : $($pattern.Regex)" }
        if (-not $isMatch) {
            if ($pattern.Message) { return "« $Text » : $($pattern.Message -f $Text, $pattern.Regex)" }
            return "« $Text » : ne correspond pas au motif $($pattern.Regex)"
        }
    }
    $null
}

function ConvertTo-ParameterArgument {
    # Valeur saisie pour un paramètre -> argument de ligne de commande ($null si non renseigné).
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
                # -Message est requis par Windows PowerShell 5.1 dès que -UserName est fourni
                $message = ConvertTo-PSQuotedString "Identifiants pour -$name"
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
    # $null si le paramètre n'appartient pas au jeu ; sinon $true (obligatoire) ou $false.
    param([Parameter(Mandatory)]$Parameter, [string]$ParameterSet)

    $sets = $Parameter.Sets
    if (-not $ParameterSet) { return (@($sets.Values) -contains $true) }
    if ($sets.Contains($ParameterSet)) { return [bool]$sets[$ParameterSet] }
    if ($sets.Contains('__AllParameterSets')) { return [bool]$sets['__AllParameterSets'] }
    $null
}

function New-ScriptCommand {
    # Construit la commande d'appel du script à partir des valeurs saisies.
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
    # Échappe un argument pour la ligne de commande Windows (règles CommandLineToArgvW/MSVCRT :
    # 2n barres obliques inverses + guillemet -> n barres + fin de chaîne ; 2n+1 -> n + guillemet).
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
    # Arguments de powershell.exe / pwsh.exe pour exécuter la commande dans une nouvelle console.
    # Pas de -EncodedCommand : souvent signalé par les EDR, et illisible dans les journaux.
    param(
        [Parameter(Mandatory)][string]$CommandText,
        [string]$Title,
        [string]$WorkingDirectory,
        [switch]$NoExit,
        [switch]$NoProfile
    )

    $statements = [System.Collections.Generic.List[string]]::new()
    if ($Title) { $statements.Add('$Host.UI.RawUI.WindowTitle = ' + (ConvertTo-PSQuotedString $Title)) }
    # -WorkingDirectory est ignoré par un lancement élevé : on se place explicitement
    if ($WorkingDirectory) {
        $statements.Add('Set-Location -LiteralPath ' + (ConvertTo-PSQuotedString $WorkingDirectory))
    }
    # Rappel de la commande dans la console (Write-Host : affichage seul, rien dans le pipeline).
    # Tronqué au-delà d'une certaine taille : la commande figure deux fois dans la ligne de commande.
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
    # Édition imposée par #Requires (Core, Desktop) ou $null.
    param([Parameter(Mandatory)]$ScriptInfo)

    $requirements = $ScriptInfo.Requirements
    $needsCore = $requirements.PSEditions -contains 'Core' -or
        ($requirements.PSVersion -and $requirements.PSVersion.Major -ge 6)
    if ($needsCore) { return 'Core' }
    if ($requirements.PSEditions -contains 'Desktop') { return 'Desktop' }
    $null
}

function Get-PowerShellEngine {
    # Moteurs disponibles : Windows PowerShell 5.1 et PowerShell 7+ (pwsh) s'il est installé.
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
        catch { Write-Verbose "Version de pwsh illisible : $($_.Exception.Message)" }
        $engines.Add([pscustomobject]@{ Name = $label; Path = $pwshPath; Edition = 'Core' })
    }
    $engines.ToArray()
}

function Resolve-NetworkPath {
    # Lecteur réseau mappé -> chemin UNC : une console élevée ne voit pas les lecteurs mappés
    # de la session non élevée (jeton différent).
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
    # Lance le moteur PowerShell dans une nouvelle console (ShellExecute), élevée si demandé.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WorkingDirectory,
        [switch]$Elevate
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $true          # nouvelle fenêtre de console + verbe runas
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    if ($Elevate) { $startInfo.Verb = 'runas' }
    [void][System.Diagnostics.Process]::Start($startInfo)
}
