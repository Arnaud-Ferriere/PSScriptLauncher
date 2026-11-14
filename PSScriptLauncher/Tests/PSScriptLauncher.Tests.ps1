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
            $catalog = Get-ScriptCatalog -Root $Root -ExcludePattern '*.Tests.ps1' -Progress $progress `
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
            $notAFolder = $File
            { Get-ScriptCatalog -Root $notAFolder } | Should -Throw
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

Describe 'Recent folders' {
    It 'remembers the folders, without duplicates and with a limit' {
        InModuleScope PSScriptLauncher {
            $state = New-UserState
            Add-RecentRoot -State $state -Path 'D:\Scripts' | Out-Null
            Add-RecentRoot -State $state -Path 'E:\Admin' | Out-Null
            # Same folder, other case and trailing separator: no duplicate, moved to the head
            Add-RecentRoot -State $state -Path 'd:\scripts\' | Out-Null
            @($state.RecentRoots).Count | Should -Be 2
            @($state.RecentRoots)[0] | Should -Be 'd:\scripts'
            foreach ($i in 1..10) { Add-RecentRoot -State $state -Path ("X:\D$i") | Out-Null }
            @($state.RecentRoots).Count | Should -Be $script:Settings.MaxRecentRoots
        }
    }

    It 'opens the last folder that still exists, else the launcher folder' {
        $statePath = Join-Path (Join-Path $TestDrive 'roots') 'state.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force
        InModuleScope PSScriptLauncher -Parameters @{ StatePath = $statePath; Temp = $TestDrive } {
            param($StatePath, $Temp)
            $state = New-UserState
            Add-RecentRoot -State $state -Path $Temp | Out-Null
            Add-RecentRoot -State $state -Path (Join-Path $Temp 'gone') | Out-Null
            Save-UserState -Path $StatePath -State $state
            # The most recent folder is missing: the next one that exists is used
            Get-DefaultRoot -StatePath $StatePath | Should -Be $Temp

            $gone = New-UserState
            Add-RecentRoot -State $gone -Path (Join-Path $Temp 'gone-too') | Out-Null
            Save-UserState -Path $StatePath -State $gone
            Get-DefaultRoot -StatePath $StatePath | Should -Be (Split-Path -Parent $script:ModuleRoot)
        }
    }
}

Describe 'Missing help' {
    BeforeAll {
        $nl = [Environment]::NewLine
        $enc = [System.Text.UTF8Encoding]::new($true)
        $script:helpFolder = Join-Path $TestDrive 'help-scripts'
        $null = New-Item -ItemType Directory -Path $script:helpFolder -Force

        function New-HelpScript {
            param([string]$Name, [string]$Body)
            $path = Join-Path $script:helpFolder $Name
            [System.IO.File]::WriteAllText($path, $Body, $enc)
            $path
        }

        # Nothing at all
        $script:helpNone = New-HelpScript -Name 'Get-None.ps1' -Body ('param([string]$Name)' + $nl + '"n"')
        # A description but no synopsis
        $script:helpDescription = New-HelpScript -Name 'Get-Description.ps1' -Body ('<#' + $nl + '.DESCRIPTION' + $nl + '    Only a description.' + $nl + '#>' + $nl + 'param([string]$Name)' + $nl + '"d"')
        # A synopsis but nothing else
        $script:helpSynopsis = New-HelpScript -Name 'Get-Synopsis.ps1' -Body ('<#' + $nl + '.SYNOPSIS' + $nl + '    Only a synopsis.' + $nl + '#>' + $nl + 'param([string]$Name)' + $nl + '"s"')
        # Complete help
        $script:helpFull = New-HelpScript -Name 'Get-Complete.ps1' -Body ('<#' + $nl + '.SYNOPSIS' + $nl + '    Complete.' + $nl + '.DESCRIPTION' + $nl + '    With a description.' + $nl + '.PARAMETER Name' + $nl + '    Documented.' + $nl + '.EXAMPLE' + $nl + '    .\Get-Complete.ps1 -Name x' + $nl + '#>' + $nl + 'param([string]$Name)' + $nl + '"c"')
        # Good help, but one parameter is not documented
        $script:helpMute = New-HelpScript -Name 'Get-Mute.ps1' -Body ('<#' + $nl + '.SYNOPSIS' + $nl + '    Mute.' + $nl + '.DESCRIPTION' + $nl + '    With a description.' + $nl + '.PARAMETER Name' + $nl + '    Documented.' + $nl + '.EXAMPLE' + $nl + '    .\Get-Mute.ps1 -Name x' + $nl + '#>' + $nl + 'param([string]$Name, [string]$Other)' + $nl + '"m"')
    }

    It 'lists what the help is missing, in a stable order' {
        InModuleScope PSScriptLauncher -Parameters @{
            None = $script:helpNone; Synopsis = $script:helpSynopsis
            Full = $script:helpFull; Mute = $script:helpMute
        } {
            param($None, $Synopsis, $Full, $Mute)
            @(Get-HelpGap -ScriptInfo (Get-ScriptInfo -LiteralPath $None -RelativePath 'a.ps1')) |
                Should -Be @('synopsis', 'description', 'example', 'parameters')
            @(Get-HelpGap -ScriptInfo (Get-ScriptInfo -LiteralPath $Synopsis -RelativePath 'b.ps1')) |
                Should -Be @('description', 'example', 'parameters')
            @(Get-HelpGap -ScriptInfo (Get-ScriptInfo -LiteralPath $Full -RelativePath 'c.ps1')).Count | Should -Be 0
            @(Get-HelpGap -ScriptInfo (Get-ScriptInfo -LiteralPath $Mute -RelativePath 'd.ps1')) | Should -Be @('parameters')
        }
    }

    It 'names the parameters that are not documented' {
        InModuleScope PSScriptLauncher -Parameters @{ Mute = $script:helpMute } {
            param($Mute)
            $info = Get-ScriptInfo -LiteralPath $Mute -RelativePath 'Get-Mute.ps1'
            @($info.UndocumentedParameters) | Should -Be @('Other')
            $info.UndocumentedCount | Should -Be 1
        }
    }

    It 'flags the help that lacks content, not the parameters' {
        InModuleScope PSScriptLauncher -Parameters @{
            None = $script:helpNone; Description = $script:helpDescription
            Synopsis = $script:helpSynopsis; Full = $script:helpFull; Mute = $script:helpMute
        } {
            param($None, $Description, $Synopsis, $Full, $Mute)
            Test-IncompleteHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $None -RelativePath 'a.ps1') | Should -BeTrue
            Test-IncompleteHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $Description -RelativePath 'b.ps1') | Should -BeTrue
            Test-IncompleteHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $Synopsis -RelativePath 'c.ps1') | Should -BeTrue
            Test-IncompleteHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $Full -RelativePath 'd.ps1') | Should -BeFalse
            # A missing parameter description has its own filter
            Test-IncompleteHelp -ScriptInfo (Get-ScriptInfo -LiteralPath $Mute -RelativePath 'e.ps1') | Should -BeFalse
        }
    }

    It 'filters on one kind of gap' {
        InModuleScope PSScriptLauncher -Parameters @{
            Synopsis = $script:helpSynopsis; Full = $script:helpFull; Mute = $script:helpMute
        } {
            param($Synopsis, $Full, $Mute)
            $syn = Get-ScriptInfo -LiteralPath $Synopsis -RelativePath 'a.ps1'
            $ok = Get-ScriptInfo -LiteralPath $Full -RelativePath 'b.ps1'
            $mute = Get-ScriptInfo -LiteralPath $Mute -RelativePath 'c.ps1'
            Test-ScriptHelpFilter -ScriptInfo $syn -Filter 'synopsis' | Should -BeFalse
            Test-ScriptHelpFilter -ScriptInfo $syn -Filter 'description' | Should -BeTrue
            Test-ScriptHelpFilter -ScriptInfo $syn -Filter 'example' | Should -BeTrue
            Test-ScriptHelpFilter -ScriptInfo $mute -Filter 'parameters' | Should -BeTrue
            Test-ScriptHelpFilter -ScriptInfo $ok -Filter 'parameters' | Should -BeFalse
            Test-ScriptHelpFilter -ScriptInfo $ok -Filter 'all' | Should -BeTrue
            Test-ScriptHelpFilter -ScriptInfo $ok -Filter 'incomplete' | Should -BeFalse
            Test-ScriptHelpFilter -ScriptInfo $syn -Filter 'incomplete' | Should -BeTrue
        }
    }

    It 'keeps the gaps through the catalog cache' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:helpFolder } {
            param($Root)
            $cache = New-CatalogCache -Root $Root
            $first = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            @($first.Scripts | Where-Object { Test-IncompleteHelp -ScriptInfo $_ }).Count | Should -Be 3
            $second = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            @($second.Scripts | Where-Object { $_.FromCache }).Count | Should -Be 5
            @($second.Scripts | Where-Object { Test-IncompleteHelp -ScriptInfo $_ }).Count | Should -Be 3
            $mute = @($second.Scripts | Where-Object { $_.BaseName -eq 'Get-Mute' })[0]
            $mute.UndocumentedCount | Should -Be 1
            @(Get-HelpGap -ScriptInfo $mute) | Should -Be @('parameters')
            $full = @($second.Scripts | Where-Object { $_.BaseName -eq 'Get-Complete' })[0]
            @(Get-HelpGap -ScriptInfo $full).Count | Should -Be 0
        }
    }
}

Describe 'Catalog cache' {
    BeforeAll {
        $nl = [Environment]::NewLine
        $enc = [System.Text.UTF8Encoding]::new($true)

        function New-CacheFixture {
            # A folder with the given scripts, each one being a tiny valid script with a synopsis.
            param([string]$Name, [hashtable]$Scripts)
            $folder = Join-Path $TestDrive $Name
            $null = New-Item -ItemType Directory -Path $folder -Force
            foreach ($key in $Scripts.Keys) {
                [System.IO.File]::WriteAllText((Join-Path $folder $key), $Scripts[$key], $enc)
            }
            $folder
        }

        $script:cacheOne = New-CacheFixture -Name 'cache-one' -Scripts @{
            'Get-Cached.ps1' = '#Requires -Version 5.1' + $nl + $nl + '<#' + $nl + '.SYNOPSIS' + $nl + '    Cached script.' + $nl + '#>' + $nl + 'param([string]$Name)' + $nl + '"x"'
        }
        $script:cacheTwo = New-CacheFixture -Name 'cache-two' -Scripts @{
            'Get-A.ps1' = '#Requires -Version 5.1' + $nl + $nl + '<#' + $nl + '.SYNOPSIS' + $nl + '    Script A.' + $nl + '#>' + $nl + '"a"'
            'Get-B.ps1' = '#Requires -Version 5.1' + $nl + $nl + '<#' + $nl + '.SYNOPSIS' + $nl + '    Script B.' + $nl + '#>' + $nl + '"b"'
        }
        # No blank line between #Requires and the help block: the analysis reports a warning
        $script:cacheGlued = New-CacheFixture -Name 'cache-glued' -Scripts @{
            'Get-Glued.ps1' = '#Requires -Version 5.1' + $nl + '<#' + $nl + '.SYNOPSIS' + $nl + '    Glued help.' + $nl + '#>' + $nl + '"g"'
        }
        $script:cacheFile = Join-Path $TestDrive 'cache.json'
    }

    It 'stores one entry per script, with its size, its date and its synopsis' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:cacheOne; CacheFile = $script:cacheFile } {
            param($Root, $CacheFile)
            $cache = New-CatalogCache -Root $Root
            $catalog = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            $cache.Entries.Count | Should -Be 1
            $entry = @($cache.Entries.Values)[0]
            $entry.RelativePath | Should -Be 'Get-Cached.ps1'
            $entry.Size | Should -BeGreaterThan 0
            $entry.Mtime | Should -BeGreaterThan 0
            $entry.Synopsis | Should -Be 'Cached script.'
            @($catalog.Scripts)[0].FromCache | Should -Not -BeTrue
            $catalog.Cache | Should -Not -BeNullOrEmpty

            Save-CatalogCache -Path $CacheFile -Cache $cache
            Test-Path -LiteralPath $CacheFile | Should -BeTrue
            (Read-CatalogCache -Path $CacheFile -Root $Root).Entries.Count | Should -Be 1
        }
    }

    It 'reuses an unchanged file instead of parsing it again' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:cacheOne } {
            param($Root)
            $cache = New-CatalogCache -Root $Root
            $null = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            $second = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            @($second.Scripts)[0].FromCache | Should -BeTrue
            @($second.Scripts)[0].Synopsis | Should -Be 'Cached script.'
        }
    }

    It 'analyses again a file whose size or date changed, and only that one' {
        $target = Join-Path $script:cacheTwo 'Get-A.ps1'
        $script:cacheTwoPath = $script:cacheTwo
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:cacheTwoPath; Target = $target } {
            param($Root, $Target)
            $cache = New-CatalogCache -Root $Root
            $null = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            [System.IO.File]::AppendAllText($Target, [Environment]::NewLine + 'Write-Output 1')
            (Get-Item -LiteralPath $Target).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(10)
            $after = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            @($after.Scripts | Where-Object { $_.BaseName -eq 'Get-A' })[0].FromCache | Should -Not -BeTrue
            @($after.Scripts | Where-Object { $_.BaseName -eq 'Get-B' })[0].FromCache | Should -BeTrue
        }
    }

    It 'forgets the entry of a file that disappeared' {
        $folder = Join-Path $TestDrive 'cache-deleted'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [System.IO.File]::WriteAllText((Join-Path $folder 'Get-Keep.ps1'), '"keep"', [System.Text.UTF8Encoding]::new($true))
        [System.IO.File]::WriteAllText((Join-Path $folder 'Get-Gone.ps1'), '"gone"', [System.Text.UTF8Encoding]::new($true))
        InModuleScope PSScriptLauncher -Parameters @{ Root = $folder } {
            param($Root)
            $cache = New-CatalogCache -Root $Root
            $null = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            $cache.Entries.Count | Should -Be 2
            Remove-Item -LiteralPath (Join-Path $Root 'Get-Gone.ps1') -Force
            $null = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            $cache.Entries.Count | Should -Be 1
            @($cache.Entries.Values)[0].RelativePath | Should -Be 'Get-Keep.ps1'
        }
    }

    It 'keeps the number of warnings, never their text' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:cacheGlued } {
            param($Root)
            $cache = New-CatalogCache -Root $Root
            # First pass: the file is analysed, so its warnings carry their text
            $first = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            @($cache.Entries.Values)[0].Warnings | Should -Be 1
            @(@($first.Scripts)[0].Warnings).Count | Should -BeGreaterThan 0
            # Second pass: the entry comes from the cache and only keeps the count
            $second = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            $cached = @($second.Scripts)[0]
            $cached.FromCache | Should -BeTrue
            @($cached.Warnings).Count | Should -Be 0
            Get-ScriptWarningCount -ScriptInfo $cached | Should -Be 1
        }
    }

    It 'ignores a corrupted, outdated or foreign cache file' {
        InModuleScope PSScriptLauncher -Parameters @{ Root = $script:cacheTwo; CacheFile = $script:cacheFile } {
            param($Root, $CacheFile)
            Set-Content -LiteralPath $CacheFile -Value '{ not JSON' -Encoding UTF8
            (Read-CatalogCache -Path $CacheFile -Root $Root).Entries.Count | Should -Be 0

            $cache = New-CatalogCache -Root $Root
            $null = Get-ScriptCatalog -Root $Root -ExcludePattern @() -Cache $cache
            Save-CatalogCache -Path $CacheFile -Cache $cache
            (Read-CatalogCache -Path $CacheFile -Root $Root).Entries.Count | Should -Be 2
            # Same file, another folder: nothing is reused
            (Read-CatalogCache -Path $CacheFile -Root (Split-Path -Parent $Root)).Entries.Count | Should -Be 0
            # Another cache version: the file is ignored
            $saved = $script:Settings.CacheVersion
            try {
                $script:Settings.CacheVersion = $saved + 1
                (Read-CatalogCache -Path $CacheFile -Root $Root).Entries.Count | Should -Be 0
            }
            finally { $script:Settings.CacheVersion = $saved }
        }
    }

    It 'gives one cache file per folder, and the same one for the same folder' {
        InModuleScope PSScriptLauncher -Parameters @{ RootA = $script:cacheOne; RootB = $script:cacheTwo; StatePath = (Join-Path $TestDrive 'state.json') } {
            param($RootA, $RootB, $StatePath)
            $pathA = Get-CatalogCachePath -Root $RootA -StatePath $StatePath
            $pathB = Get-CatalogCachePath -Root $RootB -StatePath $StatePath
            $pathA | Should -Not -Be $pathB
            Get-CatalogCachePath -Root $RootA -StatePath $StatePath | Should -Be $pathA
            Get-CatalogCachePath -Root ($RootA + '\') -StatePath $StatePath | Should -Be $pathA
            $pathA | Should -BeLike '*\cache\*.json'
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

Describe 'Keyboard shortcuts' {
    It 'lists every shortcut, in both languages' {
        InModuleScope PSScriptLauncher -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
            foreach ($language in 'en', 'fr') {
                Initialize-UiText -Language $language -StatePath (Join-Path $Drive "shortcuts-$language.json")
                $window = New-ShortcutsWindow
                try {
                    $window.Title | Should -Not -BeNullOrEmpty
                    $list = $window.FindName('ShortcutsList')
                    [System.Windows.Automation.AutomationProperties]::GetName($list) | Should -Not -BeNullOrEmpty
                    @($list.Items).Count | Should -Be 8
                    foreach ($item in $list.Items) {
                        $item.Keys | Should -Not -BeNullOrEmpty
                        $item.Text | Should -Not -BeNullOrEmpty
                        $item.AutomationName | Should -Be ($item.Keys + ' : ' + $item.Text)
                    }
                }
                finally { $window.Close() }
            }
        }
    }
}

Describe 'Help search' {
    BeforeAll {
        $script:SearchScript = New-TestScript -Name 'Search.ps1' -Content @'
<#
.SYNOPSIS
    Does a very specific thing.
.DESCRIPTION
    Reads the mailbox of the user.
.PARAMETER Quota
    Mailbox size, in gigabytes.
.EXAMPLE
    PS C:\> .\Search.ps1 -Quota 10
.NOTES
    Reserved for the platform team.
#>
param(
    [int]$Quota = 5
)
'@
        $script:SearchInfo = InModuleScope PSScriptLauncher -Parameters @{ Path = $script:SearchScript } {
            param($Path)
            Get-ScriptInfo -LiteralPath $Path -RelativePath 'Search.ps1'
        }
    }

    It 'finds terms in the parameters, the examples and the raw help block' {
        InModuleScope PSScriptLauncher -Parameters @{ Info = $script:SearchInfo } {
            param($Info)
            (Test-ScriptFilter -ScriptInfo $Info -Filter 'gigabytes') | Should -BeTrue
            (Test-ScriptFilter -ScriptInfo $Info -Filter 'Quota') | Should -BeTrue
            (Test-ScriptFilter -ScriptInfo $Info -Filter 'platform') | Should -BeTrue
            (Test-ScriptFilter -ScriptInfo $Info -Filter 'nothing-matches-this') | Should -BeFalse
        }
    }

    It 'says where the match comes from, and stays silent for the name' {
        InModuleScope PSScriptLauncher -Parameters @{ Info = $script:SearchInfo } {
            param($Info)
            (Get-ScriptMatchReason -ScriptInfo $Info -Filter 'gigabytes') |
                Should -Be (Get-UiText 'search.match.parameter' -Arguments @('Quota'))
            (Get-ScriptMatchReason -ScriptInfo $Info -Filter 'platform') |
                Should -Be (Get-UiText 'search.match.help')
            (Get-ScriptMatchReason -ScriptInfo $Info -Filter 'specific') | Should -Be ''
        }
    }

    It 'sorts each result into the group of the field that matched' {
        InModuleScope PSScriptLauncher -Parameters @{ Info = $script:SearchInfo } {
            param($Info)
            (Get-ScriptMatchKind -ScriptInfo $Info -Filter 'specific') | Should -Be 'name'
            (Get-ScriptMatchKind -ScriptInfo $Info -Filter 'gigabytes') | Should -Be 'parameter'
            (Get-ScriptMatchKind -ScriptInfo $Info -Filter 'platform') | Should -Be 'help'
            (Get-ScriptMatchKind -ScriptInfo $Info -Filter 'nothing-matches-this') | Should -Be ''
        }
    }

    It 'still searches after a cache reload' {
        $cachePath = Join-Path (Join-Path $TestDrive 'search-cache') 'cache.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cachePath) -Force
        InModuleScope PSScriptLauncher -Parameters @{ Root = $TestDrive; CachePath = $cachePath } {
            param($Root, $CachePath)
            $empty = Read-CatalogCache -Path $CachePath -Root $Root
            $catalog = Get-ScriptCatalog -Root $Root -Cache $empty
            Save-CatalogCache -Path $CachePath -Cache $catalog.Cache
            $cache = Read-CatalogCache -Path $CachePath -Root $Root
            $reloaded = Get-ScriptCatalog -Root $Root -Cache $cache
            $fromCache = @($reloaded.Scripts | Where-Object { $_.FromCache -and $_.BaseName -eq 'Search' })[0]
            $fromCache | Should -Not -BeNullOrEmpty
            (Test-ScriptFilter -ScriptInfo $fromCache -Filter 'gigabytes') | Should -BeTrue
            (Test-ScriptFilter -ScriptInfo $fromCache -Filter 'platform') | Should -BeTrue
        }
    }
}

Describe 'Unknown help sections' {
    It 'warns about a section Get-Help does not know, and still shows the help' {
        $path = New-TestScript -Name 'BadTag.ps1' -Content @'
<#
.SYNOPSIS
    Has a strange section.
.TAG
    Invented by someone.
.DESCRIPTION
    Still readable.
#>
param([string]$Path)
'@
        InModuleScope PSScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path -RelativePath 'BadTag.ps1'
            @($info.Warnings).Count | Should -BeGreaterThan 0
            (@($info.Warnings) -join ' ') | Should -Match '\.TAG'
            $info.Synopsis | Should -Be 'Has a strange section.'
            $info.Description | Should -Be 'Still readable.'
        }
    }
}

Describe 'Accessibility' {
    It 'keeps every text colour readable in both palettes' {
        InModuleScope PSScriptLauncher {
            function Get-Luminance { param([string]$Hex)
                $r = [Convert]::ToInt32($Hex.Substring(1, 2), 16) / 255
                $g = [Convert]::ToInt32($Hex.Substring(3, 2), 16) / 255
                $b = [Convert]::ToInt32($Hex.Substring(5, 2), 16) / 255
                $f = { param($c) if ($c -le 0.03928) { $c / 12.92 } else { [math]::Pow((($c + 0.055) / 1.055), 2.4) } }
                0.2126 * (& $f $r) + 0.7152 * (& $f $g) + 0.0722 * (& $f $b)
            }
            function Get-ContrastRatio { param([string]$Foreground, [string]$Background)
                $a = Get-Luminance $Foreground; $b = Get-Luminance $Background
                $hi = [math]::Max($a, $b); $lo = [math]::Min($a, $b)
                ($hi + 0.05) / ($lo + 0.05)
            }
            foreach ($theme in 'light', 'dark', 'contrast') {
                $palette = Get-ThemePalette -Name $theme
                foreach ($pair in @(@('Text', 'Window'), @('Text', 'Surface'), @('Muted', 'Window'),
                        @('Muted', 'Surface'), @('Warning', 'Surface'), @('Link', 'Surface'),
                        @('AccentText', 'Accent'), @('Text', 'Sunken'), @('Muted', 'Sunken'), @('Text', 'Field'), @('Muted', 'Field'), @('Accent', 'Sunken'),
                        @('Text', 'Control'))) {
                    $foreground = $palette[$pair[0]]
                    $background = $palette[$pair[1]]
                    (Get-ContrastRatio -Foreground $foreground -Background $background) |
                        Should -BeGreaterOrEqual 4.5 -Because "$theme`: $($pair[0]) on $($pair[1])"
                }
            }
        }
    }

    It 'names the controls a screen reader has to announce' {
        InModuleScope PSScriptLauncher -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $folder = Join-Path $Drive 'a11y'
            $null = New-Item -ItemType Directory -Path $folder -Force
            $enc = [System.Text.UTF8Encoding]::new($true)
            $nl = [Environment]::NewLine
            [System.IO.File]::WriteAllText((Join-Path $folder 'Get-Sample.ps1'),
                ('<#' + $nl + '.SYNOPSIS' + $nl + '    Sample.' + $nl + '#>' + $nl + 'param([string]$Name)'), $enc)
            [System.IO.File]::WriteAllText((Join-Path $folder 'Get-Bare.ps1'), 'param([string]$Quiet)', $enc)
            $statePath = Join-Path $Drive 'a11y-state.json'
            Initialize-UiText -Language 'en' -StatePath $statePath
            $script:State = New-LauncherState -Root $folder -StatePath $statePath
            try {
                Initialize-LauncherWindow
                foreach ($name in 'SearchBox', 'ScriptTree', 'RecentButton', 'FolderButton', 'HelpReportButton',
                    'HelpFilterCombo', 'LanguageCombo', 'ThemeCombo', 'EditButton', 'CommandBox', 'HelpText') {
                    [System.Windows.Automation.AutomationProperties]::GetName($script:Ui[$name]) |
                        Should -Not -BeNullOrEmpty -Because $name
                }

                Start-CatalogScan
                for ($i = 0; $i -lt 100 -and $script:State.Scan; $i++) {
                    Start-Sleep -Milliseconds 50
                    Update-CatalogScan
                }

                # Colour alone is not information: a script without help says so
                $bare = @($script:Ui.ScriptTree.Items | Where-Object { $_.Header.Text -eq 'Get-Bare' })[0]
                [System.Windows.Automation.AutomationProperties]::GetItemStatus($bare) | Should -Not -BeNullOrEmpty

                # Each parameter field carries the parameter name, not just a visual header
                $sample = @($script:Ui.ScriptTree.Items | Where-Object { $_.Header.Text -eq 'Get-Sample' })[0]
                $sample.IsSelected = $true
                $script:Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
                foreach ($row in $script:State.Rows) {
                    [System.Windows.Automation.AutomationProperties]::GetName($row.Control) | Should -Be $row.Parameter.Name
                }
            }
            finally {
                if ($script:Window) {
                    $script:Window.Close()
                    $script:Window = $null
                }
            }
        }
    }

    It 'applies the light and dark palettes' {
        InModuleScope PSScriptLauncher -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $statePath = Join-Path $Drive 'a11y-theme.json'
            Initialize-UiText -Language 'en' -StatePath $statePath
            $script:State = New-LauncherState -Root $Drive -StatePath $statePath
            try {
                Initialize-LauncherWindow
                Set-UiTheme -Name 'light'
                $script:Window.Background.Color.ToString() | Should -Be '#FFE6EBEF'
                Set-UiTheme -Name 'dark'
                $script:Window.Background.Color.ToString() | Should -Be '#FF0F1923'
            }
            finally {
                if ($script:Window) {
                    $script:Window.Close()
                    $script:Window = $null
                }
            }
        }
    }
}
