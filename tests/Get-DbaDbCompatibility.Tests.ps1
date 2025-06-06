$commandname = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", "")
Write-Host -Object "Running $PSCommandpath" -ForegroundColor Cyan
$global:TestConfig = Get-TestConfig

Describe "$CommandName Unit Tests" -Tag 'UnitTests' {
    Context "Validate parameters" {
        [object[]]$params = (Get-Command $CommandName).Parameters.Keys | Where-Object { $_ -notin ('whatif', 'confirm') }
        [object[]]$knownParameters = 'SqlInstance', 'SqlCredential', 'Database', 'InputObject', 'EnableException'
        $knownParameters += [System.Management.Automation.PSCmdlet]::CommonParameters
        It "Should only contain our specific parameters" {
            (@(Compare-Object -ReferenceObject ($knownParameters | Where-Object { $_ }) -DifferenceObject $params).Count ) | Should Be 0
        }
    }
}

Describe "$commandname Integration Tests" -Tags "IntegrationTests" {
    BeforeAll {
        $server = Connect-DbaInstance -SqlInstance $TestConfig.instance1
        $compatibilityLevel = $server.Databases['master'].CompatibilityLevel
    }
    Context "Gets compatibility for multiple databases" {
        $results = Get-DbaDbCompatibility -SqlInstance $TestConfig.instance1
        It "Gets results" {
            $results | Should Not Be $null
        }
        Foreach ($row in $results) {
            It "Should return correct compatibility level for $($row.database)" {
                # Only test system databases as there might be leftover databases from other tests
                if ($row.DatabaseId -le 4) {
                    $row.Compatibility | Should Be $compatibilityLevel
                }
                $row.DatabaseId | Should -Be (Get-DbaDatabase -SqlInstance $TestConfig.instance1 -Database $row.Database).Id
            }
        }
    }
    Context "Gets compatibility for one database" {
        $results = Get-DbaDbCompatibility -SqlInstance $TestConfig.instance1 -database master

        It "Gets results" {
            $results | Should Not Be $null
        }
        It "Should return correct compatibility level for $($results.database)" {
            $results.Compatibility | Should Be $compatibilityLevel
            $results.DatabaseId | Should -Be (Get-DbaDatabase -SqlInstance $TestConfig.instance1 -Database master).Id
        }
    }
}
