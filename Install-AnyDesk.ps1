#requires -version 5.1

<#
.SYNOPSIS
    Instalacion/configuracion automatizada de AnyDesk.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Detecta si AnyDesk esta instalado como servicio.
    - Detecta una instancia portable existente.
    - Si existe AnyDesk portable pero no servicio:
        * preserva la instancia portable;
        * descarga AnyDesk;
        * realiza instalacion persistente;
        * verifica la creacion del servicio.
    - NO detiene ni reinicia deliberadamente una instancia AnyDesk activa.
    - Configura el servicio como Automatic.
    - Configura acceso desatendido.
    - Obtiene ID, alias, version y estado.
    - Genera log en C:\ProgramData\AnyDeskDeploy.

.EXAMPLE
    .\Install-AnyDesk.ps1

.EXAMPLE
    .\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD'
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$UnattendedPassword
)

$ErrorActionPreference = "Stop"


# ============================================================
# PASSWORD
# ============================================================

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


$DefaultInstalledExe = Join-Path `
    $InstallDir `
    "AnyDesk.exe"


$TempDir = Join-Path `
    $env:TEMP `
    "AnyDeskDeploy"


$Installer = Join-Path `
    $TempDir `
    "AnyDesk.exe"


$LogDir = "C:\ProgramData\AnyDeskDeploy"

$LogFile = Join-Path `
    $LogDir `
    "AnyDesk_Deploy.log"


$Script:PortableExe   = $null
$Script:InstalledExe  = $null
$Script:OldID         = $null
$Script:NewID         = $null


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

            Write-Host `
                $Line `
                -ForegroundColor Green
        }

        "WARN" {

            Write-Host `
                $Line `
                -ForegroundColor Yellow
        }

        "ERROR" {

            Write-Host `
                $Line `
                -ForegroundColor Red
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

    $Identity = `
        [Security.Principal.WindowsIdentity]::GetCurrent()


    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)


    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}



function Get-AnyDeskService {

    return Get-Service `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue
}



function Find-InstalledAnyDesk {

    $Paths = @()


    if (${env:ProgramFiles(x86)}) {

        $Paths += Join-Path `
            ${env:ProgramFiles(x86)} `
            "AnyDesk\AnyDesk.exe"
    }


    if ($env:ProgramFiles) {

        $Paths += Join-Path `
            $env:ProgramFiles `
            "AnyDesk\AnyDesk.exe"
    }


    foreach ($Path in $Paths) {

        if (Test-Path $Path) {

            return $Path
        }
    }


    return $null
}



function Find-PortableAnyDesk {

    $Processes = Get-Process `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue


    foreach ($Process in $Processes) {

        try {

            if (
                $Process.Path -and
                (Test-Path $Process.Path)
            ) {

                $Path = $Process.Path


                if (
                    $Path -notlike "$env:ProgramFiles\AnyDesk\*" -and
                    (
                        -not ${env:ProgramFiles(x86)} -or
                        $Path -notlike "${env:ProgramFiles(x86)}\AnyDesk\*"
                    )
                ) {

                    return $Path
                }
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

        $Result = (
            & $Executable --get-id 2>$null |
            Out-String
        ).Trim()


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

        $Result = (
            & $Executable --get-alias 2>$null |
            Out-String
        ).Trim()


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

        $Result = (
            & $Executable --get-status 2>$null |
            Out-String
        ).Trim()


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

        $Result = (
            & $Executable --version 2>$null |
            Out-String
        ).Trim()


        if ($Result) {

            return $Result
        }

    }
    catch {
    }


    try {

        return (
            Get-Item $Executable
        ).VersionInfo.FileVersion

    }
    catch {
    }


    return "No disponible"
}



function Wait-AnyDeskService {

    param (

        [int]$TimeoutSeconds = 90
    )


    $Elapsed = 0


    while ($Elapsed -lt $TimeoutSeconds) {

        $Service = Get-AnyDeskService


        if ($Service) {

            return $Service
        }


        Start-Sleep -Seconds 2

        $Elapsed += 2
    }


    return $null
}



# ============================================================
# PREPARACION
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $LogDir `
    -Force |
    Out-Null


New-Item `
    -ItemType Directory `
    -Path $TempDir `
    -Force |
    Out-Null


Write-Host ""
Write-Host "============================================================"
Write-Host " ANYDESK - DEPLOY AUTOMATICO"
Write-Host "============================================================"
Write-Host ""


Write-Log "Inicio del deployment."

Write-Log `
    "Equipo: $env:COMPUTERNAME"

Write-Log `
    "Usuario: $env:USERDOMAIN\$env:USERNAME"



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


Write-Log `
    "Privilegios de administrador confirmados." `
    "OK"



# ============================================================
# VALIDAR PASSWORD
# ============================================================

if (
    [string]::IsNullOrWhiteSpace($UnattendedPassword) -or
    $UnattendedPassword.Length -lt 8
) {

    Write-Log `
        "La password de acceso desatendido debe tener al menos 8 caracteres." `
        "ERROR"


    exit 11
}


Write-Log `
    "Password de acceso desatendido recibida."


Write-Log `
    "La password NO sera escrita en el log."



# ============================================================
# RELEVAMIENTO INICIAL
# ============================================================

Write-Log `
    "Relevando estado actual de AnyDesk..."


$InitialService = Get-AnyDeskService

$Script:InstalledExe = Find-InstalledAnyDesk

$Script:PortableExe = Find-PortableAnyDesk



# ============================================================
# ANYDESK PORTABLE
# ============================================================

if ($Script:PortableExe) {

    Write-Log `
        "AnyDesk PORTABLE detectado." `
        "WARN"


    Write-Log `
        "Portable: $Script:PortableExe"


    $PortableVersion = Get-AnyDeskVersion `
        -Executable $Script:PortableExe


    Write-Log `
        "Version portable: $PortableVersion"


    $Script:OldID = Get-AnyDeskID `
        -Executable $Script:PortableExe


    if ($Script:OldID) {

        Write-Log `
            "ID AnyDesk actual: $Script:OldID" `
            "OK"
    }


    Write-Log `
        "La instancia portable NO sera detenida." `
        "WARN"


    Write-Log `
        "Esto permite preservar la sesion remota actual." `
        "INFO"
}



# ============================================================
# INSTALACION EXISTENTE
# ============================================================

if ($InitialService) {

    Write-Log `
        "Servicio AnyDesk detectado." `
        "OK"


    Write-Log `
        "Estado inicial del servicio: $($InitialService.Status)"


    if ($Script:InstalledExe) {

        Write-Log `
            "Instalacion persistente: $Script:InstalledExe" `
            "OK"


        if (-not $Script:OldID) {

            $Script:OldID = Get-AnyDeskID `
                -Executable $Script:InstalledExe
        }

    }

}
else {

    Write-Log `
        "No existe servicio AnyDesk." `
        "WARN"


    if ($Script:PortableExe) {

        Write-Log `
            "Se realizara instalacion persistente sin detener el portable." `
            "WARN"

    }
    else {

        Write-Log `
            "AnyDesk no esta instalado. Se realizara instalacion."
    }
}



# ============================================================
# INSTALAR SI NO EXISTE SERVICIO
# ============================================================

if (-not $InitialService) {

    # ========================================================
    # DESCARGA
    # ========================================================

    Write-Log `
        "Descargando AnyDesk desde el sitio oficial..."


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
    # FIRMA DIGITAL
    # ========================================================

    Write-Log `
        "Validando firma digital del instalador..."


    $Signature = Get-AuthenticodeSignature `
        $Installer


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
    # INSTALACION
    # ========================================================

    Write-Log `
        "Iniciando instalacion persistente de AnyDesk..."


    if ($Script:PortableExe) {

        Write-Log `
            "IMPORTANTE: no se detendra $Script:PortableExe" `
            "WARN"
    }


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


        Write-Log `
            "Proceso de instalacion iniciado. PID: $($InstallProcess.Id)"


        try {

            $InstallProcess |
                Wait-Process `
                    -Timeout 60 `
                    -ErrorAction Stop

        }
        catch {

            Write-Log `
                "El instalador continua ejecutandose o excedio el tiempo de espera." `
                "WARN"
        }

    }
    catch {

        Write-Log `
            "Error ejecutando el instalador: $($_.Exception.Message)" `
            "ERROR"


        exit 24
    }



    # ========================================================
    # ESPERAR SERVICIO
    # ========================================================

    Write-Log `
        "Esperando creacion del servicio AnyDesk..."


    $Service = Wait-AnyDeskService `
        -TimeoutSeconds 90


    if (-not $Service) {

        Write-Log `
            "No se creo el servicio AnyDesk despues de la instalacion." `
            "ERROR"


        Write-Log `
            "La instancia portable, si existia, NO fue detenida." `
            "WARN"


        exit 25
    }



    Write-Log `
        "Servicio AnyDesk creado correctamente." `
        "OK"


    $Script:InstalledExe = Find-InstalledAnyDesk


    if (-not $Script:InstalledExe) {

        Write-Log `
            "El servicio existe pero no se encontro el ejecutable instalado." `
            "ERROR"


        exit 26
    }



    Write-Log `
        "AnyDesk instalado en: $Script:InstalledExe" `
        "OK"

}



# ============================================================
# LOCALIZAR EJECUTABLE PERSISTENTE
# ============================================================

if (-not $Script:InstalledExe) {

    $Script:InstalledExe = Find-InstalledAnyDesk
}


if (-not $Script:InstalledExe) {

    Write-Log `
        "No fue posible localizar el AnyDesk instalado." `
        "ERROR"


    exit 27
}



# ============================================================
# SERVICIO
# ============================================================

Write-Log `
    "Verificando servicio AnyDesk..."


$Service = Get-AnyDeskService


if (-not $Service) {

    Write-Log `
        "No se encontro el servicio AnyDesk." `
        "ERROR"


    exit 30
}



Write-Log `
    "Servicio AnyDesk detectado." `
    "OK"


Write-Log `
    "Estado actual: $($Service.Status)"



# ============================================================
# STARTUP AUTOMATIC
# ============================================================

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



# ============================================================
# INICIAR SERVICIO SOLO SI ESTA DETENIDO
# ============================================================

$Service.Refresh()


if ($Service.Status -ne "Running") {

    Write-Log `
        "El servicio esta detenido. Se iniciara." `
        "WARN"


    try {

        Start-Service `
            -Name "AnyDesk"


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


        exit 31
    }

}
else {

    Write-Log `
        "Servicio ya se encuentra Running. NO se reiniciara." `
        "OK"
}



# ============================================================
# VERIFICAR STARTUP TYPE
# ============================================================

try {

    $ServiceCIM = Get-CimInstance `
        Win32_Service `
        -Filter "Name='AnyDesk'"


    if ($ServiceCIM) {

        Write-Log `
            "StartupType servicio: $($ServiceCIM.StartMode)" `
            "OK"
    }

}
catch {

    Write-Log `
        "No se pudo consultar StartupType mediante CIM." `
        "WARN"
}



# ============================================================
# CONFIGURAR PASSWORD SOBRE INSTALACION PERSISTENTE
# ============================================================

Write-Log `
    "Configurando acceso desatendido sobre la instalacion persistente..."


Write-Log `
    "Ejecutable utilizado: $Script:InstalledExe"


try {

    $UnattendedPassword |
        & $Script:InstalledExe `
            --set-password `
            _unattended_access


    $PasswordExitCode = $LASTEXITCODE


    if (
        $null -ne $PasswordExitCode -and
        $PasswordExitCode -ne 0
    ) {

        Write-Log `
            "AnyDesk devolvio codigo $PasswordExitCode al configurar la password." `
            "ERROR"


        exit 40
    }


    Write-Log `
        "Password de acceso desatendido configurada." `
        "OK"

}
catch {

    Write-Log `
        "Error configurando acceso desatendido: $($_.Exception.Message)" `
        "ERROR"


    exit 41
}



# ============================================================
# ESPERAR REGISTRO
# ============================================================

Write-Log `
    "Esperando registro de AnyDesk..."


Start-Sleep -Seconds 5



# ============================================================
# OBTENER ID FINAL
# ============================================================

for ($Attempt = 1; $Attempt -le 12; $Attempt++) {

    $Script:NewID = Get-AnyDeskID `
        -Executable $Script:InstalledExe


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
    -Executable $Script:InstalledExe


$Alias = Get-AnyDeskAlias `
    -Executable $Script:InstalledExe


$Status = Get-AnyDeskStatus `
    -Executable $Script:InstalledExe


$Service = Get-AnyDeskService


$ServiceCIM = Get-CimInstance `
    Win32_Service `
    -Filter "Name='AnyDesk'" `
    -ErrorAction SilentlyContinue



# ============================================================
# COMPARAR ID
# ============================================================

$IDResult = "No comparable"


if (
    $Script:OldID -and
    $Script:NewID
) {

    if (
        $Script:OldID -eq
        $Script:NewID
    ) {

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
# VALIDACION FINAL
# ============================================================

$DeploymentOK = $true



if (-not $Service) {

    Write-Log `
        "No se encontro el servicio AnyDesk al finalizar." `
        "ERROR"


    $DeploymentOK = $false

}
elseif ($Service.Status -ne "Running") {

    Write-Log `
        "El servicio AnyDesk no esta Running." `
        "ERROR"


    $DeploymentOK = $false
}



if (
    $ServiceCIM -and
    $ServiceCIM.StartMode -ne "Auto"
) {

    Write-Log `
        "El servicio AnyDesk no esta configurado Automatic." `
        "WARN"


    $DeploymentOK = $false
}



if (-not $Script:NewID) {

    Write-Log `
        "No se pudo obtener un ID AnyDesk final." `
        "WARN"


    $DeploymentOK = $false
}



if (-not (Test-Path $Script:InstalledExe)) {

    Write-Log `
        "No existe el ejecutable persistente." `
        "ERROR"


    $DeploymentOK = $false
}



# ============================================================
# RESULTADO
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " RESULTADO DEPLOY ANYDESK"
Write-Host "============================================================"
Write-Host ""


Write-Host `
    ("Equipo             : {0}" -f $env:COMPUTERNAME)


Write-Host `
    ("Ejecutable         : {0}" -f $Script:InstalledExe)


Write-Host `
    ("Version            : {0}" -f $Version)



if ($Service) {

    Write-Host `
        ("Servicio           : {0}" -f $Service.Status)

}
else {

    Write-Host `
        "Servicio           : NO ENCONTRADO"
}



if ($ServiceCIM) {

    Write-Host `
        ("Inicio servicio    : {0}" -f $ServiceCIM.StartMode)

}
else {

    Write-Host `
        "Inicio servicio    : No disponible"
}



if ($Script:OldID) {

    Write-Host `
        ("ID anterior        : {0}" -f $Script:OldID)

}
else {

    Write-Host `
        "ID anterior        : No disponible"
}



if ($Script:NewID) {

    Write-Host `
        ("ID actual          : {0}" -f $Script:NewID)

}
else {

    Write-Host `
        "ID actual          : No disponible"
}



if ($Alias) {

    Write-Host `
        ("Alias              : {0}" -f $Alias)

}
else {

    Write-Host `
        "Alias              : No configurado"
}



Write-Host `
    ("Estado AnyDesk     : {0}" -f $Status)


Write-Host `
    ("Comparacion ID     : {0}" -f $IDResult)


Write-Host `
    "Acceso desatendido : CONFIGURADO"


if ($Script:PortableExe) {

    Write-Host `
        ("Portable original  : {0}" -f $Script:PortableExe)

}
else {

    Write-Host `
        "Portable original  : No detectado"
}


Write-Host `
    ("Log                : {0}" -f $LogFile)


Write-Host ""
Write-Host "============================================================"



# ============================================================
# RESULTADO FINAL
# ============================================================

if ($DeploymentOK) {

    Write-Host ""
    Write-Host `
        "DEPLOY FINALIZADO CORRECTAMENTE" `
        -ForegroundColor Green


    if ($Script:NewID) {

        Write-Host ""
        Write-Host `
            "AnyDesk ID: $Script:NewID" `
            -ForegroundColor Green
    }


    Write-Host ""


    Write-Log `
        "Deployment finalizado correctamente." `
        "OK"

}
else {

    Write-Host ""
    Write-Host `
        "DEPLOY FINALIZADO CON ADVERTENCIAS" `
        -ForegroundColor Yellow


    Write-Host `
        "Revise: $LogFile"


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



# Reducir permanencia de la password en variables.
$UnattendedPassword = $null
$SecurePassword = $null
$BSTR = [IntPtr]::Zero



Write-Log `
    "Fin del script."


Write-Host ""
Write-Host "IMPORTANTE:"
Write-Host "No se detuvo ni reinicio deliberadamente la instancia"
Write-Host "AnyDesk portable utilizada para la conexion inicial."
Write-Host ""



if ($DeploymentOK) {

    exit 0

}
else {

    exit 1
}
