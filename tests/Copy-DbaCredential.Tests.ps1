$CommandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", "")
Write-Host -Object "Running $PSCommandPath" -ForegroundColor Cyan
$global:TestConfig = Get-TestConfig
. "$PSScriptRoot\..\private\functions\Invoke-Command2.ps1"

Describe "$CommandName Unit Tests" -Tag 'UnitTests' {
    Context "Validate parameters" {
        [object[]]$params = (Get-Command $CommandName).Parameters.Keys | Where-Object { $_ -notin ('whatif', 'confirm') }
        [object[]]$knownParameters = 'Source', 'SourceSqlCredential', 'Credential', 'Destination', 'DestinationSqlCredential', 'Name', 'ExcludeName', 'Identity', 'ExcludeIdentity', 'Force', 'EnableException'
        $knownParameters += [System.Management.Automation.PSCmdlet]::CommonParameters
        It "Should only contain our specific parameters" {
            (@(Compare-Object -ReferenceObject ($knownParameters | Where-Object { $_ }) -DifferenceObject $params).Count ) | Should Be 0
        }
    }
}

Describe "$CommandName Integration Tests" -Tag "IntegrationTests" {
    BeforeAll {
        $logins = "dbatoolsci_thor", "dbatoolsci_thorsmomma", "dbatoolsci_thor_crypto"
        $plaintext = "BigOlPassword!"
        $password = ConvertTo-SecureString $plaintext -AsPlainText -Force

        $server2 = Connect-DbaInstance -SqlInstance $TestConfig.instance2
        $server3 = Connect-DbaInstance -SqlInstance $TestConfig.instance3

        # Add user
        foreach ($login in $logins) {
            $null = Invoke-Command2 -ScriptBlock { net user $args[0] $args[1] /add *>&1 } -ArgumentList $login, $plaintext -ComputerName $TestConfig.instance2
            $null = Invoke-Command2 -ScriptBlock { net user $args[0] $args[1] /add *>&1 } -ArgumentList $login, $plaintext -ComputerName $TestConfig.instance3
        }

        <#
            New tests have been added for validating a credential that uses a crypto provider. (Ref: https://github.com/dataplat/dbatools/issues/7896)

            The new pester tests will only run if a crypto provider is registered and enabled.

            Follow these steps to configure the local machine to run the crypto provider tests.

            1. Run these SQL commands on the instance2 and instance3 servers:

            -- Enable advanced options.
            USE master;
            GO
            sp_configure 'show advanced options', 1;
            GO
            RECONFIGURE;
            GO
            -- Enable EKM provider
            sp_configure 'EKM provider enabled', 1;
            GO
            RECONFIGURE;

            2. Install https://www.microsoft.com/en-us/download/details.aspx?id=45344 on the instance2 and instance3 servers.

            3. Run these SQL commands on the instance2 and instance3 servers:

            CREATE CRYPTOGRAPHIC PROVIDER dbatoolsci_AKV FROM FILE = 'C:\github\appveyor-lab\keytests\ekm\Microsoft.AzureKeyVaultService.EKM.dll'
        #>

        # check to see if a crypto provider is present on the instances
        $instance2CryptoProviders = $server2.Query("SELECT name FROM sys.cryptographic_providers WHERE is_enabled = 1 ORDER BY name")
        $instance3CryptoProviders = $server3.Query("SELECT name FROM sys.cryptographic_providers WHERE is_enabled = 1 ORDER BY name")

        $cryptoProvider = ($instance2CryptoProviders | Where-Object { $_.name -eq $instance3CryptoProviders.name } | Select-Object -First 1).name
    }
    AfterAll {
        (Get-DbaCredential -SqlInstance $server2 -Identity dbatoolsci_thor, dbatoolsci_thorsmomma, dbatoolsci_thor_crypto -ErrorAction Stop -WarningAction SilentlyContinue).Drop()
        (Get-DbaCredential -SqlInstance $server3 -Identity dbatoolsci_thor, dbatoolsci_thorsmomma, dbatoolsci_thor_crypto -ErrorAction Stop -WarningAction SilentlyContinue).Drop()

        foreach ($login in $logins) {
            $null = Invoke-Command2 -ScriptBlock { net user $args /delete *>&1 } -ArgumentList $login -ComputerName $TestConfig.instance2
            $null = Invoke-Command2 -ScriptBlock { net user $args /delete *>&1 } -ArgumentList $login -ComputerName $TestConfig.instance3
        }
    }

    Context "Create new credential" {
        It "Should create new credentials with the proper properties" {
            $results = New-DbaCredential -SqlInstance $server2 -Name dbatoolsci_thorcred -Identity dbatoolsci_thor -Password $password
            $results.Name | Should Be "dbatoolsci_thorcred"
            $results.Identity | Should Be "dbatoolsci_thor"

            $results = New-DbaCredential -SqlInstance $server2 -Identity dbatoolsci_thorsmomma -Password $password
            $results.Name | Should Be "dbatoolsci_thorsmomma"
            $results.Identity | Should Be "dbatoolsci_thorsmomma"

            if ($cryptoProvider) {
                $results = New-DbaCredential -SqlInstance $server2 -Identity dbatoolsci_thor_crypto -Password $password -MappedClassType CryptographicProvider -ProviderName $cryptoProvider
                $results.Name | Should Be "dbatoolsci_thor_crypto"
                $results.Identity | Should Be "dbatoolsci_thor_crypto"
                $results.ProviderName | Should -Be $cryptoProvider
            }
        }
    }

    Context "Copy Credential with the same properties." {
        It "Should copy successfully" {
            $results = Copy-DbaCredential -Source $server2 -Destination $server3 -Name dbatoolsci_thorcred
            $results.Status | Should Be "Successful"
        }

        It "Should retain its same properties" {
            $Credential1 = Get-DbaCredential -SqlInstance $server2 -Name dbatoolsci_thor -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            $Credential2 = Get-DbaCredential -SqlInstance $server3 -Name dbatoolsci_thor -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

            # Compare its value
            $Credential1.Name | Should Be $Credential2.Name
            $Credential1.Identity | Should Be $Credential2.Identity
        }
    }

    Context "No overwrite" {
        It "does not overwrite without force" {
            $results = Copy-DbaCredential -Source $server2 -Destination $server3 -Name dbatoolsci_thorcred
            $results.Status | Should Be "Skipping"
        }
    }

    # See https://github.com/dataplat/dbatools/issues/7896 and comments above in BeforeAll
    Context "Crypto provider cred" {
        It -Skip:(-not $cryptoProvider) "ensure copied credential is using the same crypto provider" {
            $results = Copy-DbaCredential -Source $server2 -Destination $server3 -Name dbatoolsci_thor_crypto
            $results.Status | Should Be Successful
            $results = Get-DbaCredential -SqlInstance $server3 -Name dbatoolsci_thor_crypto
            $results.Name | Should -Be dbatoolsci_thor_crypto
            $results.ProviderName | Should -Be $cryptoProvider
        }

        It -Skip:(-not $cryptoProvider) "check warning message if crypto provider is not configured/enabled on destination" {
            Remove-DbaCredential -SqlInstance $server3 -Credential dbatoolsci_thor_crypto -Confirm:$false
            $server3.Query("ALTER CRYPTOGRAPHIC PROVIDER $cryptoProvider DISABLE")
            $results = Copy-DbaCredential -Source $server2 -Destination $server3 -Name dbatoolsci_thor_crypto
            $server3.Query("ALTER CRYPTOGRAPHIC PROVIDER $cryptoProvider ENABLE")
            $results.Status | Should Be Failed
            $results.Notes | Should -Match "The cryptographic provider $cryptoProvider needs to be configured and enabled on"
        }
    }
}
