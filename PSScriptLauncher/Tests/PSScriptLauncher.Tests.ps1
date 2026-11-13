# Pester tests (5.2 or later) for the PSScriptLauncher module: script analysis, command building,
# per-user state. The WPF interface is not covered here.
#
#   Invoke-Pester -Path .\PSScriptLauncher\Tests
#
# Windows PowerShell 5.1 ships with Pester 3: install a recent version first
# (Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck).

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSScriptLauncher.psd1') -Force

    # The expected messages come from the English catalog: the language is forced here so that the
    # assertions do not depend on the Windows UI language.
    InModuleScope PSScriptLauncher { Set-UiLanguage -Language 'en' }

    function New-TestScript {
        # Writes a test script in UTF-8 with BOM and returns its path.
        param([string]$Name, [string]$Content)
        $path = Join-Path $TestDrive $Name
        $folder = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($true))
        $path
    }
}

Describe 'Analyzing a script' {
    BeforeAll {
        $script:AccountScript = New-TestScript -Name (Join-Path 'AD' 'New-Account.ps1') -Content @'
#Requires -Version 5.1

<#
.SYNOPSIS
    Creates an account.
.DESCRIPTION
    Long description.
.PARAMETER Login
    Account login.
.EXAMPLE
    PS C:\> .\New-Account.ps1 -Login jdoe -Level 3 -Groups 'A', 'B' -Force

    Simple creation.
.EXAMPLE
    .\New-Account.ps1 -Csv .\in.csv -Since $date
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [Alias('Sam')]
    [string]$Login,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [Alias('Csv')]
    [string]$CsvPath,

    # Groups to assign
    [string[]]$Groups,

    [ValidateRange(1, 5)]
    [int]$Level,

    [ValidatePattern('^[A-Z]{2}-\d{2}$')]
    [string]$Code,

    [ValidateSet('Standard', 'Admin')]
    [string]$Profile = 'Standard',

    [datetime]$Since,

    [Some.Unknown.Type]$Target,

    [pscredential]$Credential,

    [switch]$Force
)
'@
    }

    It 'reads the synopsis, the description and the requirements without running the script' {
        InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -Be 'Creates an account.'
            $info.Description | Should -Be 'Long description.'
            $info.Warnings.Count | Should -Be 0
            [string]$info.Requirements.PSVersion | Should -Be '5.1'
            $info.SupportsShouldProcess | Should -BeTrue
        }
    }

    It 'determines the input kind of each parameter' {
        InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $kinds = @{}
            foreach ($parameter in (Get-ScriptInfo -LiteralPath $Path).Parameters) { $kinds[$parameter.Name] = $parameter.Kind }
            $kinds['Login'] | Should -Be 'Text'
            $kinds['Groups'] | Should -Be 'TextArray'
            $kinds['Level'] | Should -Be 'Number'
            $kinds['Profile'] | Should -Be 'Choice'
            $kinds['Since'] | Should -Be 'Date'
            $kinds['Target'] | Should -Be 'Text'          # type unknown to the session: free text
            $kinds['Credential'] | Should -Be 'Credential'
            $kinds['Force'] | Should -Be 'Switch'
        }
    }

    It 'reads the parameter sets, the aliases and the descriptions' {
        InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.ParameterSets | Should -Be @('Single', 'Csv')
            $info.DefaultParameterSet | Should -Be 'Single'
            $login = $info.Parameters | Where-Object Name -EQ 'Login'
            $login.Aliases | Should -Be @('Sam')
            $login.Description | Should -Be 'Account login.'
            Get-ParameterSetMembership -Parameter $login -ParameterSet 'Single' | Should -BeTrue
            Get-ParameterSetMembership -Parameter $login -ParameterSet 'Csv' | Should -BeNullOrEmpty
            ($info.Parameters | Where-Object Name -EQ 'Groups').Description | Should -Be 'Groups to assign'
        }
    }

    It 'reads ValidateRange and ValidatePattern' {
        InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $level = $info.Parameters | Where-Object Name -EQ 'Level'
            $level.Validation['Range']['Min'] | Should -Be 1
            $level.Validation['Range']['Max'] | Should -Be 5
            $code = $info.Parameters | Where-Object Name -EQ 'Code'
            $code.Validation['Pattern']['Regex'] | Should -Be '^[A-Z]{2}-\d{2}$'
        }
    }

    It 'parses the examples: prompt removed, aliases resolved, literal values or not' {
        InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $examples = @((Get-ScriptInfo -LiteralPath $Path).Examples)
            $examples.Count | Should -Be 2
            $examples[0].Code | Should -BeLike '.\New-Account.ps1 -Login jdoe*'
            $examples[0].Arguments['Login'].Value | Should -Be 'jdoe'
            $examples[0].Arguments['Level'].Value | Should -Be '3'
            $examples[0].Arguments['Groups'].Value | Should -Be @('A', 'B')
            $examples[0].Arguments['Force'].Value | Should -BeTrue
            $examples[1].Arguments['CsvPath'].Value | Should -Be '.\in.csv'
            $examples[1].Arguments['Since'].IsLiteral | Should -BeFalse
            $examples[1].Arguments['Since'].Text | Should -Be '$date'
        }
    }

    It 'reports help glued to #Requires, which Get-Help does not see' {
        $path = New-TestScript -Name 'Glued.ps1' -Content "#Requires -Version 5.1`n<#`n.SYNOPSIS`n    Glued help.`n#>`nparam([string]`$Name)`n"
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -Be 'Glued help.'
            ($info.Warnings -join ' ') | Should -Match 'a blank line is missing'
        }
    }

    It 'reports nothing for a function library' {
        $path = New-TestScript -Name 'Lib.ps1' -Content "<#`n.SYNOPSIS`n    Help of Get-Thing.`n#>`nfunction Get-Thing { }`n`nfunction Get-Other { }`n"
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -BeNullOrEmpty
            $info.Warnings.Count | Should -Be 0
        }
    }

    It 'reports a syntax error or an unreadable file without throwing' {
        $path = New-TestScript -Name 'Broken.ps1' -Content "param([string]`$Name)`nif (`$Name {`n"
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path; Missing = (Join-Path $TestDrive 'absent.ps1') } {
            param($Path, $Missing)
            ((Get-ScriptInfo -LiteralPath $Path).Warnings -join ' ') | Should -Match 'Syntax error'
            ((Get-ScriptInfo -LiteralPath $Missing).Warnings -join ' ') | Should -Match 'Cannot read'
        }
    }

    It 'decodes a script in the ANSI code page (no BOM)' {
        $path = Join-Path $TestDrive 'Ansi.ps1'
        $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        if ($ansi.CodePage -eq 65001) { Set-ItResult -Skipped -Because 'the ANSI code page of the system is UTF-8' }
        [System.IO.File]::WriteAllBytes($path, $ansi.GetBytes("<#`n.SYNOPSIS`n    Café report.`n#>`nparam()`n"))
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            (Get-ScriptInfo -LiteralPath $Path).Synopsis | Should -Be 'Café report.'
        }
    }

    It 'formats the help with the English section titles' {
        $text = InModuleScope PSScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            Format-ScriptHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $Path)
        }
        $text | Should -Match '(?m)^NAME\r?$'
        $text | Should -Match '(?m)^SYNOPSIS\r?$'
        $text | Should -Match '(?m)^SYNTAX\r?$'
        $text | Should -Match '(?m)^PARAMETERS\r?$'
        $text | Should -Match '(?m)^EXAMPLES\r?$'
        $text | Should -Match '(?m)^REQUIREMENTS \(#Requires\)\r?$'
        $text | Should -Match '--- Example 1 ---'
        $text | Should -Not -Match '(?m)^(NOM|SYNTAXE|PARAMÈTRES|EXEMPLES)\r?$'
    }
}

Describe 'Folder inventory' {
    BeforeAll {
        $script:CatalogRoot = Join-Path $TestDrive 'catalog'
        $names = @(
            (Join-Path 'B' 'Two.ps1'), (Join-Path 'A' 'One.ps1'), (Join-Path 'A' 'One.Tests.ps1'), 'Root.ps1',
            (Join-Path (Join-Path 'PSScriptLauncher' 'Private') 'Inner.ps1')
        )
        foreach ($name in $names) {
            $null = New-TestScript -Name (Join-Path 'catalog' $name) -Content "<#`n.SYNOPSIS`n    $name`n#>`nparam()`n"
        }
    }

    It 'lists the scripts sorted, without the excluded patterns and folders, and fills in the progress' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:CatalogRoot } {
            param($Root)
            $progress = [hashtable]::Synchronized(@{ Total = 0; Done = 0 })
            $catalog = Get-ScriptCatalog -Root $Root -ExcludePattern '*.Tests.ps1' -Summary -Progress $progress `
                -ExcludeDirectory (Join-Path $Root 'PSScriptLauncher')
            $catalog.Scripts.Name | Should -Be @('One.ps1', 'Two.ps1', 'Root.ps1')
            $progress['Total'] | Should -Be 3
            $progress['Done'] | Should -Be 3
            $catalog.Scripts[0].Synopsis | Should -Match 'One\.ps1'
        }
    }

    It 'rejects a path that is not a folder' {
        InModuleScope PSScriptLauncher -Parameters @{ File = (Join-Path $script:CatalogRoot 'Root.ps1') } {
            param($File)
            { Get-ScriptCatalog -Root $File } | Should -Throw
        }
    }

    It 'filters without regard to case or accents, all terms being required' {
        InModuleScope PSScriptLauncher {
            $entry = [pscustomobject]@{ RelativePath = 'AD\Get-Report.ps1'; Synopsis = 'Résumé of the accounts' }
            Test-ScriptFilter -ScriptInfo $entry -Filter 'RESUME accounts' | Should -BeTrue
            Test-ScriptFilter -ScriptInfo $entry -Filter 'report licence' | Should -BeFalse
        }
    }
}

Describe 'Command building' {
    BeforeAll {
        $script:PreviousCulture = [System.Globalization.CultureInfo]::CurrentCulture
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    }
    AfterAll {
        [System.Globalization.CultureInfo]::CurrentCulture = $script:PreviousCulture
    }

    It 'rewrites dates and numbers typed in French in the invariant format' {
        InModuleScope PSScriptLauncher {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            ConvertTo-InvariantDate -Text '09/11/2026' | Should -Be '2026-11-09'
            ConvertTo-InvariantDate -Text '09/11/2026 14:30' | Should -Be '2026-11-09T14:30:00'
            ConvertTo-InvariantNumber -Text '3,5' | Should -Be '3.5'
            ConvertTo-InvariantNumber -Text '3.5' | Should -Be '3.5'
            ConvertTo-InvariantNumber -Text '2,5' -Integer | Should -BeNullOrEmpty
            ConvertTo-InvariantNumber -Text 'abc' | Should -BeNullOrEmpty
        }
    }

    It 'doubles straight and typographic apostrophes' {
        InModuleScope PSScriptLauncher {
            ConvertTo-PSQuotedString -Value "O'Brien" | Should -Be "'O''Brien'"
            $curly = [string][char]0x2019
            ConvertTo-PSQuotedString -Value "don$($curly)t" | Should -Be "'don$($curly)$($curly)t'"
        }
    }

    It 'produces an executable command that passes the values through unchanged' {
        $echo = New-TestScript -Name 'Echo.ps1' -Content @'
param([string]$Text, [string[]]$List, [int]$Count, [decimal]$Amount, [datetime]$When, [switch]$Force)
'{0}|{1}|{2}|{3}|{4}|{5}' -f $Text, ($List -join '+'), $Count, $Amount.ToString([cultureinfo]::InvariantCulture),
    $When.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture), $Force.IsPresent
'@
        $command = InModuleScope PSScriptLauncher -Parameters @{ Path = $echo } {
            param($Path)
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $info = Get-ScriptInfo -LiteralPath $Path
            $values = @{
                Text   = 'O''Brien "x" $env:TEMP ; `n'
                List   = [string[]]@('a b', "c'd")
                Count  = '-5'
                Amount = '1234,10'
                When   = '09/11/2026'
                Force  = $true
            }
            $result = New-ScriptCommand -ScriptInfo $info -Values $values
            $result.Errors.Count | Should -Be 0
            $result.CommandText
        }
        $output = & ([scriptblock]::Create($command))
        $output | Should -Be 'O''Brien "x" $env:TEMP ; `n|a b+c''d|-5|1234.10|2026-11-09|True'
    }

    It 'reports the missing mandatory values and the values outside ValidateRange / ValidatePattern' {
        $path = New-TestScript -Name 'Valid.ps1' -Content @'
param(
    [Parameter(Mandatory)][string]$Name,
    [ValidateRange(1, 5)][int]$Level,
    [ValidatePattern('^[A-Z]{2}-\d{2}$')][string]$Code,
    [ValidateRange(0.5, 2)][double[]]$Ratios
)
'@
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $info = Get-ScriptInfo -LiteralPath $Path
            $bad = New-ScriptCommand -ScriptInfo $info -Values @{ Level = '7'; Code = 'ab-1'; Ratios = [string[]]@('0,5', '3') }
            $bad.Missing | Should -Be @('Name')
            ($bad.Errors.Keys | Sort-Object) | Should -Be @('Code', 'Level', 'Ratios')
            ($bad.Errors['Level'] -join '') | Should -Match 'out of range \(range: 1 to 5\)'
            ($bad.Errors['Ratios'] -join '') | Should -Match '"3": out of range'
            $good = New-ScriptCommand -ScriptInfo $info -Values @{ Name = 'x'; Level = '5'; Code = 'ab-12'; Ratios = [string[]]@('0,5', '2') }
            $good.Missing.Count | Should -Be 0
            $good.Errors.Count | Should -Be 0
        }
    }

    It 'never puts a secret in the command: Get-Credential and Read-Host are called at launch' {
        $path = New-TestScript -Name 'Secret.ps1' -Content 'param([pscredential]$Credential, [securestring]$Password)'
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $values = @{ Credential = [pscustomobject]@{ Prompt = $true; UserName = 'DOM\adm' }; Password = $true }
            $text = (New-ScriptCommand -ScriptInfo $info -Values $values).CommandText
            $text | Should -Match ([regex]::Escape("-Credential (Get-Credential -UserName 'DOM\adm' -Message 'Credentials for -Credential')"))
            $text | Should -Match ([regex]::Escape("-Password (Read-Host -AsSecureString -Prompt 'Password')"))
        }
    }

    It 'escapes the arguments for the Windows command line' {
        InModuleScope PSScriptLauncher {
            ConvertTo-ProcessArgument -Value 'simple' | Should -Be 'simple'
            ConvertTo-ProcessArgument -Value 'a b' | Should -Be '"a b"'
            ConvertTo-ProcessArgument -Value 'a"b' | Should -Be '"a\"b"'
            ConvertTo-ProcessArgument -Value 'C:\Test folder\' | Should -Be '"C:\Test folder\\"'
            ConvertTo-ProcessArgument -Value '' | Should -Be '""'
        }
    }
}

Describe 'Per-user state' {
    It 'places the state in the profile, under the launcher name' {
        InModuleScope PSScriptLauncher {
            Get-DefaultStatePath | Should -BeLike '*\PSScriptLauncher\state.json'
        }
    }

    It 'saves and reloads favorites, recents and inputs, arrays included' {
        $statePath = Join-Path (Join-Path $TestDrive 'state') 'state.json'
        InModuleScope PSScriptLauncher -Parameters @{ StatePath = $statePath } {
            param($StatePath)
            $state = Read-UserState -Path $StatePath
            $state.Favorites.Count | Should -Be 0
            Switch-FavoriteScript -State $state -ScriptPath 'C:\S\A.ps1' | Should -BeTrue
            Set-RememberedInput -State $state -ScriptPath 'C:\S\A.ps1' -ParameterSet 'Csv' -Values @{
                Name   = 'x'
                Groups = @('only')
                Force  = $true
                Cred   = @{ Prompt = $true; UserName = 'DOM\adm' }
            }
            Save-UserState -Path $StatePath -State $state

            $json = [System.IO.File]::ReadAllText($StatePath)
            $json | Should -Not -Match '"value"\s*:'          # array wrapped in a PSObject (ConvertTo-Json trap in 5.1)

            $reloaded = Read-UserState -Path $StatePath
            Test-FavoriteScript -State $reloaded -ScriptPath 'c:\s\a.PS1' | Should -BeTrue
            $reloaded.Recents | Should -Be @('C:\S\A.ps1')
            $remembered = Get-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1'
            $remembered.ParameterSet | Should -Be 'Csv'
            $remembered.Values['Name'] | Should -Be 'x'
            @($remembered.Values['Groups']) | Should -Be @('only')
            $remembered.Values['Force'] | Should -BeTrue
            $remembered.Values['Cred']['UserName'] | Should -Be 'DOM\adm'

            Switch-FavoriteScript -State $reloaded -ScriptPath 'C:\S\A.ps1' | Should -BeFalse
            Remove-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1'
            Get-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1' | Should -BeNullOrEmpty
        }
    }

    It 'limits the recents and puts the last launched one first, without duplicates' {
        InModuleScope PSScriptLauncher {
            $state = New-UserState
            1..12 | ForEach-Object { Set-RememberedInput -State $state -ScriptPath "C:\S\$_.ps1" }
            Set-RememberedInput -State $state -ScriptPath 'C:\S\10.PS1'
            $state.Recents.Count | Should -Be $script:Settings.MaxRecent
            $state.Recents[0] | Should -Be 'C:\S\10.PS1'
            @($state.Recents | Where-Object { $_ -like '*\10.ps1' }).Count | Should -Be 1
        }
    }

    It 'does not keep a clear-text value whose name suggests a secret' {
        InModuleScope PSScriptLauncher {
            $secret = [pscustomobject]@{ Name = 'ApiToken'; Kind = 'Text' }
            $plain = [pscustomobject]@{ Name = 'Name'; Kind = 'Text' }
            $credential = [pscustomobject]@{ Name = 'Credential'; Kind = 'Credential' }
            ConvertTo-StoredValue -Parameter $secret -Value 'abc' | Should -BeNullOrEmpty
            ConvertTo-StoredValue -Parameter $plain -Value 'abc' | Should -Be 'abc'
            $stored = ConvertTo-StoredValue -Parameter $credential -Value ([pscustomobject]@{ Prompt = $true; UserName = 'u' })
            $stored['Prompt'] | Should -BeTrue
            foreach ($name in 'Password', 'ClientSecret', 'AccessKey', 'Pwd', 'SasToken') {
                Test-SensitiveParameterName -Name $name | Should -BeTrue -Because $name
            }
            foreach ($name in 'Path', 'Name', 'KeyVaultName', 'Monkey') {
                Test-SensitiveParameterName -Name $name | Should -BeFalse -Because $name
            }
        }
    }

    It 'starts again from an empty state when the file is corrupted' {
        $statePath = Join-Path $TestDrive 'corrupted.json'
        Set-Content -LiteralPath $statePath -Value '{ not JSON'
        InModuleScope PSScriptLauncher -Parameters @{ StatePath = $statePath } {
            param($StatePath)
            $state = Read-UserState -Path $StatePath
            $state.Favorites.Count | Should -Be 0
            $state.Scripts.Count | Should -Be 0
        }
    }
}

Describe 'Interface language' {
    AfterAll {
        # The other blocks expect English: put the catalog back whatever this block did.
        InModuleScope PSScriptLauncher { Set-UiLanguage -Language 'en' }
    }

    It 'exposes exactly the same set of keys in the en and fr catalogs' {
        InModuleScope PSScriptLauncher {
            @(Get-AvailableLanguage) | Should -Be @('en', 'fr')

            $english = Import-UiText -Language 'en'
            $french = Import-UiText -Language 'fr'
            $english.Count | Should -BeGreaterThan 0
            $english.Count | Should -Be $french.Count

            $onlyEnglish = @($english.Keys | Where-Object { -not $french.ContainsKey($_) } | Sort-Object)
            $onlyFrench = @($french.Keys | Where-Object { -not $english.ContainsKey($_) } | Sort-Object)
            ('missing from fr: ' + ($onlyEnglish -join ', ')) | Should -Be 'missing from fr: '
            ('missing from en: ' + ($onlyFrench -join ', ')) | Should -Be 'missing from en: '
        }
    }

    It 'references only keys that exist in both catalogs' {
        InModuleScope PSScriptLauncher {
            $english = Import-UiText -Language 'en'
            $french = Import-UiText -Language 'fr'

            # Every Get-UiText '...' of the module, the Tests folder excluded.
            $files = @(Get-ChildItem -LiteralPath $script:ModuleRoot -Recurse -File | Where-Object {
                    $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '[\\/]Tests[\\/]'
                })
            $files.Count | Should -BeGreaterThan 0
            $keys = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $files) {
                $code = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($match in [regex]::Matches($code, "Get-UiText\s+'([^']+)'")) {
                    $keys.Add($match.Groups[1].Value)
                }
            }
            $keys.Count | Should -BeGreaterThan 0

            $missing = foreach ($key in @($keys | Sort-Object -Unique)) {
                if (-not $english.ContainsKey($key) -or -not $french.ContainsKey($key)) { $key }
            }
            ('missing keys: ' + (@($missing) -join ', ')) | Should -Be 'missing keys: '
        }
    }

    It 'resolves the language: explicit choice, then the saved preference, then Windows, then en' {
        InModuleScope PSScriptLauncher {
            # An explicit choice wins over the saved preference.
            Resolve-UiLanguage -Language 'fr' -State @{ Language = 'en' } | Should -Be 'fr'
            Resolve-UiLanguage -Language 'en' -State @{ Language = 'fr' } | Should -Be 'en'
            # The preference saved in the user state comes next, whatever the Windows culture is.
            Resolve-UiLanguage -State @{ Language = 'fr' } | Should -Be 'fr'
            Resolve-UiLanguage -State @{ Language = 'en' } | Should -Be 'en'

            $previous = [System.Globalization.CultureInfo]::CurrentUICulture
            try {
                # Without a preference, the Windows UI language is used when it is shipped...
                [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
                Resolve-UiLanguage -State @{ Language = '' } | Should -Be 'fr'
                # ...and an unsupported Windows UI language falls back to English.
                [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                Resolve-UiLanguage -State @{ Language = '' } | Should -Be 'en'
                Resolve-UiLanguage | Should -Be 'en'
            }
            finally {
                [System.Globalization.CultureInfo]::CurrentUICulture = $previous
            }
        }
    }

    It 'rejects an explicit language that does not exist' {
        InModuleScope PSScriptLauncher {
            { Resolve-UiLanguage -Language 'zz' } | Should -Throw -ExpectedMessage '*Unknown language*'
        }
    }

    It 'formats the arguments in the language of the catalog' {
        InModuleScope PSScriptLauncher {
            try {
                Set-UiLanguage -Language 'en'
                $english = Get-UiText 'window.status.catalog' -Arguments @(3, 0.5)
                Set-UiLanguage -Language 'fr'
                $french = Get-UiText 'window.status.catalog' -Arguments @(3, 0.5)
            }
            finally {
                Set-UiLanguage -Language 'en'
            }
            $english | Should -Be '3 script(s) · 0.5 s'
            $french | Should -Be '3 script(s) · 0,5 s'
            $english | Should -Not -Be $french
        }
    }
}
