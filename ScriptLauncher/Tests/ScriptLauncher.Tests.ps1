# Tests Pester (5.2 ou plus récent) du module ScriptLauncher : analyse des scripts, construction
# de la commande, état par utilisateur. L'interface WPF n'est pas couverte ici.
#
#   Invoke-Pester -Path .\ScriptLauncher\Tests
#
# Windows PowerShell 5.1 est livré avec Pester 3 : installer une version récente au préalable
# (Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck).

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ScriptLauncher.psd1') -Force

    function New-TestScript {
        # Écrit un script de test en UTF-8 avec BOM et renvoie son chemin.
        param([string]$Name, [string]$Content)
        $path = Join-Path $TestDrive $Name
        $folder = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($true))
        $path
    }
}

Describe 'Analyse d''un script' {
    BeforeAll {
        $script:AccountScript = New-TestScript -Name (Join-Path 'AD' 'New-Account.ps1') -Content @'
#Requires -Version 5.1

<#
.SYNOPSIS
    Crée un compte.
.DESCRIPTION
    Description longue.
.PARAMETER Login
    Identifiant du compte.
.EXAMPLE
    PS C:\> .\New-Account.ps1 -Login jdupont -Level 3 -Groups 'A', 'B' -Force

    Création simple.
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

    # Groupes à attribuer
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

    It 'lit le synopsis, la description et les exigences sans exécuter le script' {
        InModuleScope ScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -Be 'Crée un compte.'
            $info.Description | Should -Be 'Description longue.'
            $info.Warnings.Count | Should -Be 0
            [string]$info.Requirements.PSVersion | Should -Be '5.1'
            $info.SupportsShouldProcess | Should -BeTrue
        }
    }

    It 'détermine la catégorie de saisie de chaque paramètre' {
        InModuleScope ScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $kinds = @{}
            foreach ($parameter in (Get-ScriptInfo -LiteralPath $Path).Parameters) { $kinds[$parameter.Name] = $parameter.Kind }
            $kinds['Login'] | Should -Be 'Text'
            $kinds['Groups'] | Should -Be 'TextArray'
            $kinds['Level'] | Should -Be 'Number'
            $kinds['Profile'] | Should -Be 'Choice'
            $kinds['Since'] | Should -Be 'Date'
            $kinds['Target'] | Should -Be 'Text'          # type inconnu de la session : saisie libre
            $kinds['Credential'] | Should -Be 'Credential'
            $kinds['Force'] | Should -Be 'Switch'
        }
    }

    It 'lit les jeux de paramètres, les alias et les descriptions' {
        InModuleScope ScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.ParameterSets | Should -Be @('Single', 'Csv')
            $info.DefaultParameterSet | Should -Be 'Single'
            $login = $info.Parameters | Where-Object Name -EQ 'Login'
            $login.Aliases | Should -Be @('Sam')
            $login.Description | Should -Be 'Identifiant du compte.'
            Get-ParameterSetMembership -Parameter $login -ParameterSet 'Single' | Should -BeTrue
            Get-ParameterSetMembership -Parameter $login -ParameterSet 'Csv' | Should -BeNullOrEmpty
            ($info.Parameters | Where-Object Name -EQ 'Groups').Description | Should -Be 'Groupes à attribuer'
        }
    }

    It 'lit ValidateRange et ValidatePattern' {
        InModuleScope ScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $level = $info.Parameters | Where-Object Name -EQ 'Level'
            $level.Validation['Range']['Min'] | Should -Be 1
            $level.Validation['Range']['Max'] | Should -Be 5
            $code = $info.Parameters | Where-Object Name -EQ 'Code'
            $code.Validation['Pattern']['Regex'] | Should -Be '^[A-Z]{2}-\d{2}$'
        }
    }

    It 'analyse les exemples : invite retirée, alias résolus, valeurs littérales ou non' {
        InModuleScope ScriptLauncher -Parameters @{ Path = $script:AccountScript } {
            param($Path)
            $examples = @((Get-ScriptInfo -LiteralPath $Path).Examples)
            $examples.Count | Should -Be 2
            $examples[0].Code | Should -BeLike '.\New-Account.ps1 -Login jdupont*'
            $examples[0].Arguments['Login'].Value | Should -Be 'jdupont'
            $examples[0].Arguments['Level'].Value | Should -Be '3'
            $examples[0].Arguments['Groups'].Value | Should -Be @('A', 'B')
            $examples[0].Arguments['Force'].Value | Should -BeTrue
            $examples[1].Arguments['CsvPath'].Value | Should -Be '.\in.csv'
            $examples[1].Arguments['Since'].IsLiteral | Should -BeFalse
            $examples[1].Arguments['Since'].Text | Should -Be '$date'
        }
    }

    It 'signale une aide collée à #Requires, que Get-Help ne voit pas' {
        $path = New-TestScript -Name 'Glued.ps1' -Content "#Requires -Version 5.1`n<#`n.SYNOPSIS`n    Aide collée.`n#>`nparam([string]`$Name)`n"
        InModuleScope ScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -Be 'Aide collée.'
            ($info.Warnings -join ' ') | Should -Match 'il manque une ligne vide'
        }
    }

    It 'ne signale rien pour une bibliothèque de fonctions' {
        $path = New-TestScript -Name 'Lib.ps1' -Content "<#`n.SYNOPSIS`n    Aide de Get-Truc.`n#>`nfunction Get-Truc { }`n`nfunction Get-Machin { }`n"
        InModuleScope ScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $info.Synopsis | Should -BeNullOrEmpty
            $info.Warnings.Count | Should -Be 0
        }
    }

    It 'signale une erreur de syntaxe ou un fichier illisible sans lever d''exception' {
        $path = New-TestScript -Name 'Broken.ps1' -Content "param([string]`$Name)`nif (`$Name {`n"
        InModuleScope ScriptLauncher -Parameters @{ Path = $path; Missing = (Join-Path $TestDrive 'absent.ps1') } {
            param($Path, $Missing)
            ((Get-ScriptInfo -LiteralPath $Path).Warnings -join ' ') | Should -Match 'Erreur de syntaxe'
            ((Get-ScriptInfo -LiteralPath $Missing).Warnings -join ' ') | Should -Match 'Lecture impossible'
        }
    }

    It 'décode un script en page de code ANSI (sans BOM)' {
        $path = Join-Path $TestDrive 'Ansi.ps1'
        $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
        if ($ansi.CodePage -eq 65001) { Set-ItResult -Skipped -Because 'la page de code ANSI du système est UTF-8' }
        [System.IO.File]::WriteAllBytes($path, $ansi.GetBytes("<#`n.SYNOPSIS`n    Créé à l'été.`n#>`nparam()`n"))
        InModuleScope ScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            (Get-ScriptInfo -LiteralPath $Path).Synopsis | Should -Be "Créé à l'été."
        }
    }
}

Describe 'Inventaire d''un dossier' {
    BeforeAll {
        $script:CatalogRoot = Join-Path $TestDrive 'catalog'
        $names = @(
            (Join-Path 'B' 'Two.ps1'), (Join-Path 'A' 'One.ps1'), (Join-Path 'A' 'One.Tests.ps1'), 'Root.ps1',
            (Join-Path (Join-Path 'ScriptLauncher' 'Private') 'Inner.ps1')
        )
        foreach ($name in $names) {
            $null = New-TestScript -Name (Join-Path 'catalog' $name) -Content "<#`n.SYNOPSIS`n    $name`n#>`nparam()`n"
        }
    }

    It 'liste les scripts triés, hors motifs et dossiers exclus, et renseigne la progression' {
        InModuleScope ScriptLauncher -Parameters @{ Root = $script:CatalogRoot } {
            param($Root)
            $progress = [hashtable]::Synchronized(@{ Total = 0; Done = 0 })
            $catalog = Get-ScriptCatalog -Root $Root -ExcludePattern '*.Tests.ps1' -Summary -Progress $progress `
                -ExcludeDirectory (Join-Path $Root 'ScriptLauncher')
            $catalog.Scripts.Name | Should -Be @('One.ps1', 'Two.ps1', 'Root.ps1')
            $progress['Total'] | Should -Be 3
            $progress['Done'] | Should -Be 3
            $catalog.Scripts[0].Synopsis | Should -Match 'One\.ps1'
        }
    }

    It 'refuse un chemin qui n''est pas un dossier' {
        InModuleScope ScriptLauncher -Parameters @{ File = (Join-Path $script:CatalogRoot 'Root.ps1') } {
            param($File)
            { Get-ScriptCatalog -Root $File } | Should -Throw
        }
    }

    It 'filtre sans tenir compte de la casse ni des accents, tous les termes étant requis' {
        InModuleScope ScriptLauncher {
            $entry = [pscustomobject]@{ RelativePath = 'AD\Get-Report.ps1'; Synopsis = 'Comptes désactivés' }
            Test-ScriptFilter -ScriptInfo $entry -Filter 'DESACTIVES report' | Should -BeTrue
            Test-ScriptFilter -ScriptInfo $entry -Filter 'report licence' | Should -BeFalse
        }
    }
}

Describe 'Construction de la commande' {
    BeforeAll {
        $script:PreviousCulture = [System.Globalization.CultureInfo]::CurrentCulture
        [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    }
    AfterAll {
        [System.Globalization.CultureInfo]::CurrentCulture = $script:PreviousCulture
    }

    It 'réécrit dates et nombres saisis en français au format invariant' {
        InModuleScope ScriptLauncher {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            ConvertTo-InvariantDate -Text '09/11/2026' | Should -Be '2026-11-09'
            ConvertTo-InvariantDate -Text '09/11/2026 14:30' | Should -Be '2026-11-09T14:30:00'
            ConvertTo-InvariantNumber -Text '3,5' | Should -Be '3.5'
            ConvertTo-InvariantNumber -Text '3.5' | Should -Be '3.5'
            ConvertTo-InvariantNumber -Text '2,5' -Integer | Should -BeNullOrEmpty
            ConvertTo-InvariantNumber -Text 'abc' | Should -BeNullOrEmpty
        }
    }

    It 'double les apostrophes, droites et typographiques' {
        InModuleScope ScriptLauncher {
            ConvertTo-PSQuotedString -Value "O'Brien" | Should -Be "'O''Brien'"
            $curly = [string][char]0x2019
            ConvertTo-PSQuotedString -Value "l${curly}été" | Should -Be "'l${curly}${curly}été'"
        }
    }

    It 'produit une commande exécutable qui transmet les valeurs à l''identique' {
        $echo = New-TestScript -Name 'Echo.ps1' -Content @'
param([string]$Text, [string[]]$List, [int]$Count, [decimal]$Amount, [datetime]$When, [switch]$Force)
'{0}|{1}|{2}|{3}|{4}|{5}' -f $Text, ($List -join '+'), $Count, $Amount.ToString([cultureinfo]::InvariantCulture),
    $When.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture), $Force.IsPresent
'@
        $command = InModuleScope ScriptLauncher -Parameters @{ Path = $echo } {
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

    It 'signale les obligatoires manquants et les valeurs hors ValidateRange / ValidatePattern' {
        $path = New-TestScript -Name 'Valid.ps1' -Content @'
param(
    [Parameter(Mandatory)][string]$Name,
    [ValidateRange(1, 5)][int]$Level,
    [ValidatePattern('^[A-Z]{2}-\d{2}$')][string]$Code,
    [ValidateRange(0.5, 2)][double[]]$Ratios
)
'@
        InModuleScope ScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $info = Get-ScriptInfo -LiteralPath $Path
            $bad = New-ScriptCommand -ScriptInfo $info -Values @{ Level = '7'; Code = 'ab-1'; Ratios = [string[]]@('0,5', '3') }
            $bad.Missing | Should -Be @('Name')
            ($bad.Errors.Keys | Sort-Object) | Should -Be @('Code', 'Level', 'Ratios')
            ($bad.Errors['Level'] -join '') | Should -Match 'hors limites \(intervalle : 1 à 5\)'
            ($bad.Errors['Ratios'] -join '') | Should -Match '« 3 »'
            $good = New-ScriptCommand -ScriptInfo $info -Values @{ Name = 'x'; Level = '5'; Code = 'ab-12'; Ratios = [string[]]@('0,5', '2') }
            $good.Missing.Count | Should -Be 0
            $good.Errors.Count | Should -Be 0
        }
    }

    It 'ne met jamais de secret dans la commande : Get-Credential et Read-Host sont appelés au lancement' {
        $path = New-TestScript -Name 'Secret.ps1' -Content 'param([pscredential]$Credential, [securestring]$Password)'
        InModuleScope ScriptLauncher -Parameters @{ Path = $path } {
            param($Path)
            $info = Get-ScriptInfo -LiteralPath $Path
            $values = @{ Credential = [pscustomobject]@{ Prompt = $true; UserName = 'DOM\adm' }; Password = $true }
            $text = (New-ScriptCommand -ScriptInfo $info -Values $values).CommandText
            $text | Should -Match ([regex]::Escape("-Credential (Get-Credential -UserName 'DOM\adm' -Message"))
            $text | Should -Match ([regex]::Escape("-Password (Read-Host -AsSecureString -Prompt 'Password')"))
        }
    }

    It 'échappe les arguments pour la ligne de commande Windows' {
        InModuleScope ScriptLauncher {
            ConvertTo-ProcessArgument -Value 'simple' | Should -Be 'simple'
            ConvertTo-ProcessArgument -Value 'a b' | Should -Be '"a b"'
            ConvertTo-ProcessArgument -Value 'a"b' | Should -Be '"a\"b"'
            ConvertTo-ProcessArgument -Value 'C:\Dossier test\' | Should -Be '"C:\Dossier test\\"'
            ConvertTo-ProcessArgument -Value '' | Should -Be '""'
        }
    }
}

Describe 'État par utilisateur' {
    It 'enregistre et relit favoris, récents et saisies, tableaux compris' {
        $statePath = Join-Path (Join-Path $TestDrive 'state') 'state.json'
        InModuleScope ScriptLauncher -Parameters @{ StatePath = $statePath } {
            param($StatePath)
            $state = Read-UserState -Path $StatePath
            $state.Favorites.Count | Should -Be 0
            Switch-FavoriteScript -State $state -ScriptPath 'C:\S\A.ps1' | Should -BeTrue
            Set-RememberedInput -State $state -ScriptPath 'C:\S\A.ps1' -ParameterSet 'Csv' -Values @{
                Name   = 'x'
                Groups = @('seul')
                Force  = $true
                Cred   = @{ Prompt = $true; UserName = 'DOM\adm' }
            }
            Save-UserState -Path $StatePath -State $state

            $json = [System.IO.File]::ReadAllText($StatePath)
            $json | Should -Not -Match '"value"\s*:'          # tableau enveloppé (piège de ConvertTo-Json en 5.1)

            $reloaded = Read-UserState -Path $StatePath
            Test-FavoriteScript -State $reloaded -ScriptPath 'c:\s\a.PS1' | Should -BeTrue
            $reloaded.Recents | Should -Be @('C:\S\A.ps1')
            $remembered = Get-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1'
            $remembered.ParameterSet | Should -Be 'Csv'
            $remembered.Values['Name'] | Should -Be 'x'
            @($remembered.Values['Groups']) | Should -Be @('seul')
            $remembered.Values['Force'] | Should -BeTrue
            $remembered.Values['Cred']['UserName'] | Should -Be 'DOM\adm'

            Switch-FavoriteScript -State $reloaded -ScriptPath 'C:\S\A.ps1' | Should -BeFalse
            Remove-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1'
            Get-RememberedInput -State $reloaded -ScriptPath 'C:\S\A.ps1' | Should -BeNullOrEmpty
        }
    }

    It 'limite les récents et place le dernier lancé en tête, sans doublon' {
        InModuleScope ScriptLauncher {
            $state = New-UserState
            1..12 | ForEach-Object { Set-RememberedInput -State $state -ScriptPath "C:\S\$_.ps1" }
            Set-RememberedInput -State $state -ScriptPath 'C:\S\10.PS1'
            $state.Recents.Count | Should -Be $script:Settings.MaxRecent
            $state.Recents[0] | Should -Be 'C:\S\10.PS1'
            @($state.Recents | Where-Object { $_ -like '*\10.ps1' }).Count | Should -Be 1
        }
    }

    It 'ne conserve pas une valeur saisie en clair dont le nom évoque un secret' {
        InModuleScope ScriptLauncher {
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

    It 'repart d''un état vide si le fichier est corrompu' {
        $statePath = Join-Path $TestDrive 'corrompu.json'
        Set-Content -LiteralPath $statePath -Value '{ pas du JSON'
        InModuleScope ScriptLauncher -Parameters @{ StatePath = $statePath } {
            param($StatePath)
            $state = Read-UserState -Path $StatePath
            $state.Favorites.Count | Should -Be 0
            $state.Scripts.Count | Should -Be 0
        }
    }
}
