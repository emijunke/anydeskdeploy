#requires -version 5.1

<#
.SYNOPSIS
    Instalacion/configuracion automatizada de AnyDesk.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Detecta una instalacion existente de AnyDesk.
    - Obtiene el ID previo cuando es posible.
    - Descarga AnyDesk desde el sitio oficial si no esta instalado.
    - Instala AnyDesk silenciosamente.
    - Configura inicio automatico.
    - Configura acceso desatendido.
    - Obtiene ID, alias, version y estado.
    - Compara ID anterior y posterior.
    - Genera log en C:\ProgramData\AnyDeskDeploy.
    - NO reinicia ni detiene deliberadamente el servicio AnyDesk.

.PARAMETER UnattendedPassword
    Password que se configurara para acceso desatendido.

.EXAMPLE
    .\Install-AnyDesk.ps1
    Solicita interactivamente la password de acceso desatendido.

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$UnattendedPassword
)

# Si no se proporciono password como parametro, solicitarlo
# de forma interactiva y sin mostrarlo en pantalla.
if ([string]::IsNullOrWhiteSpace($UnattendedPassword)) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " CONFIGURACION DE ACCESO DESATENDIDO"
    Write-Host "============================================================"
    Write-Host ""

    $SecurePassword = Read-Host `
        "Ingrese la password de acceso desatendido de AnyDesk" `
        -AsSecureString

    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecurePassword
    )

    try {
        $UnattendedPassword = `
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURACION
# ============================================================

$DownloadUrl = "https://download.anydesk.com/AnyDesk.exe"

$InstallDir = if (${env:ProgramFiles(x86)}) {
    Join-Path ${env:ProgramFiles(x86)} "AnyDesk"
}
else {
    Join-Path $env:ProgramFiles "AnyDesk"
}

$DefaultInstalledExe = Join-Path $InstallDir "AnyDesk.exe"

$TempDir   = Join-Path $env:TEMP "AnyDeskDeploy"
$Installer = Join-Path $TempDir "AnyDesk.exe"

$LogDir  = "C:\ProgramData\AnyDeskDeploy"
$LogFile = Join-Path $LogDir "AnyDesk_Deploy.log"

$Script:AnyDeskExe = $null
$Script:OldID      = $null
$Script:NewID      = $null


# ============================================================
# FUNCIONES
# ============================================================

function Write-Log {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "OK", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $Line = "[{0}] [{1}] {2}" -f `
        $Timestamp,
        $Level,
        $Message

    switch ($Level) {

        "OK" {
            Write-Host $Line -ForegroundColor Green
        }

        "WARN" {
            Write-Host $Line -ForegroundColor Yellow
        }

        "ERROR" {
            Write-Host $Line -ForegroundColor Red
        }

        default {
            Write-Host $Line
        }
    }

    Add-Content `
        -Path $LogFile `
        -Value $Line `
        -Encoding UTF8
}


function Test-Administrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Find-AnyDeskExecutable {

    $Paths = @()

    if (${env:ProgramFiles(x86)}) {
        $Paths += Join-Path ${env:ProgramFiles(x86)} "AnyDesk\AnyDesk.exe"
    }

    if ($env:ProgramFiles) {
        $Paths += Join-Path $env:ProgramFiles "AnyDesk\AnyDesk.exe"
    }

    if ($env:LOCALAPPDATA) {
        $Paths += Join-Path $env:LOCALAPPDATA "AnyDesk\AnyDesk.exe"
    }

    # Buscar primero en ubicaciones conocidas
    foreach ($Path in $Paths) {

        if (Test-Path $Path) {
            return $Path
        }
    }

    # Intentar localizarlo mediante proceso existente
    $Processes = Get-Process `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue

    foreach ($Process in $Processes) {

        try {

            if ($Process.Path -and (Test-Path $Process.Path)) {
                return $Process.Path
            }

        }
        catch {
            # Algunos procesos pueden impedir consultar Path.
        }
    }

    return $null
}


function Get-AnyDeskID {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    try {

        $Result = (& $Executable --get-id 2>$null |
            Out-String).Trim()

        if ($Result) {
            return $Result
        }

    }
    catch {
    }

    return $null
}


function Get-AnyDeskAlias {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    try {

        $Result = (& $Executable --get-alias 2>$null |
            Out-String).Trim()

        if ($Result) {
            return $Result
        }

    }
    catch {
    }

    return $null
}


function Get-AnyDeskStatus {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    try {

        $Result = (& $Executable --get-status 2>$null |
            Out-String).Trim()

        if ($Result) {
            return $Result
        }

    }
    catch {
    }

    return "Desconocido"
}


function Get-AnyDeskVersion {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    try {

        $Result = (& $Executable --version 2>$null |
            Out-String).Trim()

        if ($Result) {
            return $Result
        }

    }
    catch {
    }

    try {

        return (Get-Item $Executable).VersionInfo.FileVersion

    }
    catch {
    }

    return "No disponible"
}


# ============================================================
# PREPARACION
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $LogDir `
    -Force | Out-Null

New-Item `
    -ItemType Directory `
    -Path $TempDir `
    -Force | Out-Null


Write-Host ""
Write-Host "============================================================"
Write-Host " ANYDESK - DEPLOY AUTOMATICO"
Write-Host "============================================================"
Write-Host ""

Write-Log "Inicio del deployment."
Write-Log "Equipo: $env:COMPUTERNAME"
Write-Log "Usuario: $env:USERDOMAIN\$env:USERNAME"


# ============================================================
# VALIDAR ADMINISTRADOR
# ============================================================

if (-not (Test-Administrator)) {

    Write-Log `
        "PowerShell no esta ejecutandose como Administrador." `
        "ERROR"

    Write-Host ""
    Write-Host "Ejecute PowerShell como Administrador."
    Write-Host ""

    exit 10
}

Write-Log "Privilegios de administrador confirmados." "OK"


# ============================================================
# VALIDAR PASSWORD
# ============================================================

if ($UnattendedPassword.Length -lt 8) {

    Write-Log `
        "La password de acceso desatendido debe tener al menos 8 caracteres." `
        "ERROR"

    exit 11
}

Write-Log "Password de acceso desatendido recibida."
Write-Log "La password NO sera escrita en el log."


# ============================================================
# DETECTAR ANYDESK ACTUAL
# ============================================================

Write-Log "Buscando instalacion existente de AnyDesk..."

$ExistingExe = Find-AnyDeskExecutable

if ($ExistingExe) {

    $Script:AnyDeskExe = $ExistingExe

    Write-Log "AnyDesk detectado." "OK"
    Write-Log "Ejecutable actual: $ExistingExe"

    $OldVersion = Get-AnyDeskVersion `
        -Executable $ExistingExe

    Write-Log "Version actual: $OldVersion"

    $Script:OldID = Get-AnyDeskID `
        -Executable $ExistingExe

    if ($Script:OldID) {

        Write-Log "ID AnyDesk actual: $Script:OldID" "OK"

    }
    else {

        Write-Log `
            "No fue posible obtener el ID actual." `
            "WARN"
    }

}
else {

    Write-Log "AnyDesk no se encuentra instalado."
}


# ============================================================
# COMPROBAR SESION / PROCESOS EXISTENTES
# ============================================================

$ExistingProcesses = Get-Process `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue

if ($ExistingProcesses) {

    Write-Log `
        "Se detectaron procesos AnyDesk activos." `
        "WARN"

    Write-Log `
        "No se detendran procesos ni servicios para preservar la sesion remota."
}


# ============================================================
# SI NO ESTA INSTALADO -> DESCARGAR
# ============================================================

if (-not $ExistingExe) {

    Write-Log "Descargando AnyDesk desde el sitio oficial..."

    try {

        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12

        Invoke-WebRequest `
            -Uri $DownloadUrl `
            -OutFile $Installer `
            -UseBasicParsing

    }
    catch {

        Write-Log `
            "Error descargando AnyDesk: $($_.Exception.Message)" `
            "ERROR"

        exit 20
    }


    if (-not (Test-Path $Installer)) {

        Write-Log `
            "No se encontro el instalador descargado." `
            "ERROR"

        exit 21
    }


    $DownloadedFile = Get-Item $Installer

    if ($DownloadedFile.Length -lt 1MB) {

        Write-Log `
            "El archivo descargado parece invalido. Tamaño: $($DownloadedFile.Length) bytes." `
            "ERROR"

        exit 22
    }


    Write-Log `
        ("Descarga completada. Tamaño: {0:N2} MB" -f `
        ($DownloadedFile.Length / 1MB)) `
        "OK"


    # ========================================================
    # VALIDAR FIRMA DIGITAL
    # ========================================================

    Write-Log "Validando firma digital del instalador..."

    $Signature = Get-AuthenticodeSignature $Installer

    if ($Signature.Status -ne "Valid") {

        Write-Log `
            "La firma digital del instalador no es valida. Estado: $($Signature.Status)" `
            "ERROR"

        Remove-Item `
            $Installer `
            -Force `
            -ErrorAction SilentlyContinue

        exit 23
    }


    Write-Log `
        "Firma digital valida: $($Signature.SignerCertificate.Subject)" `
        "OK"


    # ========================================================
    # INSTALAR
    # ========================================================

    Write-Log "Iniciando instalacion silenciosa..."

    try {

        $Arguments = @(
            "--install",
            "`"$InstallDir`"",
            "--start-with-win",
            "--silent"
        )


        $InstallProcess = Start-Process `
            -FilePath $Installer `
            -ArgumentList $Arguments `
            -PassThru


        # No esperamos indefinidamente porque estamos
        # trabajando potencialmente desde AnyDesk.

        $InstallProcess |
            Wait-Process `
                -Timeout 60 `
                -ErrorAction SilentlyContinue

    }
    catch {

        Write-Log `
            "Error ejecutando el instalador: $($_.Exception.Message)" `
            "ERROR"

        exit 24
    }


    # ========================================================
    # ESPERAR INSTALACION
    # ========================================================

    Write-Log "Esperando que aparezca la instalacion..."

    $Timeout = 60
    $Elapsed = 0

    while (
        -not (Test-Path $DefaultInstalledExe) -and
        $Elapsed -lt $Timeout
    ) {

        Start-Sleep -Seconds 2

        $Elapsed += 2
    }


    $Script:AnyDeskExe = Find-AnyDeskExecutable


    if (-not $Script:AnyDeskExe) {

        Write-Log `
            "AnyDesk no fue localizado despues de la instalacion." `
            "ERROR"

        exit 25
    }


    Write-Log "AnyDesk instalado correctamente." "OK"
    Write-Log "Ejecutable: $Script:AnyDeskExe"
}


# ============================================================
# SERVICIO
# ============================================================

Write-Log "Verificando servicio AnyDesk..."

$Service = Get-Service `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue


if ($Service) {

    Write-Log "Servicio AnyDesk detectado." "OK"
    Write-Log "Estado actual: $($Service.Status)"


    # Configuramos automatico sin reiniciar.

    try {

        Set-Service `
            -Name "AnyDesk" `
            -StartupType Automatic

        Write-Log `
            "Inicio automatico configurado." `
            "OK"

    }
    catch {

        Write-Log `
            "No fue posible configurar StartupType: $($_.Exception.Message)" `
            "WARN"
    }


    if ($Service.Status -ne "Running") {

        Write-Log `
            "El servicio esta detenido. Se iniciara." `
            "WARN"

        try {

            Start-Service -Name "AnyDesk"

            $Service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(30)
            )

            Write-Log `
                "Servicio AnyDesk iniciado." `
                "OK"

        }
        catch {

            Write-Log `
                "No fue posible iniciar el servicio: $($_.Exception.Message)" `
                "ERROR"

            exit 30
        }

    }
    else {

        Write-Log `
            "Servicio ya se encuentra Running. NO se reiniciara." `
            "OK"
    }

}
else {

    Write-Log `
        "No se encontro el servicio AnyDesk." `
        "WARN"
}


# ============================================================
# CONFIGURAR PASSWORD ACCESO DESATENDIDO
# ============================================================

Write-Log "Configurando acceso desatendido..."

try {

    # No usamos Start-Process porque necesitamos enviar
    # el password por STDIN.

    $UnattendedPassword |
        & $Script:AnyDeskExe `
            --set-password `
            _unattended_access


    $PasswordExitCode = $LASTEXITCODE


    if (
        $null -ne $PasswordExitCode -and
        $PasswordExitCode -ne 0
    ) {

        Write-Log `
            "AnyDesk devolvio codigo $PasswordExitCode al configurar la password." `
            "WARN"

    }
    else {

        Write-Log `
            "Password de acceso desatendido configurada." `
            "OK"
    }

}
catch {

    Write-Log `
        "Error configurando acceso desatendido: $($_.Exception.Message)" `
        "ERROR"

    exit 40
}


# ============================================================
# ESPERAR REGISTRO
# ============================================================

Write-Log "Esperando registro de AnyDesk..."

Start-Sleep -Seconds 5


# ============================================================
# OBTENER ID FINAL
# ============================================================

for ($Attempt = 1; $Attempt -le 12; $Attempt++) {

    $Script:NewID = Get-AnyDeskID `
        -Executable $Script:AnyDeskExe

    if ($Script:NewID) {
        break
    }


    Write-Log `
        "Esperando ID AnyDesk. Intento $Attempt/12..."

    Start-Sleep -Seconds 5
}


# ============================================================
# DATOS FINALES
# ============================================================

$Version = Get-AnyDeskVersion `
    -Executable $Script:AnyDeskExe

$Alias = Get-AnyDeskAlias `
    -Executable $Script:AnyDeskExe

$Status = Get-AnyDeskStatus `
    -Executable $Script:AnyDeskExe

$Service = Get-Service `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue


# ============================================================
# COMPARAR ID
# ============================================================

$IDResult = "No comparable"


if ($Script:OldID -and $Script:NewID) {

    if ($Script:OldID -eq $Script:NewID) {

        $IDResult = "SIN CAMBIOS"

        Write-Log `
            "El ID AnyDesk se mantuvo: $Script:NewID" `
            "OK"

    }
    else {

        $IDResult = "CAMBIO DE ID"

        Write-Log `
            "ATENCION: el ID AnyDesk cambio." `
            "WARN"

        Write-Log `
            "ID anterior: $Script:OldID" `
            "WARN"

        Write-Log `
            "ID nuevo: $Script:NewID" `
            "WARN"
    }

}


# ============================================================
# RESULTADO
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " RESULTADO DEPLOY ANYDESK"
Write-Host "============================================================"
Write-Host ""

Write-Host ("Equipo            : {0}" -f $env:COMPUTERNAME)
Write-Host ("Ejecutable        : {0}" -f $Script:AnyDeskExe)
Write-Host ("Version           : {0}" -f $Version)

if ($Service) {
    Write-Host ("Servicio          : {0}" -f $Service.Status)
}
else {
    Write-Host "Servicio          : NO ENCONTRADO"
}

if ($Script:OldID) {
    Write-Host ("ID anterior       : {0}" -f $Script:OldID)
}
else {
    Write-Host "ID anterior       : No disponible"
}

if ($Script:NewID) {
    Write-Host ("ID actual         : {0}" -f $Script:NewID)
}
else {
    Write-Host "ID actual         : No disponible"
}

if ($Alias) {
    Write-Host ("Alias             : {0}" -f $Alias)
}
else {
    Write-Host "Alias             : No configurado"
}

Write-Host ("Estado AnyDesk    : {0}" -f $Status)
Write-Host ("Comparacion ID    : {0}" -f $IDResult)
Write-Host ("Acceso desatendido: CONFIGURADO")
Write-Host ("Log               : {0}" -f $LogFile)

Write-Host ""
Write-Host "============================================================"


# ============================================================
# VALIDACION FINAL
# ============================================================

$DeploymentOK = $true


if (-not $Script:NewID) {

    Write-Log `
        "No se pudo obtener un ID AnyDesk final." `
        "WARN"

    $DeploymentOK = $false
}


if (-not $Service) {

    Write-Log `
        "No se encontro el servicio AnyDesk al finalizar." `
        "WARN"

    $DeploymentOK = $false

}
elseif ($Service.Status -ne "Running") {

    Write-Log `
        "El servicio AnyDesk no esta Running." `
        "WARN"

    $DeploymentOK = $false
}


if ($DeploymentOK) {

    Write-Host ""
    Write-Host "DEPLOY FINALIZADO CORRECTAMENTE" `
        -ForegroundColor Green

    if ($Script:NewID) {

        Write-Host ""
        Write-Host "AnyDesk ID: $Script:NewID" `
            -ForegroundColor Green
    }

    Write-Host ""

    Write-Log `
        "Deployment finalizado correctamente." `
        "OK"

}
else {

    Write-Host ""
    Write-Host "DEPLOY FINALIZADO CON ADVERTENCIAS" `
        -ForegroundColor Yellow

    Write-Host "Revise: $LogFile"
    Write-Host ""

    Write-Log `
        "Deployment finalizado con advertencias." `
        "WARN"
}


# ============================================================
# LIMPIEZA
# ============================================================

if (Test-Path $Installer) {

    Remove-Item `
        $Installer `
        -Force `
        -ErrorAction SilentlyContinue
}


Write-Log "Fin del script."

Write-Host ""
Write-Host "IMPORTANTE:"
Write-Host "No se detuvo ni reinicio deliberadamente el servicio AnyDesk."
Write-Host "Esto permite preservar la sesion remota existente."
Write-Host ""


if ($DeploymentOK) {
    exit 0
}
else {
    exit 1
}
