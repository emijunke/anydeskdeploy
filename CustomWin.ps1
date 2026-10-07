
[4 lines collapsed]

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Al ejecutarse muestra una lista para tildar que se quiere aplicar.
    - Puede instalar Notepad++, 7-Zip, Firefox, Chrome y PuTTY.
    - Puede instalar Notepad++, 7-Zip, Firefox, Chrome, PuTTY y VMware Tools.
      Si alguno ya esta instalado, no lo vuelve a descargar.
      7-Zip no firma su instalador: se comprueba el SHA-256 de la
      release oficial.
    - Puede deshabilitar el Firewall, habilitar Escritorio remoto sin
      autenticacion de nivel de red y deshabilitar IPv6.
    - Puede ocultar la busqueda de la barra de tareas y alinearla
      a la izquierda.
    - Lo que no se tilda no se modifica.
    - Genera log en C:\ProgramData\CustomWin.
.EXAMPLE
    .\CustomWin.ps1
.EXAMPLE
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/CustomWin.ps1" | iex
#>
# Windows PowerShell 5.1 rechaza #requires y param() cuando el script
# se ejecuta con Invoke-Expression (irm | iex).
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if ($PSVersionTable.PSVersion -lt [Version] "5.1") {
    Write-Host "Se requiere PowerShell 5.1 o superior."
    if ($PSCommandPath) {
        exit 12
    }
    return
}
$LogDir = "C:\ProgramData\CustomWin"
$LogFile = Join-Path $LogDir "CustomWin.log"
$TempDir = Join-Path $env:TEMP "CustomWin"
$Script:HideSearch = $false

[292 lines collapsed]

        [ValidateSet("NSIS", "MSI")]
        [string]$Kind,
        [string]$Sha256
        [string]$Sha256,
        [string]$Arguments
    )

[15 lines collapsed]

    $Size = (Get-Item -LiteralPath $Destination).Length
    if ($Size -lt 400KB) {
        throw "El archivo descargado parece invalido. Tamano: $Size bytes."
    }
    Write-Log ("Descarga de {0} completada. Tamano: {1:N1} MB" -f $Name, ($Size / 1MB)) "OK"
    $Trust = Test-InstallerTrust -Path $Destination -Sha256 $Sha256
    Write-Log "Integridad de ${Name}: $Trust" "OK"
    Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    if ($Kind -eq "MSI") {
        $Msiexec = "$env:SystemRoot\System32\msiexec.exe"
        if (
            [Environment]::Is64BitOperatingSystem -and
            -not [Environment]::Is64BitProcess
        ) {
            $Msiexec = "$env:SystemRoot\Sysnative\msiexec.exe"
        }
        $Arguments = "/i `"$Destination`" /qn /norestart"
        $ExitCode = Invoke-InstallerProcess `
            -FilePath $Msiexec `
            -Arguments $Arguments
    }
    else {
        $SetupArgs = "/S"
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $SetupArgs = $Arguments
        }
        $ExitCode = Invoke-InstallerProcess `
            -FilePath $Destination `
            -Arguments "/S"
            -Arguments $SetupArgs
    }
    if ($ExitCode -in @(0, 3010, 1641, $null)) {
        Write-Log "$Name instalado. Codigo: $ExitCode" "OK"
        return
    }
    throw "$Name devolvio el codigo $ExitCode."
}
function Get-NotepadPlusPlusUrl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )
    $Release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest" `
        -Headers @{ "User-Agent" = "Install-Win-Basic" }
    $Asset = $null
    if ($Architecture -eq "ARM64") {
        $Asset = $Release.assets |
            Where-Object { $_.name -like "npp.*.Installer.arm64.exe" } |
            Select-Object -First 1
    }
    elseif ($Architecture -eq "x64") {
        $Asset = $Release.assets |
            Where-Object { $_.name -like "npp.*.Installer.x64.exe" } |
            Select-Object -First 1
    }
    else {
        $Asset = $Release.assets |
            Where-Object {
                $_.name -like "npp.*.Installer.exe" -and
                $_.name -notlike "*.Installer.x64.exe" -and
                $_.name -notlike "*.Installer.arm64.exe"
            } |
            Select-Object -First 1
    }
    if (-not $Asset) {
        throw "No se encontro el instalador de Notepad++ para $Architecture."
    }
    return $Asset.browser_download_url
}
function Get-SevenZipPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )
