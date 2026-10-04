#requires -version 5.1

<#
.SYNOPSIS
    Desinstalacion automatizada de AnyDesk.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Distingue entre AnyDesk instalado y AnyDesk portable.
    - Detecta el servicio AnyDesk.
    - Localiza la instalacion persistente.
    - Obtiene ID y version antes de desinstalar.
    - Desinstala la instalacion persistente.
    - Verifica que el servicio haya desaparecido.
    - NO elimina un AnyDesk portable externo por defecto.
    - Opcionalmente elimina configuracion residual con -RemoveData.
    - Genera log en C:\ProgramData\AnyDeskDeploy.

.EXAMPLE
    .\Uninstall-AnyDesk.ps1

.EXAMPLE
    .\Uninstall-AnyDesk.ps1 -Force

.EXAMPLE
    .\Uninstall-AnyDesk.ps1 -Force -RemoveData
#>

[CmdletBinding()]
param (
    [switch]$Force,
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"


# ============================================================
# CONFIGURACION
# ============================================================

$LogDir = "C:\ProgramData\AnyDeskDeploy"

$LogFile = Join-Path `
    $LogDir `
    "AnyDesk_Uninstall.log"


$Script:InstalledExe = $null
$Script:PortableExe  = $null
$Script:AnyDeskID    = $null


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


    # Si no esta en las rutas estandar, intentar obtener
    # el ejecutable desde el servicio.

    try {

        $ServiceCIM = Get-CimInstance `
            Win32_Service `
            -Filter "Name='AnyDesk'" `
            -ErrorAction SilentlyContinue


        if ($ServiceCIM -and $ServiceCIM.PathName) {

            $ServicePath = $ServiceCIM.PathName.Trim()


            if ($ServicePath.StartsWith('"')) {

                $ServicePath = `
                    ($ServicePath -split '"')[1]

            }
            else {

                $ServicePath = `
                    ($ServicePath -split '\s+')[0]
            }


            if (
                $ServicePath -and
                (Test-Path $ServicePath)
            ) {

                return $ServicePath
            }
        }

    }
    catch {
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


                $IsInstalledPath = $false


                if ($env:ProgramFiles) {

                    if (
                        $Path -like `
                        "$env:ProgramFiles\AnyDesk\*"
                    ) {

                        $IsInstalledPath = $true
                    }
                }


                if (${env:ProgramFiles(x86)}) {

                    if (
                        $Path -like `
                        "${env:ProgramFiles(x86)}\AnyDesk\*"
                    ) {

                        $IsInstalledPath = $true
                    }
                }


                if (-not $IsInstalledPath) {

                    return $Path
                }
            }

        }
        catch {
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



# ============================================================
# PREPARACION
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $LogDir `
    -Force |
    Out-Null


Write-Host ""
Write-Host "============================================================"
Write-Host " ANYDESK - DESINSTALACION AUTOMATICA"
Write-Host "============================================================"
Write-Host ""


Write-Log `
    "Inicio de desinstalacion."


Write-Log `
    "Equipo: $env:COMPUTERNAME"


Write-Log `
    "Usuario: $env:USERDOMAIN\$env:USERNAME"



# ============================================================
# VALIDAR ADMINISTRADOR
# ============================================================

if (-not (Test-Administrator)) {

    Write-Log `
        "PowerShell debe ejecutarse como Administrador." `
        "ERROR"


    exit 10
}


Write-Log `
    "Privilegios de administrador confirmados." `
    "OK"



# ============================================================
# RELEVAMIENTO
# ============================================================

Write-Log `
    "Relevando instalacion de AnyDesk..."


$Service = Get-AnyDeskService

$Script:InstalledExe = Find-InstalledAnyDesk

$Script:PortableExe = Find-PortableAnyDesk



# ============================================================
# MOSTRAR PORTABLE
# ============================================================

if ($Script:PortableExe) {

    Write-Log `
        "AnyDesk PORTABLE detectado." `
        "WARN"


    Write-Log `
        "Portable: $Script:PortableExe"


    Write-Log `
        "El archivo portable NO sera eliminado." `
        "INFO"
}



# ============================================================
# VALIDAR INSTALACION PERSISTENTE
# ============================================================

if (-not $Service) {

    Write-Log `
        "No se encontro el servicio AnyDesk." `
        "WARN"


    if ($Script:PortableExe) {

        Write-Host ""
        Write-Host "Solo se detecto una instancia PORTABLE."
        Write-Host ""
        Write-Host "Portable:"
        Write-Host $Script:PortableExe
        Write-Host ""
        Write-Host "No existe una instalacion persistente para desinstalar."
        Write-Host ""
        Write-Host "El portable NO sera cerrado ni eliminado."
        Write-Host ""


        Write-Log `
            "No existe instalacion persistente. No se realizan cambios." `
            "OK"


        exit 0
    }


    Write-Host ""
    Write-Host "AnyDesk no parece estar instalado."
    Write-Host ""


    Write-Log `
        "AnyDesk no esta instalado." `
        "OK"


    exit 0
}



Write-Log `
    "Servicio AnyDesk detectado." `
    "OK"


Write-Log `
    "Estado del servicio: $($Service.Status)"



# ============================================================
# VALIDAR EJECUTABLE INSTALADO
# ============================================================

if (-not $Script:InstalledExe) {

    Write-Log `
        "Existe el servicio pero no se pudo localizar AnyDesk.exe." `
        "ERROR"


    exit 11
}



Write-Log `
    "Instalacion persistente: $Script:InstalledExe" `
    "OK"



# ============================================================
# INFORMACION PREVIA
# ============================================================

$Version = Get-AnyDeskVersion `
    -Executable $Script:InstalledExe


$Script:AnyDeskID = Get-AnyDeskID `
    -Executable $Script:InstalledExe


Write-Log `
    "Version instalada: $Version"


if ($Script:AnyDeskID) {

    Write-Log `
        "AnyDesk ID: $Script:AnyDeskID" `
        "OK"
}



# ============================================================
# INFORMACION DEL SERVICIO
# ============================================================

$ServiceCIM = Get-CimInstance `
    Win32_Service `
    -Filter "Name='AnyDesk'" `
    -ErrorAction SilentlyContinue


if ($ServiceCIM) {

    Write-Log `
        "StartupType: $($ServiceCIM.StartMode)"


    Write-Log `
        "Servicio ejecutable: $($ServiceCIM.PathName)"
}



# ============================================================
# ADVERTENCIA
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Yellow

Write-Host " ADVERTENCIA" `
    -ForegroundColor Yellow

Write-Host "============================================================" `
    -ForegroundColor Yellow

Write-Host ""

Write-Host `
    "Se va a desinstalar la instalacion persistente de AnyDesk."

Write-Host ""

Write-Host `
    "Ejecutable instalado: $Script:InstalledExe"

Write-Host `
    "Version: $Version"


if ($Script:AnyDeskID) {

    Write-Host `
        "AnyDesk ID: $Script:AnyDeskID"
}


Write-Host ""


if ($Script:PortableExe) {

    Write-Host `
        "Tambien existe una instancia portable:"

    Write-Host `
        $Script:PortableExe

    Write-Host ""

    Write-Host `
        "El portable NO sera eliminado."

    Write-Host ""
}


Write-Host `
    "La desinstalacion detendra el servicio AnyDesk." `
    -ForegroundColor Yellow


Write-Host ""

Write-Host `
    "Si la conexion actual depende de ese servicio," `
    -ForegroundColor Yellow

Write-Host `
    "LA SESION REMOTA PUEDE DESCONECTARSE." `
    -ForegroundColor Yellow

Write-Host ""



# ============================================================
# CONFIRMACION
# ============================================================

if (-not $Force) {

    $Confirmation = Read-Host `
        "Escriba DESINSTALAR para continuar"


    if ($Confirmation -cne "DESINSTALAR") {

        Write-Log `
            "Desinstalacion cancelada por el usuario." `
            "WARN"


        Write-Host ""
        Write-Host "Operacion cancelada."
        Write-Host ""


        exit 0
    }

}
else {

    Write-Log `
        "Modo -Force habilitado. Se omite confirmacion." `
        "WARN"
}



# ============================================================
# DESINSTALAR
# ============================================================

Write-Log `
    "Iniciando desinstalacion de AnyDesk..."


try {

    $Arguments = @(
        "--remove",
        "--silent"
    )


    $UninstallProcess = Start-Process `
        -FilePath $Script:InstalledExe `
        -ArgumentList $Arguments `
        -PassThru


    Write-Log `
        "Proceso de desinstalacion iniciado. PID: $($UninstallProcess.Id)"


    try {

        $UninstallProcess |
            Wait-Process `
                -Timeout 60 `
                -ErrorAction Stop

    }
    catch {

        Write-Log `
            "El proceso de desinstalacion continua o excedio el tiempo de espera." `
            "WARN"
    }

}
catch {

    Write-Log `
        "Error iniciando desinstalacion: $($_.Exception.Message)" `
        "ERROR"


    exit 20
}



# ============================================================
# ESPERAR DESAPARICION DEL SERVICIO
# ============================================================

Write-Log `
    "Esperando eliminacion del servicio AnyDesk..."


$Timeout = 90

$Elapsed = 0


do {

    Start-Sleep -Seconds 2

    $Elapsed += 2

    $ServiceAfter = Get-AnyDeskService

}
while (
    $ServiceAfter -and
    $Elapsed -lt $Timeout
)



# ============================================================
# VERIFICACION
# ============================================================

$ServiceAfter = Get-AnyDeskService

$InstalledExeAfter = Find-InstalledAnyDesk



if (-not $ServiceAfter) {

    Write-Log `
        "Servicio AnyDesk eliminado." `
        "OK"

}
else {

    Write-Log `
        "El servicio AnyDesk todavia existe." `
        "ERROR"
}



if ($InstalledExeAfter) {

    Write-Log `
        "Todavia existe ejecutable instalado: $InstalledExeAfter" `
        "WARN"

}
else {

    Write-Log `
        "Ejecutable de instalacion persistente eliminado." `
        "OK"
}



# ============================================================
# REMOVE DATA OPCIONAL
# ============================================================

if ($RemoveData) {

    Write-Log `
        "RemoveData habilitado." `
        "WARN"


    Write-Log `
        "Se eliminaran configuraciones residuales de AnyDesk." `
        "WARN"


    $ResidualPaths = @(
        "$env:ProgramData\AnyDesk",
        "$env:APPDATA\AnyDesk",
        "$env:LOCALAPPDATA\AnyDesk"
    )


    foreach ($Path in $ResidualPaths) {

        if (Test-Path $Path) {

            try {

                Remove-Item `
                    -Path $Path `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop


                Write-Log `
                    "Eliminado: $Path" `
                    "OK"

            }
            catch {

                Write-Log `
                    "No se pudo eliminar $Path : $($_.Exception.Message)" `
                    "WARN"
            }
        }
    }

}
else {

    Write-Log `
        "Configuracion residual conservada."


    Write-Log `
        "Use -RemoveData para eliminar tambien configuraciones."
}



# ============================================================
# COMPROBAR PORTABLE DESPUES
# ============================================================

$PortableAfter = Find-PortableAnyDesk


if ($PortableAfter) {

    Write-Log `
        "La instancia portable continua presente: $PortableAfter" `
        "OK"
}



# ============================================================
# RESULTADO
# ============================================================

$UninstallOK = $true


if ($ServiceAfter) {

    $UninstallOK = $false
}



Write-Host ""
Write-Host "============================================================"
Write-Host " RESULTADO DESINSTALACION ANYDESK"
Write-Host "============================================================"
Write-Host ""


Write-Host `
    ("Equipo              : {0}" -f $env:COMPUTERNAME)


Write-Host `
    ("Version anterior    : {0}" -f $Version)


if ($Script:AnyDeskID) {

    Write-Host `
        ("AnyDesk ID anterior: {0}" -f $Script:AnyDeskID)
}


if ($ServiceAfter) {

    Write-Host `
        "Servicio           : TODAVIA EXISTE"

}
else {

    Write-Host `
        "Servicio           : ELIMINADO"
}


if ($InstalledExeAfter) {

    Write-Host `
        ("Ejecutable        : {0}" -f $InstalledExeAfter)

}
else {

    Write-Host `
        "Ejecutable        : ELIMINADO"
}


if ($PortableAfter) {

    Write-Host `
        ("Portable          : {0}" -f $PortableAfter)

}
else {

    Write-Host `
        "Portable          : No detectado"
}


Write-Host `
    ("RemoveData          : {0}" -f $RemoveData)


Write-Host `
    ("Log                 : {0}" -f $LogFile)


Write-Host ""
Write-Host "============================================================"



# ============================================================
# FINAL
# ============================================================

if ($UninstallOK) {

    Write-Host ""
    Write-Host `
        "ANYDESK DESINSTALADO CORRECTAMENTE" `
        -ForegroundColor Green


    if ($PortableAfter) {

        Write-Host ""
        Write-Host `
            "La instancia portable NO fue eliminada." `
            -ForegroundColor Yellow
    }


    Write-Host ""


    Write-Log `
        "Desinstalacion finalizada correctamente." `
        "OK"

}
else {

    Write-Host ""
    Write-Host `
        "DESINSTALACION FINALIZADA CON ERRORES" `
        -ForegroundColor Red


    Write-Host `
        "Revise: $LogFile"


    Write-Host ""


    Write-Log `
        "Desinstalacion finalizada con errores." `
        "ERROR"
}



Write-Log `
    "Fin del script."


if ($UninstallOK) {

    exit 0

}
else {

    exit 1
}
