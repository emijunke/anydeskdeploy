#requires -version 5.1
<#
.SYNOPSIS
    Instalacion desatendida de AnyDesk, sin interfaz para el usuario local.

[36 lines collapsed]

.EXAMPLE
    .\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD' -ShowUserInterface
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$UnattendedPassword,
.EXAMPLE
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-AnyDesk.ps1" | iex
    [Parameter(Mandatory = $false)]
    [switch]$ShowUserInterface
)
.EXAMPLE
    $UnattendedPassword = 'PASSWORD'
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-AnyDesk.ps1" | iex
#>
# Windows PowerShell 5.1 rechaza #requires y param() cuando el script
# se ejecuta con Invoke-Expression (irm | iex).
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion -lt [Version] "5.1") {
    Write-Host "Se requiere PowerShell 5.1 o superior."
    if ($PSCommandPath) {
        exit 12
    }
    return
}
$DeployPassword = $null
$DeployShowUserInterface = $false
if (Test-Path -Path "variable:UnattendedPassword") {
    $DeployPassword = [string]$UnattendedPassword
}
if (Test-Path -Path "variable:ShowUserInterface") {
    $DeployShowUserInterface = [bool]$ShowUserInterface
}
$DeployArguments = @($args)
for ($DeployIndex = 0; $DeployIndex -lt $DeployArguments.Count; $DeployIndex++) {
    $DeployToken = [string]$DeployArguments[$DeployIndex]
    if ($DeployToken -eq "-UnattendedPassword") {
        $DeployIndex++
        if ($DeployIndex -lt $DeployArguments.Count) {
            $DeployPassword = [string]$DeployArguments[$DeployIndex]
        }
    }
    elseif ($DeployToken -eq "-ShowUserInterface") {
        $DeployShowUserInterface = $true
    }
}
$UnattendedPassword = $DeployPassword
$ShowUserInterface = $DeployShowUserInterface
# ============================================================
# PASSWORD
# ============================================================

[1611 lines collapsed]

function Stop-AnyDeskDeploy {
    param (
        [int]$Code
    )
    # iex comparte la consola del operador. exit cerraria esa ventana.
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw "AnyDeskDeployExit:$Code"
    }
    exit $Code
}
# ============================================================
# PREPARACION
# ============================================================
try {
New-Item `
    -ItemType Directory `
    -Path $LogDir `

[54 lines collapsed]

    Write-Host ""
    exit 10
    Stop-AnyDeskDeploy -Code 10
}

[17 lines collapsed]

        "ERROR"
    exit 11
    Stop-AnyDeskDeploy -Code 11
}

[159 lines collapsed]

            "ERROR"
        exit 20
        Stop-AnyDeskDeploy -Code 20
    }

[5 lines collapsed]

            "ERROR"
        exit 21
        Stop-AnyDeskDeploy -Code 21
    }

[8 lines collapsed]

            "ERROR"
        exit 22
        Stop-AnyDeskDeploy -Code 22
    }

[30 lines collapsed]

            -ErrorAction SilentlyContinue
        exit 23
        Stop-AnyDeskDeploy -Code 23
    }
