<#
.SYNOPSIS
    Instalacion basica desatendida de Windows.
    Menu para elegir que personalizar en Windows.
.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Instala la ultima version de Notepad++, 7-Zip, Firefox y Chrome.
    - Al ejecutarse muestra una lista para tildar que se quiere aplicar.
    - Puede instalar Notepad++, 7-Zip, Firefox y Chrome.
      Si alguno ya esta instalado, no lo vuelve a descargar.
      7-Zip no firma su instalador: se comprueba el SHA-256 de la
      release oficial.
    - Deshabilita el Firewall de Windows en todas las redes y lo deja
      aplicado por directiva.
    - Habilita Escritorio remoto y desmarca "Permitir solo conexiones
      desde equipos con Autenticacion a nivel de red".
    - Deshabilita IPv6 en los adaptadores y en el sistema.
      El cambio de IPv6 queda completo despues de reiniciar.
    - Oculta el campo de busqueda de la barra de tareas y alinea
      los iconos a la izquierda.
    - Genera log en C:\ProgramData\WinBasicDeploy.
    - Puede deshabilitar el Firewall, habilitar Escritorio remoto sin
      autenticacion de nivel de red y deshabilitar IPv6.
    - Puede ocultar la busqueda de la barra de tareas y alinearla
      a la izquierda.
    - Lo que no se tilda no se modifica.
    - Genera log en C:\ProgramData\CustomWin.
.EXAMPLE
    .\Install-Win-Basic.ps1
    .\CustomWin.ps1
.EXAMPLE
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-Win-Basic.ps1" | iex
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/CustomWin.ps1" | iex
#>
# Windows PowerShell 5.1 rechaza #requires y param() cuando el script

[15 lines collapsed]

}
$LogDir = "C:\ProgramData\WinBasicDeploy"
$LogDir = "C:\ProgramData\CustomWin"
$LogFile = Join-Path $LogDir "Install-Win-Basic.log"
$LogFile = Join-Path $LogDir "CustomWin.log"
$TempDir = Join-Path $env:TEMP "WinBasicDeploy"
$TempDir = Join-Path $env:TEMP "CustomWin"
$Script:HideSearch = $false
$Script:AlignLeft = $false
$Script:Failures = New-Object System.Collections.Generic.List[string]

[45 lines collapsed]

function Stop-WinBasicDeploy {
function Stop-CustomWin {
    param (
        [int]$Code

[2 lines collapsed]

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw "WinBasicDeployExit:$Code"
        throw "CustomWinExit:$Code"
    }

[741 lines collapsed]

function Install-BasicApplications {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
        [string]$Architecture,
        [string[]]$Names
    )

[39 lines collapsed]

    foreach ($Package in $Packages) {
        if ($Names -and $Names -notcontains $Package.Name) {
            continue
        }
        try {
            $Installed = Find-InstalledApplication `

[267 lines collapsed]

    )
    Set-RegistryDword `
        -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
        -Name "SearchboxTaskbarMode" `
        -Value 0
    if ($Script:HideSearch) {
        Set-RegistryDword `
            -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
            -Name "SearchboxTaskbarMode" `
            -Value 0
    # Sin esta marca, el Explorador trata el valor anterior como
    # ausente y vuelve a mostrar el cuadro de busqueda.
    Set-RegistryDword `
        -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
        -Name "SearchboxTaskbarModeCache" `
        -Value 1
        # Sin esta marca, el Explorador trata el valor anterior como
        # ausente y vuelve a mostrar el cuadro de busqueda.
        Set-RegistryDword `
            -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
            -Name "SearchboxTaskbarModeCache" `
            -Value 1
    }
    Set-RegistryDword `
        -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
        -Name "TaskbarAl" `
        -Value 0
    if ($Script:AlignLeft) {
        Set-RegistryDword `
            -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
            -Name "TaskbarAl" `
            -Value 0
    }
}

[84 lines collapsed]

    )
    $HiveName = "WinBasicTaskbar"
    $HiveName = "CustomWinTaskbar"
    $Loaded = "Registry::HKEY_USERS\$HiveName"

[63 lines collapsed]

    }
    $TaskName = "WinBasicExplorer"
    $TaskName = "CustomWinExplorer"
    $Schtasks = "$env:SystemRoot\System32\schtasks.exe"

[61 lines collapsed]

function Test-TaskbarLayoutApplied {
    $SearchMode = (
        Get-ItemProperty `
            -LiteralPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
            -Name "SearchboxTaskbarMode"
    ).SearchboxTaskbarMode
    if ($Script:HideSearch) {
