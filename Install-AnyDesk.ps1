<#
.SYNOPSIS
    Instalacion desatendida de AnyDesk, sin interfaz para el usuario local.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Detecta si AnyDesk esta instalado como servicio.
    - Detecta una instancia portable existente.
    - Si existe AnyDesk portable pero no servicio:
        * preserva la instancia portable;
        * descarga AnyDesk;
        * realiza instalacion persistente;
        * verifica la creacion del servicio.
    - NO detiene ni reinicia un servicio AnyDesk que ya estuviera en ejecucion.
    - Configura el servicio como Automatic.
    - Configura acceso desatendido.
    - Oculta la aplicacion al usuario local:
        * no crea icono de escritorio ni acceso del menu Inicio;
        * no registra el inicio automatico de la ventana;
        * quita accesos directos y entradas de inicio ya existentes;
        * cierra la ventana de una instalacion nueva, conservando el servicio;
        * acepta solo conexiones con la password de acceso desatendido,
          sin mostrar la ventana de aceptar sesion.
    - Durante una sesion remota, AnyDesk sigue mostrando el marco y la barra
      de sesion. El programa sigue visible en Aplicaciones y caracteristicas.
    - Obtiene ID, alias, version y estado.
    - Genera log en C:\ProgramData\AnyDeskDeploy.

.PARAMETER UnattendedPassword
    Password de acceso desatendido. Si se omite, se solicita de forma segura.

.PARAMETER ShowUserInterface
    Conserva iconos, menu Inicio e inicio de la ventana con Windows.

.EXAMPLE
    .\Install-AnyDesk.ps1

.EXAMPLE
    .\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD'

.EXAMPLE
    .\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD' -ShowUserInterface

.EXAMPLE
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-AnyDesk.ps1" | iex

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


$SystemConfig = "C:\ProgramData\AnyDesk\system.conf"

$ServiceConfig = "C:\ProgramData\AnyDesk\service.conf"


$Script:PortableExe          = $null
$Script:InstalledExe         = $null
$Script:OldID                = $null
$Script:NewID                = $null
$Script:InitialService       = $null
$Script:RemovedShortcuts     = 0
$Script:RemovedStartupEntries = 0
$Script:ClosedGuiCount       = 0
$Script:SilentConfigApplied  = $false


# Claves oficiales de AnyDesk. interactive_access=2 equivale a
# "Never show incoming session requests": solo entra quien conoce
# la password de acceso desatendido.
$SilentConfig = @{
    "ad.security.interactive_access" = "2"
    "ad.features.discovery"          = "false"
    "ad.discovery.enabled"           = "false"
    "ad.discovery.hidden"            = "true"
    "ad.discovery.show_tile"         = "0"
}


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



function Get-AnyDeskServicePid {

    $Service = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='AnyDesk'" `
        -ErrorAction SilentlyContinue


    if ($Service -and $Service.ProcessId) {

        return [int]$Service.ProcessId
    }


    return 0
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

        if (Test-Path -LiteralPath $Path) {

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
                (Test-Path -LiteralPath $Process.Path)
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



function ConvertTo-AnyDeskIDKey {

    param (
        [string]$Id
    )


    if ([string]::IsNullOrWhiteSpace($Id)) {

        return $null
    }


    return ($Id -replace "\s", "")
}



function Read-AnyDeskConfigValue {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )


    if (-not (Test-Path -LiteralPath $Path)) {

        return $null
    }


    foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {

        $Separator = $Line.IndexOf("=")

        if ($Separator -lt 1) {

            continue
        }


        $Key = $Line.Substring(0, $Separator).Trim()

        if ($Key -eq $Name) {

            return $Line.Substring($Separator + 1).Trim()
        }
    }


    return $null
}



function Get-AnyDeskIDFromServiceConfig {

    foreach ($Path in @($SystemConfig, $ServiceConfig)) {

        $Value = Read-AnyDeskConfigValue `
            -Path $Path `
            -Name "ad.anynet.id"


        if ($Value) {

            return $Value
        }
    }


    return $null
}



function Get-AnyDeskID {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [switch]$FromInstalledService
    )


    if ($FromInstalledService) {

        $FromConfig = Get-AnyDeskIDFromServiceConfig

        if ($FromConfig) {

            return $FromConfig
        }
    }


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
            Get-Item -LiteralPath $Executable
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



function Test-PathUnderInstallDir {

    param (
        [string]$Path
    )


    if ([string]::IsNullOrWhiteSpace($Path)) {

        return $false
    }


    $Clean = $Path.Trim().Trim('"')

    if ($Clean -match '^(?:"([^"]+\.exe)"|([^\s"]+\.exe))') {

        if ($Matches[1]) {

            $Clean = $Matches[1]

        }
        else {

            $Clean = $Matches[2]
        }
    }


    $Prefix = $InstallDir.TrimEnd("\")


    return $Clean.StartsWith(
        $Prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}



function Set-AnyDeskConfigKeys {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )


    $Directory = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $Directory)) {

        New-Item `
            -ItemType Directory `
            -Path $Directory `
            -Force |
            Out-Null
    }


    $Existing = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $Path) {

        foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {

            $Existing.Add($Line)
        }
    }


    $Written = @{}

    $Output = New-Object System.Collections.Generic.List[string]


    foreach ($Line in $Existing) {

        $Trimmed = $Line.Trim()

        if (
            $Trimmed.Length -eq 0 -or
            $Trimmed.StartsWith("#")
        ) {

            $Output.Add($Line)

            continue
        }


        $Separator = $Line.IndexOf("=")

        if ($Separator -lt 1) {

            $Output.Add($Line)

            continue
        }


        $Name = $Line.Substring(0, $Separator).Trim()

        if ($Values.ContainsKey($Name)) {

            $Output.Add(("{0}={1}" -f $Name, $Values[$Name]))

            $Written[$Name] = $true

        }
        else {

            $Output.Add($Line)
        }
    }


    foreach ($Name in @($Values.Keys)) {

        if (-not $Written.ContainsKey($Name)) {

            $Output.Add(("{0}={1}" -f $Name, $Values[$Name]))
        }
    }


    $Utf8 = New-Object System.Text.UTF8Encoding $false

    [System.IO.File]::WriteAllLines(
        $Path,
        $Output.ToArray(),
        $Utf8
    )
}



function Update-AnyDeskSilentConfig {

    # Solo el system.conf del servicio. No se toca el system.conf de
    # %AppData%, porque ahi puede vivir la instancia portable.
    $Saved = $false


    for ($Attempt = 1; $Attempt -le 5; $Attempt++) {

        try {

            Set-AnyDeskConfigKeys `
                -Path $SystemConfig `
                -Values $SilentConfig


            $Saved = $true

            break

        }
        catch {

            if ($Attempt -ge 5) {

                Write-Log `
                    "No se pudo escribir ${SystemConfig}: $($_.Exception.Message)" `
                    "WARN"
            }
            else {

                Start-Sleep -Seconds 1
            }
        }
    }


    if ($Saved) {

        Write-Log `
            "Configuracion silenciosa escrita: $SystemConfig" `
            "OK"
    }


    $Applied = Read-AnyDeskConfigValue `
        -Path $SystemConfig `
        -Name "ad.security.interactive_access"


    $Script:SilentConfigApplied = $Saved -and ($Applied -eq "2")


    if ($Script:SilentConfigApplied) {

        Write-Log `
            "Solicitudes entrantes desactivadas. Solo acceso desatendido." `
            "OK"

    }
    else {

        Write-Log `
            "No quedo confirmado ad.security.interactive_access=2." `
            "WARN"
    }


    return $Script:SilentConfigApplied
}



function Test-AnyDeskPasswordHashStored {

    if (-not (Test-Path -LiteralPath $SystemConfig)) {

        return $false
    }


    foreach ($Line in [System.IO.File]::ReadAllLines($SystemConfig)) {

        if ($Line -match "(?i)pwd_hash\s*=\s*\S+") {

            return $true
        }
    }


    return $false
}



function Remove-AnyDeskShortcut {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path
    )


    if (-not (Test-Path -LiteralPath $Path)) {

        return
    }


    $Item = Get-Item -LiteralPath $Path -Force


    if ($Item.PSIsContainer) {

        return
    }


    $Name = $Item.Name

    $KnownName = (
        $Name -eq "AnyDesk.lnk" -or
        $Name -eq "AnyDesk.exe.lnk"
    )

    $Target = $null


    if ($Name -like "*.lnk") {

        try {

            $Shell = New-Object -ComObject WScript.Shell

            $Shortcut = $Shell.CreateShortcut($Item.FullName)

            $Target = [string]$Shortcut.TargetPath

        }
        catch {

            $Target = $null
        }
    }


    # Un acceso que apunta a la copia portable se conserva.
    if ($Target) {

        $Remove = Test-PathUnderInstallDir -Path $Target

    }
    else {

        $Remove = $KnownName
    }


    if (-not $Remove) {

        return
    }


    Remove-Item `
        -LiteralPath $Item.FullName `
        -Force `
        -ErrorAction Stop


    $Script:RemovedShortcuts++

    Write-Log `
        "Acceso directo eliminado: $($Item.FullName)" `
        "OK"
}



function Get-AnyDeskShortcutRoots {

    $Roots = New-Object System.Collections.Generic.List[string]


    foreach (
        $Folder in @(
            "CommonDesktopDirectory",
            "CommonPrograms",
            "CommonStartup",
            "CommonStartMenu",
            "Desktop",
            "Programs",
            "Startup",
            "StartMenu"
        )
    ) {

        $Path = [Environment]::GetFolderPath($Folder)

        if ($Path) {

            $Roots.Add($Path)
        }
    }


    $Users = Get-ChildItem `
        -LiteralPath "C:\Users" `
        -Directory `
        -ErrorAction SilentlyContinue


    foreach ($User in $Users) {

        if (
            $User.Name -in @(
                "Public",
                "Default",
                "Default User",
                "All Users"
            )
        ) {

            continue
        }


        foreach (
            $Relative in @(
                "Desktop",
                "Escritorio",
                "AppData\Roaming\Microsoft\Windows\Start Menu\Programs",
                "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup",
                "AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
            )
        ) {

            $Roots.Add((Join-Path $User.FullName $Relative))
        }
    }


    return $Roots
}



function Get-AnyDeskProgramRoots {

    $Roots = @{}


    foreach (
        $Folder in @(
            [Environment]::GetFolderPath("CommonPrograms"),
            [Environment]::GetFolderPath("Programs")
        )
    ) {

        if ($Folder) {

            $Roots[[System.IO.Path]::GetFullPath($Folder)] = $true
        }
    }


    $Users = Get-ChildItem `
        -LiteralPath "C:\Users" `
        -Directory `
        -ErrorAction SilentlyContinue


    foreach ($User in $Users) {

        if (
            $User.Name -in @(
                "Public",
                "Default",
                "Default User",
                "All Users"
            )
        ) {

            continue
        }


        $Programs = Join-Path `
            $User.FullName `
            "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"


        if (Test-Path -LiteralPath $Programs) {

            $Roots[[System.IO.Path]::GetFullPath($Programs)] = $true
        }
    }


    # La coma evita que PowerShell desarme el hashtable al salir.
    return ,$Roots
}



function Remove-AnyDeskShortcuts {

    $Seen = @{}

    $ProgramRoots = Get-AnyDeskProgramRoots


    foreach ($Root in @(Get-AnyDeskShortcutRoots)) {

        if (-not (Test-Path -LiteralPath $Root)) {

            continue
        }


        $FullRoot = [System.IO.Path]::GetFullPath($Root)

        if ($Seen.ContainsKey($FullRoot)) {

            continue
        }


        $Seen[$FullRoot] = $true


        $ProgramFolder = Join-Path $FullRoot "AnyDesk"

        if (
            $ProgramRoots.ContainsKey($FullRoot) -and
            (Test-Path -LiteralPath $ProgramFolder)
        ) {

            try {

                Remove-Item `
                    -LiteralPath $ProgramFolder `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop


                $Script:RemovedShortcuts++

                Write-Log `
                    "Carpeta de accesos eliminada: $ProgramFolder" `
                    "OK"

            }
            catch {

                Write-Log `
                    "No se pudo eliminar ${ProgramFolder}: $($_.Exception.Message)" `
                    "WARN"
            }
        }


        $Links = Get-ChildItem `
            -LiteralPath $FullRoot `
            -Filter "*.lnk" `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue


        foreach ($Link in $Links) {

            try {

                Remove-AnyDeskShortcut -Path $Link.FullName

            }
            catch {

                Write-Log `
                    "No se pudo eliminar $($Link.FullName): $($_.Exception.Message)" `
                    "WARN"
            }
        }
    }
}



function Remove-AnyDeskRunValue {

    param (

        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )


    if (-not (Test-Path -LiteralPath $KeyPath)) {

        return
    }


    $Properties = Get-ItemProperty `
        -LiteralPath $KeyPath `
        -ErrorAction SilentlyContinue


    if (-not $Properties) {

        return
    }


    foreach ($Property in $Properties.PSObject.Properties) {

        if ($Property.Name -like "PS*") {

            continue
        }


        $Value = [string]$Property.Value

        if (-not (Test-PathUnderInstallDir -Path $Value)) {

            continue
        }


        Remove-ItemProperty `
            -LiteralPath $KeyPath `
            -Name $Property.Name `
            -ErrorAction Stop


        $Script:RemovedStartupEntries++

        Write-Log `
            "Inicio automatico de la ventana eliminado: $KeyPath :: $($Property.Name)" `
            "OK"
    }
}



function Get-AnyDeskRunKeyPaths {

    $Keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )


    $UserHives = Get-ChildItem `
        -Path "Registry::HKEY_USERS" `
        -ErrorAction SilentlyContinue


    foreach ($Hive in $UserHives) {

        if ($Hive.PSChildName -notmatch "^S-1-5-21-") {

            continue
        }


        if ($Hive.PSChildName -match "_Classes$") {

            continue
        }


        $Keys += "Registry::HKEY_USERS\$($Hive.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
    }


    return $Keys
}



function Remove-AnyDeskStartupEntries {

    foreach ($Key in @(Get-AnyDeskRunKeyPaths)) {

        try {

            Remove-AnyDeskRunValue -KeyPath $Key

        }
        catch {

            Write-Log `
                "No se pudo limpiar ${Key}: $($_.Exception.Message)" `
                "WARN"
        }
    }
}



function Remove-AnyDeskLogonTasks {

    try {

        $Tasks = @(Get-ScheduledTask -ErrorAction Stop)

    }
    catch {

        Write-Log `
            "No se pudieron consultar tareas programadas: $($_.Exception.Message)" `
            "WARN"

        return
    }


    foreach ($Task in $Tasks) {

        $LaunchesGui = $false


        foreach ($Action in @($Task.Actions)) {

            $Arguments = [string]$Action.Arguments

            if ($Arguments -match "(?i)--service") {

                continue
            }


            if (Test-PathUnderInstallDir -Path ([string]$Action.Execute)) {

                $LaunchesGui = $true
            }
        }


        if (-not $LaunchesGui) {

            continue
        }


        $StartsAtLogon = $false


        foreach ($Trigger in @($Task.Triggers)) {

            if (
                $Trigger.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger"
            ) {

                $StartsAtLogon = $true
            }
        }


        if (-not $StartsAtLogon) {

            continue
        }


        try {

            Unregister-ScheduledTask `
                -TaskName $Task.TaskName `
                -TaskPath $Task.TaskPath `
                -Confirm:$false `
                -ErrorAction Stop


            $Script:RemovedStartupEntries++

            Write-Log `
                "Tarea de inicio de sesion eliminada: $($Task.TaskName)" `
                "OK"

        }
        catch {

            Write-Log `
                "No se pudo eliminar la tarea $($Task.TaskName): $($_.Exception.Message)" `
                "WARN"
        }
    }
}



function Stop-InstalledAnyDeskGui {

    # El servicio y la instancia portable no se tocan.
    # Solo se cierra la ventana creada por la instalacion nueva.

    if ($Script:InitialService) {

        return
    }


    $ServicePid = Get-AnyDeskServicePid

    $Processes = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "Name='AnyDesk.exe'" `
            -ErrorAction SilentlyContinue
    )


    foreach ($Process in $Processes) {

        $Command = [string]$Process.CommandLine

        $ExePath = [string]$Process.ExecutablePath


        if ($Process.ProcessId -eq $ServicePid) {

            continue
        }


        if ($Command -match "(?i)--service") {

            continue
        }


        if (
            $Script:PortableExe -and
            $ExePath -and
            ($ExePath -ieq $Script:PortableExe)
        ) {

            continue
        }


        if (-not $ExePath -or -not $Command) {

            Write-Log `
                "PID $($Process.ProcessId) sin ruta o linea de comando. No se detuvo." `
                "WARN"

            continue
        }


        if (-not (Test-PathUnderInstallDir -Path $ExePath)) {

            continue
        }


        try {

            Stop-Process `
                -Id $Process.ProcessId `
                -Force `
                -ErrorAction Stop


            $Script:ClosedGuiCount++

            Write-Log `
                "Ventana de AnyDesk cerrada. PID $($Process.ProcessId). El servicio sigue activo." `
                "OK"

        }
        catch {

            Write-Log `
                "No se pudo cerrar la ventana PID $($Process.ProcessId): $($_.Exception.Message)" `
                "WARN"
        }
    }
}



function Restart-NewAnyDeskService {

    Write-Log `
        "Aplicando la configuracion silenciosa sobre la instalacion nueva."


    try {

        Stop-Service `
            -Name "AnyDesk" `
            -Force `
            -ErrorAction Stop


        $Service = Get-AnyDeskService

        $Service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30)
        )


        Write-Log `
            "Servicio detenido para escribir system.conf." `
            "OK"

    }
    catch {

        Write-Log `
            "No se pudo detener el servicio nuevo: $($_.Exception.Message)" `
            "ERROR"

        return $false
    }


    $ConfigOk = Update-AnyDeskSilentConfig


    try {

        if (-not (Test-AnyDeskPasswordHashStored)) {

            Write-Log `
                "No se encontro el hash de la password en system.conf." `
                "WARN"
        }

    }
    catch {

        Write-Log `
            "No se pudo comprobar el hash de la password: $($_.Exception.Message)" `
            "WARN"
    }


    try {

        Start-Service `
            -Name "AnyDesk" `
            -ErrorAction Stop


        $Service = Get-AnyDeskService

        $Service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(30)
        )


        Write-Log `
            "Servicio AnyDesk en ejecucion, sin ventana de usuario." `
            "OK"

    }
    catch {

        Write-Log `
            "No se pudo iniciar el servicio despues de configurar la interfaz: $($_.Exception.Message)" `
            "ERROR"


        try {

            Start-Service `
                -Name "AnyDesk" `
                -ErrorAction Stop


            Write-Log `
                "Servicio AnyDesk recuperado." `
                "WARN"

        }
        catch {

            Write-Log `
                "El servicio AnyDesk quedo detenido: $($_.Exception.Message)" `
                "ERROR"
        }


        return $false
    }


    return $ConfigOk
}



function Hide-AnyDeskUserInterface {

    Write-Log `
        "Ocultando la interfaz local de AnyDesk."


    Remove-AnyDeskShortcuts

    Remove-AnyDeskStartupEntries

    Remove-AnyDeskLogonTasks


    if ($Script:RemovedShortcuts -eq 0) {

        Write-Log `
            "No habia accesos directos de la instalacion persistente." `
            "OK"
    }


    if ($Script:RemovedStartupEntries -eq 0) {

        Write-Log `
            "No habia entradas de inicio de la ventana." `
            "OK"
    }


    if (-not $Script:InitialService) {

        $Ready = Restart-NewAnyDeskService

        Start-Sleep -Seconds 3

        Stop-InstalledAnyDeskGui

        Start-Sleep -Seconds 2

        Stop-InstalledAnyDeskGui


        if ($Script:ClosedGuiCount -eq 0) {

            Write-Log `
                "La instalacion no dejo una ventana abierta." `
                "OK"
        }


        return $Ready
    }


    Write-Log `
        "El servicio ya estaba en ejecucion. No se reinicia, para conservar la sesion actual." `
        "WARN"


    Write-Log `
        "La ventana que ya este abierta permanece hasta el proximo cierre de sesion." `
        "WARN"


    $Written = Update-AnyDeskSilentConfig

    if ($Written) {

        Write-Log `
            "La opcion de solicitudes entrantes queda escrita y se aplicara al proximo inicio del servicio." `
            "OK"
    }


    return $Written
}



function Test-AnyDeskStartupRemains {

    foreach ($Key in @(Get-AnyDeskRunKeyPaths)) {

        if (-not (Test-Path -LiteralPath $Key)) {

            continue
        }


        $Properties = Get-ItemProperty `
            -LiteralPath $Key `
            -ErrorAction SilentlyContinue


        if (-not $Properties) {

            continue
        }


        foreach ($Property in $Properties.PSObject.Properties) {

            if ($Property.Name -like "PS*") {

                continue
            }


            if (Test-PathUnderInstallDir -Path ([string]$Property.Value)) {

                return $true
            }
        }
    }


    return $false
}



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


if ($ShowUserInterface) {

    Write-Log `
        "Modo de interfaz: VISIBLE."

}
else {

    Write-Log `
        "Modo de interfaz: OCULTA para el usuario local."
}



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


    Stop-AnyDeskDeploy -Code 10
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


    Stop-AnyDeskDeploy -Code 11
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

$Script:InitialService = $InitialService

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
                -Executable $Script:InstalledExe `
                -FromInstalledService
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


        Stop-AnyDeskDeploy -Code 20
    }



    if (-not (Test-Path -LiteralPath $Installer)) {

        Write-Log `
            "No se encontro el instalador descargado." `
            "ERROR"


        Stop-AnyDeskDeploy -Code 21
    }



    $DownloadedFile = Get-Item -LiteralPath $Installer


    if ($DownloadedFile.Length -lt 1MB) {

        Write-Log `
            "El archivo descargado parece invalido. Tamano: $($DownloadedFile.Length) bytes." `
            "ERROR"


        Stop-AnyDeskDeploy -Code 22
    }



    Write-Log `
        ("Descarga completada. Tamano: {0:N2} MB" -f `
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
            -LiteralPath $Installer `
            -Force `
            -ErrorAction SilentlyContinue


        Stop-AnyDeskDeploy -Code 23
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


    # PowerShell 5.1 cita solo cada elemento del array. La ruta con
    # espacios no debe llevar comillas adicionales.
    $InstallArguments = @(
        "--install",
        $InstallDir,
        "--silent"
    )


    if ($ShowUserInterface) {

        $InstallArguments += @(
            "--start-with-win",
            "--create-shortcuts",
            "--create-desktop-icon"
        )

        Write-Log `
            "La instalacion creara accesos directos y abrira con Windows."

    }
    else {

        # Sin --start-with-win, --create-shortcuts ni --create-desktop-icon.
        # El servicio Automatic cubre el acceso desatendido despues de reiniciar.
        Write-Log `
            "Instalacion silenciosa, sin accesos directos ni ventana al iniciar Windows."
    }


    try {

        $InstallProcess = Start-Process `
            -FilePath $Installer `
            -ArgumentList $InstallArguments `
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


        Stop-AnyDeskDeploy -Code 24
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


        Stop-AnyDeskDeploy -Code 25
    }



    Write-Log `
        "Servicio AnyDesk creado correctamente." `
        "OK"


    $Script:InstalledExe = Find-InstalledAnyDesk


    if (-not $Script:InstalledExe) {

        Write-Log `
            "El servicio existe pero no se encontro el ejecutable instalado." `
            "ERROR"


        Stop-AnyDeskDeploy -Code 26
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

    if (Test-Path -LiteralPath $DefaultInstalledExe) {

        $Script:InstalledExe = $DefaultInstalledExe
    }
}


if (-not $Script:InstalledExe) {

    Write-Log `
        "No fue posible localizar el AnyDesk instalado." `
        "ERROR"


    Stop-AnyDeskDeploy -Code 27
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


    Stop-AnyDeskDeploy -Code 30
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
        "Inicio automatico del servicio configurado." `
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


        Stop-AnyDeskDeploy -Code 31
    }

}
else {

    if ($Script:InitialService -or $ShowUserInterface) {

        Write-Log `
            "Servicio ya se encuentra Running. NO se reiniciara." `
            "OK"

    }
    else {

        Write-Log `
            "Servicio en ejecucion. Se reiniciara una vez al aplicar la interfaz oculta." `
            "OK"
    }
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


        Stop-AnyDeskDeploy -Code 40
    }


    Write-Log `
        "Password de acceso desatendido configurada." `
        "OK"

}
catch {

    Write-Log `
        "Error configurando acceso desatendido: $($_.Exception.Message)" `
        "ERROR"


    Stop-AnyDeskDeploy -Code 41
}



# ============================================================
# CERRAR VENTANA DE UNA INSTALACION NUEVA
# ============================================================

if (
    (-not $ShowUserInterface) -and
    (-not $Script:InitialService)
) {

    Stop-InstalledAnyDeskGui
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
        -Executable $Script:InstalledExe `
        -FromInstalledService


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

    $OldKey = ConvertTo-AnyDeskIDKey $Script:OldID

    $NewKey = ConvertTo-AnyDeskIDKey $Script:NewID


    if ($OldKey -eq $NewKey) {

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
# OCULTAR INTERFAZ LOCAL
# ============================================================

if ($ShowUserInterface) {

    Write-Log `
        "Se conserva la interfaz visible de AnyDesk." `
        "OK"

}
else {

    $UiOk = Hide-AnyDeskUserInterface

    if (-not $UiOk) {

        Write-Log `
            "La interfaz local no quedo completamente oculta." `
            "WARN"
    }


    # --get-id y --version pueden volver a abrir la ventana.
    if (-not $Script:InitialService) {

        Stop-InstalledAnyDeskGui
    }


    $Service = Get-AnyDeskService

    $ServiceCIM = Get-CimInstance `
        Win32_Service `
        -Filter "Name='AnyDesk'" `
        -ErrorAction SilentlyContinue


    if (-not $Script:NewID) {

        $Script:NewID = Get-AnyDeskIDFromServiceConfig
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



if (-not (Test-Path -LiteralPath $Script:InstalledExe)) {

    Write-Log `
        "No existe el ejecutable persistente." `
        "ERROR"


    $DeploymentOK = $false
}



if (-not $ShowUserInterface) {

    if (Test-AnyDeskStartupRemains) {

        Write-Log `
            "La ventana de AnyDesk sigue registrada para iniciar con Windows." `
            "WARN"


        $DeploymentOK = $false
    }


    if (-not $Script:SilentConfigApplied) {

        Write-Log `
            "Las solicitudes entrantes no quedaron desactivadas." `
            "WARN"


        $DeploymentOK = $false
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



if ($ShowUserInterface) {

    Write-Host `
        "Interfaz local     : VISIBLE"

}
else {

    Write-Host `
        "Interfaz local     : OCULTA"


    Write-Host `
        ("Accesos directos   : {0} eliminados" -f $Script:RemovedShortcuts)


    Write-Host `
        ("Inicios de ventana : {0} eliminados" -f $Script:RemovedStartupEntries)


    Write-Host `
        "Solicitudes        : solo acceso desatendido"
}



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

if (Test-Path -LiteralPath $Installer) {

    Remove-Item `
        -LiteralPath $Installer `
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

if (-not $ShowUserInterface) {

    Write-Host ""
    Write-Host "La aplicacion no queda en el escritorio, el menu Inicio"
    Write-Host "ni el inicio de Windows. El acceso entra por el servicio."
    Write-Host "Durante una sesion remota el equipo muestra el marco"
    Write-Host "y la barra de sesion de AnyDesk."
}

Write-Host ""



if ($DeploymentOK) {

    Stop-AnyDeskDeploy -Code 0

}
else {

    Stop-AnyDeskDeploy -Code 1
}

}
catch {

    $DeployMessage = [string]$_.Exception.Message

    if ($DeployMessage -like "AnyDeskDeployExit:*") {

        $DeployExitCode = 1

        $DeployParsedCode = 0

        if (
            [int]::TryParse(
                ($DeployMessage -replace "^AnyDeskDeployExit:", ""),
                [ref]$DeployParsedCode
            )
        ) {

            $DeployExitCode = $DeployParsedCode
        }


        $UnattendedPassword = $null
        $SecurePassword = $null
        $global:LASTEXITCODE = $DeployExitCode


        if ($PSCommandPath) {

            exit $DeployExitCode
        }


        return
    }


    throw
}
