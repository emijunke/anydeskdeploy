#requires -version 5.1

<#
.SYNOPSIS
    Desinstalacion automatizada de AnyDesk.

.DESCRIPTION
    - Requiere PowerShell como Administrador.
    - Detecta AnyDesk instalado.
    - Obtiene ID y version antes de desinstalar.
    - Detecta servicio y procesos.
    - Advierte que una sesion AnyDesk activa sera desconectada.
    - Ejecuta la desinstalacion silenciosa.
    - Verifica el resultado.
    - Genera log en C:\ProgramData\AnyDeskDeploy.
    - Opcionalmente elimina datos residuales con -RemoveData.

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

$LogDir  = "C:\ProgramData\AnyDeskDeploy"
$LogFile = Join-Path $LogDir "AnyDesk_Uninstall.log"

New-Item `
    -ItemType Directory `
    -Path $LogDir `
    -Force | Out-Null


# ============================================================
# FUNCIONES
# ============================================================

function Write-Log {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO","OK","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Timestamp] [$Level] $Message"

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

    $Identity = `
        [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Find-AnyDeskExecutable {

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

    if ($env:LOCALAPPDATA) {

        $Paths += Join-Path `
            $env:LOCALAPPDATA `
            "AnyDesk\AnyDesk.exe"
    }


    foreach ($Path in $Paths) {

        if (Test-Path $Path) {
            return $Path
        }
    }


    $Processes = Get-Process `
        -Name "AnyDesk" `
        -ErrorAction SilentlyContinue


    foreach ($Process in $Processes) {

        try {

            if (
                $Process.Path -and
                (Test-Path $Process.Path)
            ) {

                return $Process.Path
            }

        }
        catch {
        }
    }


    return $null
}


function Get-AnyDeskID {

    param (
        [string]$Executable
    )

    try {

        return (
            & $Executable --get-id 2>$null |
            Out-String
        ).Trim()

    }
    catch {

        return $null
    }
}


function Get-AnyDeskVersion {

    param (
        [string]$Executable
    )

    try {

        $Version = (
            & $Executable --version 2>$null |
            Out-String
        ).Trim()

        if ($Version) {
            return $Version
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

        return "No disponible"
    }
}


# ============================================================
# INICIO
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " ANYDESK - DESINSTALACION AUTOMATICA"
Write-Host "============================================================"
Write-Host ""

Write-Log "Inicio de desinstalacion."
Write-Log "Equipo: $env:COMPUTERNAME"
Write-Log "Usuario: $env:USERDOMAIN\$env:USERNAME"


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
# LOCALIZAR ANYDESK
# ============================================================

Write-Log "Buscando AnyDesk..."

$AnyDeskExe = Find-AnyDeskExecutable


if (-not $AnyDeskExe) {

    Write-Log `
        "No se encontro una instalacion de AnyDesk." `
        "WARN"

    Write-Host ""
    Write-Host "AnyDesk no parece estar instalado."
    Write-Host ""

    exit 0
}


Write-Log `
    "AnyDesk encontrado: $AnyDeskExe" `
    "OK"


# ============================================================
# INFORMACION PREVIA
# ============================================================

$AnyDeskID = Get-AnyDeskID `
    -Executable $AnyDeskExe

$Version = Get-AnyDeskVersion `
    -Executable $AnyDeskExe


if ($AnyDeskID) {
    Write-Log "AnyDesk ID: $AnyDeskID"
}

Write-Log "Version: $Version"


# ============================================================
# SERVICIO Y PROCESOS
# ============================================================

$Service = Get-Service `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue

$Processes = Get-Process `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue


if ($Service) {

    Write-Log `
        "Servicio AnyDesk: $($Service.Status)"
}


if ($Processes) {

    Write-Log `
        "Se detectaron procesos AnyDesk activos." `
        "WARN"
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
Write-Host "La desinstalacion detendra AnyDesk."
Write-Host ""
Write-Host "Si esta conectado a este equipo mediante AnyDesk,"
Write-Host "LA SESION REMOTA SE DESCONECTARA."
Write-Host ""

if ($AnyDeskID) {
    Write-Host "AnyDesk ID actual: $AnyDeskID"
}

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
# DESINSTALACION
# ============================================================

Write-Log "Iniciando desinstalacion de AnyDesk..."


try {

    $Arguments = @(
        "--remove"
        "--silent"
    )


    $Process = Start-Process `
        -FilePath $AnyDeskExe `
        -ArgumentList $Arguments `
        -PassThru


    try {

        $Process |
            Wait-Process `
                -Timeout 60 `
                -ErrorAction Stop

    }
    catch {

        Write-Log `
            "El proceso de desinstalacion continua o finalizo cerrando AnyDesk." `
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
# ESPERAR
# ============================================================

Write-Log "Esperando finalizacion..."

Start-Sleep -Seconds 10


# ============================================================
# VERIFICACION
# ============================================================

$ServiceAfter = Get-Service `
    -Name "AnyDesk" `
    -ErrorAction SilentlyContinue

$ExeAfter = Find-AnyDeskExecutable


if (
    -not $ServiceAfter -and
    -not $ExeAfter
) {

    Write-Log `
        "AnyDesk fue desinstalado correctamente." `
        "OK"

}
else {

    Write-Log `
        "Todavia se detectan componentes de AnyDesk." `
        "WARN"

    if ($ServiceAfter) {

        Write-Log `
            "Servicio detectado: $($ServiceAfter.Status)" `
            "WARN"
    }

    if ($ExeAfter) {

        Write-Log `
            "Ejecutable detectado: $ExeAfter" `
            "WARN"
    }
}


# ============================================================
# ELIMINAR DATOS - OPCIONAL
# ============================================================

if ($RemoveData) {

    Write-Log `
        "RemoveData habilitado. Eliminando datos residuales..." `
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
        "Se conservaron los datos/configuracion de AnyDesk."

    Write-Log `
        "Use -RemoveData si desea eliminar tambien la configuracion." `
        "INFO"
}


# ============================================================
# RESULTADO
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " RESULTADO"
Write-Host "============================================================"
Write-Host ""

Write-Host "Equipo       : $env:COMPUTERNAME"
Write-Host "Version      : $Version"

if ($AnyDeskID) {
    Write-Host "AnyDesk ID   : $AnyDeskID"
}

if (-not $ServiceAfter -and -not $ExeAfter) {

    Write-Host "Estado       : DESINSTALADO" `
        -ForegroundColor Green

}
else {

    Write-Host "Estado       : REVISAR" `
        -ForegroundColor Yellow
}

Write-Host "RemoveData   : $RemoveData"
Write-Host "Log          : $LogFile"

Write-Host ""
Write-Host "============================================================"

Write-Log "Fin del procedimiento."


if (-not $ServiceAfter -and -not $ExeAfter) {
    exit 0
}
else {
    exit 1
}
