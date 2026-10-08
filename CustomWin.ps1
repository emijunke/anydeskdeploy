<#
.SYNOPSIS
    Menu para elegir que personalizar en Windows.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Al ejecutarse muestra una lista para tildar que se quiere aplicar.
    - Puede instalar Notepad++, 7-Zip, Firefox, Chrome, PuTTY y VMware Tools.
      Si alguno ya esta instalado, no lo vuelve a descargar.
      7-Zip no firma su instalador: se comprueba el SHA-256 de la
      release oficial.
    - Puede instalar AnyDesk oculto, con password de acceso desatendido.
      Si $UnattendedPassword ya existe, no la vuelve a pedir.
      Una copia portable en uso no se cierra.
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

.EXAMPLE
    $UnattendedPassword = 'PASSWORD'
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

$Script:AlignLeft = $false

$Script:Failures = New-Object System.Collections.Generic.List[string]


function Write-Log {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "OK", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $Line = "[{0}] [{1}] {2}" -f $Timestamp, $Level, $Message


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


    if ($script:LogFile) {

        Add-Content -Path $script:LogFile -Value $Line -Encoding UTF8
    }
}



function Stop-CustomWin {

    param (
        [int]$Code
    )


    if ([string]::IsNullOrEmpty($PSCommandPath)) {

        throw "CustomWinExit:$Code"
    }


    exit $Code
}



function Add-DeployFailure {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )


    $Script:Failures.Add($Message)

    Write-Log $Message "ERROR"
}



function Test-Administrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}



function Get-OsArchitecture {

    if (
        $env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or
        $env:PROCESSOR_ARCHITEW6432 -eq "ARM64"
    ) {

        return "ARM64"
    }


    if ([Environment]::Is64BitOperatingSystem) {

        return "x64"
    }


    return "x86"
}



function Set-RegistryDword {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )


    if (-not (Test-Path -LiteralPath $Path)) {

        New-Item -Path $Path -Force | Out-Null
    }


    New-ItemProperty `
        -LiteralPath $Path `
        -Name $Name `
        -Value $Value `
        -PropertyType DWord `
        -Force |
        Out-Null
}



function Save-WebFile {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )


    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


    Invoke-WebRequest `
        -Uri $Uri `
        -OutFile $Destination `
        -UseBasicParsing
}



function Test-InstallerTrust {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Sha256
    )


    $Signature = Get-AuthenticodeSignature -FilePath $Path


    if ($Signature.Status -eq "Valid") {

        return [string]$Signature.SignerCertificate.Subject
    }


    $Expected = ""

    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {

        $Expected = $Sha256.Trim().ToLowerInvariant()
    }


    if ($Expected -match '^[0-9a-f]{64}$') {

        $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash

        if ($Actual.ToLowerInvariant() -eq $Expected) {

            return "instalador oficial sin firma Authenticode, SHA-256 verificado"
        }


        throw "El SHA-256 no coincide con el publicado por el fabricante."
    }


    throw "Firma digital no valida. Estado: $($Signature.Status)"
}



function Invoke-InstallerProcess {

    param (

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Arguments,

        [int]$TimeoutSeconds = 900
    )


    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo

    $StartInfo.FileName = $FilePath

    $StartInfo.Arguments = $Arguments

    $StartInfo.UseShellExecute = $false

    $StartInfo.CreateNoWindow = $true


    $Process = New-Object System.Diagnostics.Process

    $Process.StartInfo = $StartInfo


    if (-not $Process.Start()) {

        throw "No se pudo iniciar $FilePath"
    }


    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {

        try {

            $Process.Kill()
        }
        catch {
        }


        throw "El instalador excedio los $TimeoutSeconds segundos."
    }


    return $Process.ExitCode
}



function Install-SetupPackage {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [ValidateSet("NSIS", "MSI")]
        [string]$Kind,

        [string]$Sha256,

        [string]$Arguments
    )


    $Destination = Join-Path $TempDir $FileName


    Write-Log "Descargando $Name..."

    Write-Log "Origen: $Uri"


    Save-WebFile -Uri $Uri -Destination $Destination


    if (-not (Test-Path -LiteralPath $Destination)) {

        throw "No se encontro el archivo descargado."
    }


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


    $Release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" `
        -Headers @{ "User-Agent" = "Install-Win-Basic" }


    $Asset = $Release.assets |
        Where-Object {
            $_.name -like "7z*.exe" -and
            $_.name -ne "7zr.exe" -and
            (
                ($Architecture -eq "x64" -and $_.name -like "*-x64.exe") -or
                ($Architecture -eq "ARM64" -and $_.name -like "*-arm64.exe") -or
                (
                    $Architecture -eq "x86" -and
                    $_.name -notlike "*-x64.exe" -and
                    $_.name -notlike "*-arm64.exe" -and
                    $_.name -notlike "*-arm.exe"
                )
            )
        } |
        Select-Object -First 1


    if (-not $Asset) {

        throw "No se encontro el instalador de 7-Zip para $Architecture."
    }


    $Url = [string]$Asset.browser_download_url

    if ($Url -notlike "https://github.com/ip7z/7zip/releases/download/*/*.exe") {

        throw "La URL del instalador de 7-Zip no es la oficial."
    }


    $Digest = ([string]$Asset.digest).Trim().ToLowerInvariant()

    if ($Digest -notmatch '^sha256:([0-9a-f]{64})$') {

        throw "7-Zip no publico el SHA-256 del instalador."
    }


    return [pscustomobject]@{
        Url    = $Url
        Sha256 = $Matches[1]
    }
}



function Get-FirefoxUrl {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )


    $Language = "es-ES"

    try {

        $Culture = [string](Get-Culture).Name

        if ($Culture -eq "es-AR" -or $Culture -eq "es-ES" -or $Culture -eq "es-MX") {

            $Language = $Culture

        }
        elseif ($Culture -like "en-*") {

            $Language = "en-US"
        }

    }
    catch {
    }


    $Os = "win64"


    if ($Architecture -eq "ARM64") {

        $Os = "win64-aarch64"

    }
    elseif ($Architecture -eq "x86") {

        $Os = "win"
    }


    return "https://download.mozilla.org/?product=firefox-latest-ssl&os=$Os&lang=$Language"
}



function Get-ChromeUrl {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )


    if ($Architecture -eq "x86") {

        return "https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise.msi"
    }


    return "https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi"
}



function Get-PuttyUrl {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )


    $Page = Invoke-WebRequest `
        -Uri "https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html" `
        -UseBasicParsing


    $Pattern = switch ($Architecture) {

        "ARM64" { 'https://the\.earth\.li/~sgtatham/putty/latest/wa64/putty-arm64-[0-9.]+-installer\.msi' }

        "x64" { 'https://the\.earth\.li/~sgtatham/putty/latest/w64/putty-64bit-[0-9.]+-installer\.msi' }

        default { 'https://the\.earth\.li/~sgtatham/putty/latest/w32/putty-[0-9.]+-installer\.msi' }
    }


    $Match = [regex]::Match($Page.Content, $Pattern)


    if (-not $Match.Success) {

        throw "No se encontro el instalador de PuTTY para $Architecture."
    }


    return $Match.Value
}



function Get-VMwareToolsUrl {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )


    $Folder = switch ($Architecture) {

        "ARM64" { "arm" }

        "x64" { "x64" }

        default { "" }
    }


    if ([string]::IsNullOrWhiteSpace($Folder)) {

        throw "No hay instalador de VMware Tools para $Architecture."
    }


    $Page = Invoke-WebRequest `
        -Uri "https://packages.vmware.com/tools/releases/latest/windows/$Folder/" `
        -UseBasicParsing


    $Pattern = "VMware-tools-[0-9.]+-[0-9]+-x64\.exe"


    if ($Architecture -eq "ARM64") {

        $Pattern = "VMware-tools-[0-9.]+-[0-9]+-arm\.exe"
    }


    $Match = [regex]::Match($Page.Content, $Pattern)


    if (-not $Match.Success -or $Match.Value -match '[\\/]') {

        throw "No se encontro el instalador de VMware Tools para $Architecture."
    }


    return "https://packages.vmware.com/tools/releases/latest/windows/$Folder/$($Match.Value)"
}



function Get-CandidatePaths {

    param (
        [string[]]$RelativePaths,
        [string[]]$ExtraPaths
    )


    $Roots = @(
        [string]$env:ProgramFiles,
        [string]${env:ProgramFiles(x86)},
        [string]$env:ProgramW6432
    )

    $Paths = @()


    foreach ($Root in $Roots) {

        if ([string]::IsNullOrWhiteSpace($Root)) {

            continue
        }


        foreach ($RelativePath in @($RelativePaths)) {

            $Relative = [string]$RelativePath

            if ([string]::IsNullOrWhiteSpace($Relative)) {

                continue
            }


            $FullPath = Join-Path -Path $Root -ChildPath $Relative

            if ($Paths -notcontains $FullPath) {

                $Paths += $FullPath
            }
        }
    }


    foreach ($ExtraPath in @($ExtraPaths)) {

        $Extra = [string]$ExtraPath

        if ([string]::IsNullOrWhiteSpace($Extra)) {

            continue
        }


        if ($Paths -notcontains $Extra) {

            $Paths += $Extra
        }
    }


    return ,$Paths
}



function Get-UninstallEntries {

    # No usar List[object]. En Windows PowerShell 5.1, @() sobre esa
    # lista creada con New-Object lanza "Los tipos de argumentos no coinciden".
    $Entries = @()

    $Hives = @(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryHive]::CurrentUser
    )

    $Views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )


    foreach ($Hive in $Hives) {

        foreach ($View in $Views) {

            $Base = $null


            try {

                $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)

                $Uninstall = $Base.OpenSubKey(
                    "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
                )


                if (-not $Uninstall) {

                    continue
                }


                foreach ($SubKeyName in $Uninstall.GetSubKeyNames()) {

                    $Key = $Uninstall.OpenSubKey($SubKeyName)

                    if (-not $Key) {

                        continue
                    }


                    $DisplayName = [string]$Key.GetValue("DisplayName")

                    $DisplayVersion = [string]$Key.GetValue("DisplayVersion")

                    $Key.Close()


                    if ([string]::IsNullOrWhiteSpace($DisplayName)) {

                        continue
                    }


                    $Entries += [pscustomobject]@{
                        DisplayName    = $DisplayName.Trim()
                        DisplayVersion = $DisplayVersion.Trim()
                    }
                }


                $Uninstall.Close()
            }
            catch {
            }
            finally {

                if ($Base) {

                    $Base.Close()
                }
            }
        }
    }


    return ,$Entries
}



function Get-FileVersionText {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )


    try {

        $Info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)


        if (-not [string]::IsNullOrWhiteSpace($Info.ProductVersion)) {

            return $Info.ProductVersion.Trim()
        }


        if (-not [string]::IsNullOrWhiteSpace($Info.FileVersion)) {

            return $Info.FileVersion.Trim()
        }
    }
    catch {
    }


    return ""
}



function Find-InstalledApplication {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [string[]]$RelativePaths,

        [string[]]$ExtraPaths
    )


    $Candidates = Get-CandidatePaths `
        -RelativePaths $RelativePaths `
        -ExtraPaths $ExtraPaths


    foreach ($Candidate in @($Candidates)) {

        if ([string]::IsNullOrWhiteSpace([string]$Candidate)) {

            continue
        }


        if (Test-Path -LiteralPath ([string]$Candidate)) {

            return [pscustomobject]@{
                Version  = Get-FileVersionText -Path ([string]$Candidate)
                Location = [string]$Candidate
            }
        }
    }


    $UninstallEntries = Get-UninstallEntries


    foreach ($Entry in $UninstallEntries) {

        if ([string]::IsNullOrWhiteSpace([string]$Entry.DisplayName)) {

            continue
        }


        if ($Entry.DisplayName -match $Pattern) {

            return [pscustomobject]@{
                Version  = [string]$Entry.DisplayVersion
                Location = [string]$Entry.DisplayName
            }
        }
    }


    return $null
}



function Get-LocalAppPath {

    param (
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )


    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {

        return ""
    }


    return (Join-Path $env:LOCALAPPDATA $RelativePath)
}



function Install-BasicApplications {

    param (

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [string[]]$Names
    )


    $Packages = @(
        @{
            Name = "Notepad++"
            File = "npp-setup.exe"
            Kind = "NSIS"
            Pattern = '^Notepad\+\+'
            RelativePaths = @("Notepad++\notepad++.exe")
            ExtraPaths = @()
        },
        @{
            Name = "7-Zip"
            File = "7zip-setup.exe"
            Kind = "NSIS"
            Pattern = '^7-Zip($| )'
            RelativePaths = @("7-Zip\7z.exe", "7-Zip\7zFM.exe")
            ExtraPaths = @()
        },
        @{
            Name = "Firefox"
            File = "firefox-setup.exe"
            Kind = "NSIS"
            Pattern = '^Mozilla Firefox'
            RelativePaths = @("Mozilla Firefox\firefox.exe")
            ExtraPaths = @(
                (Get-LocalAppPath "Mozilla Firefox\firefox.exe")
            )
        },
        @{
            Name = "Google Chrome"
            File = "chrome-setup.msi"
            Kind = "MSI"
            Pattern = '^Google Chrome($| \d)'
            RelativePaths = @("Google\Chrome\Application\chrome.exe")
            ExtraPaths = @(
                (Get-LocalAppPath "Google\Chrome\Application\chrome.exe")
            )
        },
        @{
            Name = "PuTTY"
            File = "putty-setup.msi"
            Kind = "MSI"
            Pattern = '^PuTTY($| )'
            RelativePaths = @("PuTTY\putty.exe")
            ExtraPaths = @()
        },
        @{
            Name = "VMware Tools"
            File = "vmware-tools-setup.exe"
            Kind = "NSIS"
            Arguments = '/S /v "/qn REBOOT=R"'
            Pattern = '^VMware Tools'
            RelativePaths = @("VMware\VMware Tools\vmtoolsd.exe")
            ExtraPaths = @()
        }
    )


    foreach ($Package in $Packages) {

        if ($Names -and $Names -notcontains $Package.Name) {

            continue
        }


        try {

            $Installed = Find-InstalledApplication `
                -Pattern $Package.Pattern `
                -RelativePaths $Package.RelativePaths `
                -ExtraPaths $Package.ExtraPaths


            if ($Installed) {

                $Detail = $Installed.Version

                if ([string]::IsNullOrWhiteSpace($Detail)) {

                    $Detail = $Installed.Location
                }


                Write-Log "$($Package.Name) ya esta instalado ($Detail). Se omite." "OK"

                continue
            }


            $Url = $null

            $Sha256 = ""


            switch ($Package.Name) {

                "Notepad++" {

                    $Url = Get-NotepadPlusPlusUrl -Architecture $Architecture
                }

                "7-Zip" {

                    $SevenZip = Get-SevenZipPackage -Architecture $Architecture

                    $Url = $SevenZip.Url

                    $Sha256 = $SevenZip.Sha256
                }

                "Firefox" {

                    $Url = Get-FirefoxUrl -Architecture $Architecture
                }

                "Google Chrome" {

                    $Url = Get-ChromeUrl -Architecture $Architecture
                }

                "PuTTY" {

                    $Url = Get-PuttyUrl -Architecture $Architecture
                }

                "VMware Tools" {

                    $Url = Get-VMwareToolsUrl -Architecture $Architecture
                }
            }


            $SetupArguments = ""

            if ($Package["Arguments"]) {

                $SetupArguments = [string]$Package["Arguments"]
            }


            Install-SetupPackage `
                -Name ([string]$Package.Name) `
                -Uri ([string]$Url) `
                -FileName ([string]$Package.File) `
                -Kind ([string]$Package.Kind) `
                -Sha256 ([string]$Sha256) `
                -Arguments $SetupArguments

        }
        catch {

            $FailLine = $_.InvocationInfo.ScriptLineNumber

            Add-DeployFailure "$($Package.Name) (linea ${FailLine}): $($_.Exception.Message)"
        }
    }
}



function Disable-WindowsFirewallPermanently {

    Write-Log "Deshabilitando el Firewall de Windows en todas las redes..."


    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False


    foreach ($Profile in @("DomainProfile", "PrivateProfile", "PublicProfile")) {

        Set-RegistryDword `
            -Path "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$Profile" `
            -Name "EnableFirewall" `
            -Value 0


        Set-RegistryDword `
            -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$Profile" `
            -Name "EnableFirewall" `
            -Value 0
    }


    $StillEnabled = @(
        Get-NetFirewallProfile |
            Where-Object { $_.Enabled -eq $true }
    )


    if ($StillEnabled.Count -gt 0) {

        throw "Quedaron perfiles de firewall habilitados: $($StillEnabled.Name -join ', ')"
    }


    Write-Log "Firewall deshabilitado en Domain, Private y Public." "OK"

    Write-Log "La directiva local mantiene el firewall apagado despues de reiniciar." "OK"
}



function Enable-RemoteDesktopWithoutNla {

    Write-Log "Habilitando Escritorio remoto sin autenticacion de nivel de red..."


    Set-RegistryDword `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0


    Set-RegistryDword `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication" `
        -Value 0


    Set-RegistryDword `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "fEnableWinStation" `
        -Value 1


    Set-RegistryDword `
        -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
        -Name "fDenyTSConnections" `
        -Value 0


    Set-RegistryDword `
        -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
        -Name "UserAuthentication" `
        -Value 0


    Set-Service -Name "TermService" -StartupType Automatic

    $Service = Get-Service -Name "TermService"


    if ($Service.Status -ne "Running") {

        Start-Service -Name "TermService"
    }


    foreach ($Group in @("Remote Desktop", "Escritorio remoto")) {

        try {

            Enable-NetFirewallRule -DisplayGroup $Group -ErrorAction Stop

        }
        catch {
        }
    }


    $Deny = Get-ItemProperty `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections"


    $Nla = Get-ItemProperty `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "UserAuthentication"


    if ($Deny.fDenyTSConnections -ne 0 -or $Nla.UserAuthentication -ne 0) {

        throw "RDP no quedo habilitado sin autenticacion de nivel de red."
    }


    Write-Log "Escritorio remoto habilitado." "OK"

    Write-Log "Autenticacion a nivel de red desmarcada." "OK"
}



function Disable-IPv6Completely {

    Write-Log "Deshabilitando IPv6..."


    # 0xFF deshabilita IPv6 en todas las interfaces, salvo el loopback,
    # que Windows conserva. El valor se aplica al reiniciar.
    Set-RegistryDword `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" `
        -Name "DisabledComponents" `
        -Value 255


    $Bindings = @(
        Get-NetAdapterBinding `
            -ComponentID "ms_tcpip6" `
            -ErrorAction SilentlyContinue
    )


    foreach ($Binding in $Bindings) {

        if ($Binding.Enabled) {

            Disable-NetAdapterBinding `
                -Name $Binding.Name `
                -ComponentID "ms_tcpip6" `
                -ErrorAction SilentlyContinue
        }
    }


    $StillBound = @(
        Get-NetAdapterBinding `
            -ComponentID "ms_tcpip6" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq $true }
    )


    if ($StillBound.Count -gt 0) {

        Write-Log `
            "IPv6 sigue enlazado en: $($StillBound.Name -join ', ')" `
            "WARN"
    }


    $Components = (
        Get-ItemProperty `
            -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" `
            -Name "DisabledComponents"
    ).DisabledComponents


    if ([int]$Components -ne 255) {

        throw "DisabledComponents no quedo en 255."
    }


    Write-Log "IPv6 deshabilitado en los adaptadores." "OK"

    Write-Log "DisabledComponents=255. Reinicie el equipo para completar el cambio." "WARN"
}



function Set-TaskbarLayoutOnKey {

    param (
        [Parameter(Mandatory = $true)]
        [string]$RegistryRoot
    )


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
    }


    if ($Script:AlignLeft) {

        Set-RegistryDword `
            -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
            -Name "TaskbarAl" `
            -Value 0
    }
}



function Invoke-RegistryCommand {

    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )


    $Reg = "$env:SystemRoot\System32\reg.exe"


    if (
        [Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess
    ) {

        $Reg = "$env:SystemRoot\Sysnative\reg.exe"
    }


    $PreviousErrorAction = $ErrorActionPreference

    $ErrorActionPreference = "Continue"


    try {

        & $Reg @ArgumentList > $null

        return $LASTEXITCODE
    }
    finally {

        $ErrorActionPreference = $PreviousErrorAction
    }
}



function Dismount-UserHive {

    param (
        [Parameter(Mandatory = $true)]
        [string]$HiveName
    )


    $Code = 1


    for ($Try = 1; $Try -le 5; $Try++) {

        [gc]::Collect()

        [gc]::WaitForPendingFinalizers()

        $Code = Invoke-RegistryCommand -ArgumentList @("unload", "HKU\$HiveName")


        if ($Code -eq 0) {

            return
        }


        Start-Sleep -Seconds 1
    }


    throw "No se pudo cerrar el perfil de registro $HiveName."
}



function Set-OfflineTaskbarLayout {

    param (

        [Parameter(Mandatory = $true)]
        [string]$NtUserPath,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )


    $HiveName = "CustomWinTaskbar"

    $Loaded = "Registry::HKEY_USERS\$HiveName"


    if (Test-Path -LiteralPath $Loaded) {

        Dismount-UserHive -HiveName $HiveName
    }


    $Code = Invoke-RegistryCommand -ArgumentList @(
        "load",
        "HKU\$HiveName",
        $NtUserPath
    )


    if ($Code -ne 0) {

        throw "No se pudo abrir el perfil de $Label."
    }


    try {

        Set-TaskbarLayoutOnKey -RegistryRoot $Loaded

        Write-Log "Barra de tareas aplicada a $Label." "OK"
    }
    finally {

        Dismount-UserHive -HiveName $HiveName
    }
}



function Stop-ExplorerShell {

    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {

        $Running = @(Get-Process -Name "explorer" -ErrorAction SilentlyContinue)

        if ($Running.Count -eq 0) {

            return
        }


        foreach ($Process in $Running) {

            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }


        Start-Sleep -Milliseconds 200
    }
}



function Start-ExplorerShell {

    if (Get-Process -Name "explorer" -ErrorAction SilentlyContinue) {

        return
    }


    $TaskName = "CustomWinExplorer"

    $Schtasks = "$env:SystemRoot\System32\schtasks.exe"


    if (
        [Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess
    ) {

        $Schtasks = "$env:SystemRoot\Sysnative\schtasks.exe"
    }


    $ExplorerPath = "$env:SystemRoot\explorer.exe"

    $XmlPath = Join-Path $env:TEMP "CustomWinExplorer.xml"

    # Sin /ST: en Windows en espanol esa hora se rechazaba y el
    # Explorador quedaba elevado. LeastPrivilege usa el token limitado.
    $Xml = '<?xml version="1.0" encoding="UTF-16"?>' +
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<Principals><Principal id="Author">' +
        '<LogonType>InteractiveToken</LogonType>' +
        '<RunLevel>LeastPrivilege</RunLevel>' +
        '</Principal></Principals>' +
        '<Settings>' +
        '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' +
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' +
        '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' +
        '<AllowHardTerminate>true</AllowHardTerminate>' +
        '<StartWhenAvailable>false</StartWhenAvailable>' +
        '<Enabled>true</Enabled>' +
        '<Hidden>true</Hidden>' +
        '<AllowStartOnDemand>true</AllowStartOnDemand>' +
        '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' +
        '</Settings>' +
        '<Actions Context="Author"><Exec><Command>' +
        $ExplorerPath +
        '</Command></Exec></Actions></Task>'

    $Started = $false

    $Detail = ""

    $PreviousErrorAction = $ErrorActionPreference

    $ErrorActionPreference = "Continue"


    try {

        [System.IO.File]::WriteAllText(
            $XmlPath,
            $Xml,
            [System.Text.Encoding]::Unicode
        )

        $CreateOutput = & $Schtasks /Create /TN $TaskName /XML $XmlPath /F 2>&1


        if ($LASTEXITCODE -eq 0) {

            $RunOutput = & $Schtasks /Run /TN $TaskName 2>&1


            for ($Wait = 1; $Wait -le 40; $Wait++) {

                if (Get-Process -Name "explorer" -ErrorAction SilentlyContinue) {

                    $Started = $true

                    break
                }


                Start-Sleep -Milliseconds 250
            }


            if (-not $Started) {

                $Detail = (($RunOutput | Out-String)).Trim()
            }
        }
        else {

            $Detail = (($CreateOutput | Out-String)).Trim()
        }
    }
    catch {

        $Detail = [string]$_.Exception.Message
    }
    finally {

        & $Schtasks /Delete /TN $TaskName /F 2>&1 | Out-Null

        Remove-Item -LiteralPath $XmlPath -Force -ErrorAction SilentlyContinue

        $ErrorActionPreference = $PreviousErrorAction
    }


    if ($Started -or (Get-Process -Name "explorer" -ErrorAction SilentlyContinue)) {

        return
    }


    if (-not [string]::IsNullOrWhiteSpace($Detail)) {

        Write-Log "No se pudo iniciar el Explorador sin elevacion: $Detail" "WARN"
    }


    Start-Process -FilePath $ExplorerPath

    Write-Log "El Explorador se inicio desde la consola elevada." "WARN"
}



function Test-TaskbarLayoutApplied {

    if ($Script:HideSearch) {

        $SearchMode = (
            Get-ItemProperty `
                -LiteralPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
                -Name "SearchboxTaskbarMode"
        ).SearchboxTaskbarMode

        $SearchCache = (
            Get-ItemProperty `
                -LiteralPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
                -Name "SearchboxTaskbarModeCache"
        ).SearchboxTaskbarModeCache


        if ([int]$SearchMode -ne 0 -or [int]$SearchCache -ne 1) {

            return $false
        }
    }


    if ($Script:AlignLeft) {

        $Alignment = (
            Get-ItemProperty `
                -LiteralPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
                -Name "TaskbarAl"
        ).TaskbarAl


        if ([int]$Alignment -ne 0) {

            return $false
        }
    }


    return $true
}



function Set-TaskbarLayout {

    if ($Script:HideSearch -and $Script:AlignLeft) {

        Write-Log "Ocultando la busqueda y alineando la barra de tareas a la izquierda..."

    }
    elseif ($Script:HideSearch) {

        Write-Log "Ocultando el campo de busqueda de la barra de tareas..."

    }
    else {

        Write-Log "Alineando los iconos de la barra de tareas a la izquierda..."
    }


    $LiveRoots = @("HKCU:")


    $ProfileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    foreach ($Profile in @(Get-ChildItem -LiteralPath $ProfileList -ErrorAction SilentlyContinue)) {

        $Sid = $Profile.PSChildName

        if ($Sid -notlike "S-1-5-21-*" -and $Sid -notlike "S-1-12-1-*") {

            continue
        }


        $Image = (
            Get-ItemProperty `
                -LiteralPath $Profile.PSPath `
                -Name "ProfileImagePath" `
                -ErrorAction SilentlyContinue
        ).ProfileImagePath


        if ([string]::IsNullOrWhiteSpace($Image)) {

            continue
        }


        $Image = [Environment]::ExpandEnvironmentVariables([string]$Image)

        $NtUser = Join-Path $Image "NTUSER.DAT"

        if (-not (Test-Path -LiteralPath $NtUser)) {

            continue
        }


        $LoadedUser = "Registry::HKEY_USERS\$Sid"


        try {

            if (Test-Path -LiteralPath $LoadedUser) {

                if ($LiveRoots -notcontains $LoadedUser) {

                    $LiveRoots += $LoadedUser
                }

                continue
            }


            Set-OfflineTaskbarLayout -NtUserPath $NtUser -Label $Image
        }
        catch {

            Write-Log "No se pudo aplicar la barra de tareas en ${Image}: $($_.Exception.Message)" "WARN"
        }
    }


    $DefaultUser = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"

    if (Test-Path -LiteralPath $DefaultUser) {

        Set-OfflineTaskbarLayout -NtUserPath $DefaultUser -Label "usuarios nuevos"
    }


    # El Explorador guarda la barra que tiene en memoria al cerrarse.
    # Primero se cierra y despues se escribe la configuracion.
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {

        Stop-ExplorerShell


        foreach ($LiveRoot in $LiveRoots) {

            if ($LiveRoot -eq "HKCU:" -or (Test-Path -LiteralPath $LiveRoot)) {

                Set-TaskbarLayoutOnKey -RegistryRoot $LiveRoot
            }
        }


        Start-Sleep -Milliseconds 400


        if (-not (Get-Process -Name "explorer" -ErrorAction SilentlyContinue)) {

            break
        }
    }


    Start-ExplorerShell

    Start-Sleep -Seconds 2


    Set-TaskbarLayoutOnKey -RegistryRoot "HKCU:"


    if (-not (Test-TaskbarLayoutApplied)) {

        Stop-ExplorerShell

        Set-TaskbarLayoutOnKey -RegistryRoot "HKCU:"

        Start-ExplorerShell

        Start-Sleep -Seconds 2

        Set-TaskbarLayoutOnKey -RegistryRoot "HKCU:"
    }


    if (-not (Test-TaskbarLayoutApplied)) {

        throw "La barra de tareas no quedo configurada."
    }


    if ($Script:HideSearch) {

        Write-Log "Campo de busqueda de la barra de tareas oculto." "OK"
    }


    if ($Script:AlignLeft) {

        Write-Log "Iconos de la barra de tareas alineados a la izquierda." "OK"
    }
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



function Get-AnyDeskServiceExecutable {

    $Service = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='AnyDesk'" `
        -ErrorAction SilentlyContinue


    if (-not $Service -or -not $Service.PathName) {

        return $null
    }


    $PathName = [string]$Service.PathName

    $Executable = $null


    if ($PathName -match '^"([^"]+\.exe)"') {

        $Executable = $Matches[1]

    }
    elseif ($PathName -match '^(\S+\.exe)') {

        $Executable = $Matches[1]
    }


    if (
        $Executable -and
        (Test-Path -LiteralPath $Executable) -and
        ($Executable -notlike "$TempDir\*")
    ) {

        return $Executable
    }


    return $null
}



function Find-InstalledAnyDesk {

    $Paths = @(
        (Join-Path $InstallDir "AnyDesk.exe")
    )


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


    $FromService = Get-AnyDeskServiceExecutable

    if ($FromService) {

        $Paths += $FromService
    }


    foreach ($Path in $Paths) {

        if ($Path -and (Test-Path -LiteralPath $Path)) {

            return $Path
        }
    }


    return $null
}



function Wait-InstalledAnyDeskFile {

    param (
        [int]$TimeoutSeconds = 60
    )


    $Elapsed = 0


    while ($Elapsed -lt $TimeoutSeconds) {

        $Found = Find-InstalledAnyDesk

        if ($Found) {

            return $Found
        }


        Start-Sleep -Seconds 2

        $Elapsed += 2
    }


    return Find-InstalledAnyDesk
}



function Remove-AnyDeskServiceRecord {

    $ServicePid = Get-AnyDeskServicePid

    $Service = Get-AnyDeskService


    if ($Service -and $Service.Status -ne "Stopped") {

        try {

            Stop-Service `
                -Name "AnyDesk" `
                -Force `
                -ErrorAction Stop


            $Service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(20)
            )

        }
        catch {

            Write-Log `
                "No se pudo detener el servicio antes de reemplazarlo: $($_.Exception.Message)" `
                "WARN"
        }
    }


    if (
        $ServicePid -and
        $ServicePid -ne 0
    ) {

        Stop-Process `
            -Id $ServicePid `
            -Force `
            -ErrorAction SilentlyContinue
    }


    & "$env:SystemRoot\System32\sc.exe" delete AnyDesk |
        Out-Null


    $Elapsed = 0


    while ($Elapsed -lt 20) {

        if (-not (Get-AnyDeskService)) {

            Write-Log `
                "Servicio anterior eliminado. Se instalara de nuevo." `
                "OK"

            return
        }


        Start-Sleep -Seconds 1

        $Elapsed++
    }


    Write-Log `
        "El servicio anterior sigue registrado. El instalador intentara reemplazarlo." `
        "WARN"
}



function Receive-AnyDeskInstaller {

    $NeedsDownload = $true


    if (Test-Path -LiteralPath $Installer) {

        $Existing = Get-Item -LiteralPath $Installer

        if ($Existing.Length -ge 1MB) {

            $ExistingSignature = Get-AuthenticodeSignature $Installer

            if ($ExistingSignature.Status -eq "Valid") {

                $NeedsDownload = $false

                Write-Log `
                    ("Instalador ya presente. Tamano: {0:N2} MB" -f ($Existing.Length / 1MB)) `
                    "OK"
            }
        }
    }


    if ($NeedsDownload) {

        Write-Log `
            "No se encontro un instalador valido. Se descargara AnyDesk."


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


    if ($NeedsDownload) {

        Write-Log `
            ("Descarga completada. Tamano: {0:N2} MB" -f ($DownloadedFile.Length / 1MB)) `
            "OK"
    }


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
}



function Start-AnyDeskInstallerProcess {

    param (
        [string[]]$ArgumentList
    )


    $Quoted = foreach ($Argument in $ArgumentList) {

        if ($Argument -match '\s|"') {

            '"' + ($Argument -replace '"', '\"') + '"'

        }
        else {

            $Argument
        }
    }


    $ArgumentString = $Quoted -join " "


    Write-Log `
        "Comando de instalacion: $ArgumentString"


    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo

    $StartInfo.FileName = $Installer

    $StartInfo.Arguments = $ArgumentString

    $StartInfo.UseShellExecute = $false

    $StartInfo.CreateNoWindow = $true


    $Process = New-Object System.Diagnostics.Process

    $Process.StartInfo = $StartInfo


    if (-not $Process.Start()) {

        throw "No se pudo iniciar el instalador."
    }


    return $Process
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

    if ($Script:InitialService -and -not $Script:ReplacedInstall) {

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


    if ((-not $Script:InitialService) -or $Script:ReplacedInstall) {

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


    # Siempre lanza. El catch de Install-UnattendedAnyDesk lo convierte
    # en un resultado y sigue con el resto de CustomWin. exit cerraria
    # la consola de irm | iex.
    throw "AnyDeskDeployExit:$Code"
}



function Install-UnattendedAnyDesk {

    $script:AnyDeskExitCode = 1

    $ShowUserInterface = $false


    foreach ($ScopeName in @("Global", "Script")) {

        $ExistingShow = Get-Variable `
            -Name "ShowUserInterface" `
            -Scope $ScopeName `
            -ErrorAction SilentlyContinue


        if ($ExistingShow -and [bool]$ExistingShow.Value) {

            $ShowUserInterface = $true

            break
        }
    }


    $PasswordText = ""


    foreach ($ScopeName in @("Global", "Script")) {

        $ExistingPassword = Get-Variable `
            -Name "UnattendedPassword" `
            -Scope $ScopeName `
            -ErrorAction SilentlyContinue


        if (
            $ExistingPassword -and
            -not [string]::IsNullOrWhiteSpace([string]$ExistingPassword.Value)
        ) {

            $PasswordText = [string]$ExistingPassword.Value

            break
        }
    }


    $UnattendedPassword = $PasswordText


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


$LogDir = $script:LogDir

$LogFile = $script:LogFile


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
        "Servicio AnyDesk detectado. Sera reemplazado." `
        "WARN"


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
# DESCARGAR E INSTALAR O REEMPLAZAR
# ============================================================

$Script:ReplacedInstall = $false

$Script:RemoveFirst = $false


if ($InitialService -or $Script:InstalledExe) {

    $Script:ReplacedInstall = $true

    $Script:RemoveFirst = [bool]$Script:InstalledExe


    if (-not $Script:InstalledExe) {

        Write-Log `
            "Hay un servicio AnyDesk sin ejecutable en la carpeta de instalacion." `
            "WARN"


        Remove-AnyDeskServiceRecord

    }
    else {

        Write-Log `
            "Se reemplazara la instalacion de $($Script:InstalledExe)." `
            "WARN"
    }
}


Receive-AnyDeskInstaller


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


    # La ruta va entre comillas en ProcessStartInfo. Start-Process de
    # Windows PowerShell 5.1 parte "C:\Program Files (x86)\AnyDesk".
    $InstallArguments = @(
        "--install",
        $InstallDir
    )


    if ($Script:RemoveFirst) {

        $InstallArguments += "--remove-first"
    }


    $InstallArguments += "--silent"


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

        $InstallProcess = Start-AnyDeskInstallerProcess `
            -ArgumentList $InstallArguments


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



    if ($Script:ReplacedInstall) {

        Write-Log `
            "Servicio AnyDesk reemplazado." `
            "OK"

    }
    else {

        Write-Log `
            "Servicio AnyDesk creado correctamente." `
            "OK"
    }


    Write-Log `
        "Esperando el ejecutable en $InstallDir..."


    $Script:InstalledExe = Wait-InstalledAnyDeskFile `
        -TimeoutSeconds 60


    if (-not $Script:InstalledExe) {

        Write-Log `
            "El servicio existe pero no se encontro el ejecutable instalado." `
            "ERROR"


        Stop-AnyDeskDeploy -Code 26
    }



    Write-Log `
        "AnyDesk instalado en: $Script:InstalledExe" `
        "OK"



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

    if ($ShowUserInterface) {

        Write-Log `
            "Servicio ya se encuentra Running." `
            "OK"

    }
    elseif ((-not $Script:InitialService) -or $Script:ReplacedInstall) {

        Write-Log `
            "Servicio en ejecucion. Se reiniciara una vez al aplicar la interfaz oculta." `
            "OK"

    }
    else {

        Write-Log `
            "Servicio ya se encuentra Running." `
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

        $script:AnyDeskExitCode = $DeployExitCode

        return
    }


    $UnattendedPassword = $null

    $SecurePassword = $null

    throw
}
}


function Get-CustomWinChoices {

    return @(
        @{
            Id = "Notepad++"
            Text = "Notepad++ (ultima version, se omite si ya esta)"
        },
        @{
            Id = "7-Zip"
            Text = "7-Zip (ultima version, se omite si ya esta)"
        },
        @{
            Id = "Firefox"
            Text = "Firefox (ultima version, se omite si ya esta)"
        },
        @{
            Id = "Google Chrome"
            Text = "Google Chrome (ultima version, se omite si ya esta)"
        },
        @{
            Id = "PuTTY"
            Text = "PuTTY (ultima version, se omite si ya esta)"
        },
        @{
            Id = "VMware Tools"
            Text = "VMware Tools (ultima version, se omite si ya esta)"
        },
        @{
            Id = "AnyDesk"
            Text = "AnyDesk oculto, con password de acceso desatendido"
        },
        @{
            Id = "Firewall"
            Text = "Deshabilitar el Firewall de Windows en todas las redes"
        },
        @{
            Id = "Rdp"
            Text = "Habilitar Escritorio remoto sin autenticacion de nivel de red"
        },
        @{
            Id = "IPv6"
            Text = "Deshabilitar IPv6 en todo el sistema"
        },
        @{
            Id = "Search"
            Text = "Ocultar el campo de busqueda de la barra de tareas"
        },
        @{
            Id = "Taskbar"
            Text = "Alinear los iconos de la barra de tareas a la izquierda"
        }
    )
}



function Show-CustomWinConsole {

    $Choices = @(Get-CustomWinChoices)

    $Checked = @{}


    foreach ($Choice in $Choices) {

        $Checked[$Choice.Id] = $true
    }


    while ($true) {

        Write-Host ""
        Write-Host "Numero: tilda o destilda. A: todas. N: ninguna. Enter: aplicar. Q: cancelar."
        Write-Host ""


        for ($Index = 0; $Index -lt $Choices.Count; $Index++) {

            $Mark = " "

            if ($Checked[$Choices[$Index].Id]) {

                $Mark = "X"
            }


            Write-Host ("[{0}] {1}. {2}" -f $Mark, ($Index + 1), $Choices[$Index].Text)
        }


        $Answer = Read-Host "Opcion"


        if ([string]::IsNullOrWhiteSpace($Answer)) {

            $Picked = @(
                $Choices |
                    Where-Object { $Checked[$_.Id] } |
                    ForEach-Object { $_.Id }
            )


            if ($Picked.Count -eq 0) {

                Write-Host "Tilda al menos una opcion."

                continue
            }


            return ,$Picked
        }


        if ($Answer -eq "Q" -or $Answer -eq "q") {

            return $null
        }


        if ($Answer -eq "A" -or $Answer -eq "a") {

            foreach ($Choice in $Choices) {

                $Checked[$Choice.Id] = $true
            }

            continue
        }


        if ($Answer -eq "N" -or $Answer -eq "n") {

            foreach ($Choice in $Choices) {

                $Checked[$Choice.Id] = $false
            }

            continue
        }


        $Number = 0


        if (
            [int]::TryParse($Answer, [ref]$Number) -and
            $Number -ge 1 -and
            $Number -le $Choices.Count
        ) {

            $Id = $Choices[$Number - 1].Id

            $Checked[$Id] = -not $Checked[$Id]
        }
    }
}



function Show-CustomWinForm {

    $Choices = @(Get-CustomWinChoices)

    $Form = New-Object System.Windows.Forms.Form

    $Form.Text = "CustomWin"

    $Form.StartPosition = "CenterScreen"

    $Form.FormBorderStyle = "FixedDialog"

    $Form.MaximizeBox = $false

    $Form.MinimizeBox = $false

    $Form.ClientSize = New-Object System.Drawing.Size(640, 560)

    $Form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $Form.TopMost = $true


    $Title = New-Object System.Windows.Forms.Label

    $Title.Text = "Elegi que queres aplicar"

    $Title.AutoSize = $true

    $Title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)

    $Title.Location = New-Object System.Drawing.Point(24, 18)

    $Form.Controls.Add($Title)


    $Hint = New-Object System.Windows.Forms.Label

    $Hint.Text = "Tilda las opciones y presiona Aplicar. Lo que no este tildado no se modifica."

    $Hint.AutoSize = $false

    $Hint.Size = New-Object System.Drawing.Size(590, 28)

    $Hint.Location = New-Object System.Drawing.Point(24, 56)

    $Form.Controls.Add($Hint)


    $List = New-Object System.Windows.Forms.CheckedListBox

    $List.Location = New-Object System.Drawing.Point(24, 96)

    $List.Size = New-Object System.Drawing.Size(592, 360)

    $List.CheckOnClick = $true

    $List.BorderStyle = "FixedSingle"

    $List.Font = New-Object System.Drawing.Font("Segoe UI", 11)


    foreach ($Choice in $Choices) {

        [void]$List.Items.Add($Choice.Text, $true)
    }


    $Form.Controls.Add($List)


    $MarkAll = New-Object System.Windows.Forms.Button

    $MarkAll.Text = "Marcar todo"

    $MarkAll.Location = New-Object System.Drawing.Point(24, 476)

    $MarkAll.Size = New-Object System.Drawing.Size(130, 36)

    $MarkAll.Add_Click({

        for ($Index = 0; $Index -lt $List.Items.Count; $Index++) {

            $List.SetItemChecked($Index, $true)
        }

    }.GetNewClosure())

    $Form.Controls.Add($MarkAll)


    $ClearAll = New-Object System.Windows.Forms.Button

    $ClearAll.Text = "Desmarcar todo"

    $ClearAll.Location = New-Object System.Drawing.Point(164, 476)

    $ClearAll.Size = New-Object System.Drawing.Size(140, 36)

    $ClearAll.Add_Click({

        for ($Index = 0; $Index -lt $List.Items.Count; $Index++) {

            $List.SetItemChecked($Index, $false)
        }

    }.GetNewClosure())

    $Form.Controls.Add($ClearAll)


    $Cancel = New-Object System.Windows.Forms.Button

    $Cancel.Text = "Cancelar"

    $Cancel.Location = New-Object System.Drawing.Point(360, 476)

    $Cancel.Size = New-Object System.Drawing.Size(120, 36)

    $Cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $Form.CancelButton = $Cancel

    $Form.Controls.Add($Cancel)


    $Apply = New-Object System.Windows.Forms.Button

    $Apply.Text = "Aplicar"

    $Apply.Location = New-Object System.Drawing.Point(490, 476)

    $Apply.Size = New-Object System.Drawing.Size(126, 36)

    $Apply.Add_Click({

        $AnyChecked = $false


        for ($Index = 0; $Index -lt $List.Items.Count; $Index++) {

            if ($List.GetItemChecked($Index)) {

                $AnyChecked = $true
            }
        }


        if (-not $AnyChecked) {

            [void][System.Windows.Forms.MessageBox]::Show(
                "Tilda al menos una opcion.",
                "CustomWin"
            )

            return
        }


        $Form.DialogResult = [System.Windows.Forms.DialogResult]::OK

        $Form.Close()

    }.GetNewClosure())

    $Form.Controls.Add($Apply)

    $Form.AcceptButton = $Apply


    $Result = $Form.ShowDialog()

    $Picked = New-Object System.Collections.Generic.List[string]


    if ($Result -eq [System.Windows.Forms.DialogResult]::OK) {

        for ($Index = 0; $Index -lt $Choices.Count; $Index++) {

            if ($List.GetItemChecked($Index)) {

                $Picked.Add($Choices[$Index].Id)
            }
        }
    }


    $Form.Dispose()


    if ($Result -ne [System.Windows.Forms.DialogResult]::OK -or $Picked.Count -eq 0) {

        return $null
    }


    return ,$Picked.ToArray()
}



function Read-CustomWinSelection {

    $Apartment = [Threading.Thread]::CurrentThread.ApartmentState


    if ("$Apartment" -eq "STA") {

        try {

            Add-Type -AssemblyName System.Windows.Forms

            Add-Type -AssemblyName System.Drawing

            [System.Windows.Forms.Application]::EnableVisualStyles()

            $Picked = Show-CustomWinForm


            if ($null -eq $Picked) {

                return $null
            }


            return ,$Picked
        }
        catch {

            Write-Log "No se pudo abrir la ventana de seleccion: $($_.Exception.Message)" "WARN"
        }
    }


    $Picked = Show-CustomWinConsole


    if ($null -eq $Picked) {

        return $null
    }


    return ,$Picked
}



try {

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null


    Write-Host ""
    Write-Host "============================================================"
    Write-Host " CUSTOMWIN"
    Write-Host "============================================================"
    Write-Host ""


    Write-Log "Inicio de CustomWin."

    Write-Log "Revision: 20261008c"

    Write-Log "Equipo: $env:COMPUTERNAME"

    Write-Log "Usuario: $env:USERDOMAIN\$env:USERNAME"


    if (-not (Test-Administrator)) {

        Write-Log "PowerShell no esta ejecutandose como Administrador." "ERROR"

        Write-Host ""
        Write-Host "Ejecute PowerShell como Administrador."
        Write-Host ""

        Stop-CustomWin -Code 10
    }


    Write-Log "Privilegios de administrador confirmados." "OK"


    $Selected = Read-CustomWinSelection


    if ($null -eq $Selected) {

        Write-Host ""
        Write-Host "Cancelado. No se modifico nada."
        Write-Host ""

        Write-Log "El usuario cancelo la seleccion." "WARN"

        Stop-CustomWin -Code 0
    }


    $Selected = @($Selected)

    Write-Log ("Opciones elegidas: " + ($Selected -join ", "))


    $Architecture = Get-OsArchitecture

    Write-Log "Arquitectura: $Architecture"


    if ($Selected -contains "AnyDesk") {

        try {

            Install-UnattendedAnyDesk


            if ([int]$script:AnyDeskExitCode -ne 0) {

                Add-DeployFailure "AnyDesk: no se completo. Codigo $($script:AnyDeskExitCode)."
            }

        }
        catch {

            $FailLine = $_.InvocationInfo.ScriptLineNumber

            Add-DeployFailure "AnyDesk (linea ${FailLine}): $($_.Exception.Message)"
        }
    }


    $AppNames = @(
        $Selected | Where-Object {
            $_ -in @("Notepad++", "7-Zip", "Firefox", "Google Chrome", "PuTTY", "VMware Tools")
        }
    )


    if ($AppNames.Count -gt 0) {

        Install-BasicApplications -Architecture $Architecture -Names $AppNames
    }


    if ($Selected -contains "Firewall") {

        try {

            Disable-WindowsFirewallPermanently

        }
        catch {

            Add-DeployFailure "Firewall: $($_.Exception.Message)"
        }
    }


    if ($Selected -contains "Rdp") {

        try {

            Enable-RemoteDesktopWithoutNla

        }
        catch {

            Add-DeployFailure "Escritorio remoto: $($_.Exception.Message)"
        }
    }


    if ($Selected -contains "IPv6") {

        try {

            Disable-IPv6Completely

        }
        catch {

            Add-DeployFailure "IPv6: $($_.Exception.Message)"
        }
    }


    $Script:HideSearch = $Selected -contains "Search"

    $Script:AlignLeft = $Selected -contains "Taskbar"


    if ($Script:HideSearch -or $Script:AlignLeft) {

        try {

            Set-TaskbarLayout

        }
        catch {

            Add-DeployFailure "Barra de tareas: $($_.Exception.Message)"
        }
    }


    Get-ChildItem -LiteralPath $TempDir -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue


    Write-Host ""
    Write-Host "============================================================"
    Write-Host " RESULTADO"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "Log: $LogFile"
    Write-Host ""


    if ($Script:Failures.Count -eq 0) {

        if ($AppNames.Count -gt 0) {

            Write-Host "Programas elegidos               : INSTALADOS O YA PRESENTES"
        }


        if ($Selected -contains "AnyDesk") {

            Write-Host "AnyDesk                         : INSTALADO"

            if ($Script:NewID) {

                Write-Host "AnyDesk ID                      : $Script:NewID"
            }
        }


        if ($Selected -contains "Firewall") {

            Write-Host "Firewall de Windows             : DESHABILITADO"
        }


        if ($Selected -contains "Rdp") {

            Write-Host "Escritorio remoto               : HABILITADO"
            Write-Host "Autenticacion a nivel de red    : DESMARCADA"
        }


        if ($Selected -contains "IPv6") {

            Write-Host "IPv6                            : DESHABILITADO AL REINICIAR"
        }


        if ($Selected -contains "Search") {

            Write-Host "Busqueda en la barra de tareas : OCULTA"
        }


        if ($Selected -contains "Taskbar") {

            Write-Host "Alineacion de la barra         : IZQUIERDA"
        }


        Write-Host ""
        Write-Host "CUSTOMWIN FINALIZADO" -ForegroundColor Green
        Write-Host ""


        if ($Selected -contains "IPv6") {

            Write-Host "Reinicie el equipo para completar la deshabilitacion de IPv6."
            Write-Host ""
        }


        Write-Log "CustomWin finalizado." "OK"

        Stop-CustomWin -Code 0
    }


    Write-Host "CUSTOMWIN FINALIZADO CON ERRORES" -ForegroundColor Yellow

    Write-Host ""

    foreach ($Failure in $Script:Failures) {

        Write-Host " - $Failure"
    }

    Write-Host ""
    Write-Host "Revise: $LogFile"
    Write-Host ""

    Write-Log "CustomWin finalizado con errores." "WARN"

    Stop-CustomWin -Code 1

}
catch {

    $DeployMessage = [string]$_.Exception.Message


    if ($DeployMessage -like "CustomWinExit:*") {

        $DeployExitCode = 1

        $DeployParsedCode = 0


        if (
            [int]::TryParse(
                ($DeployMessage -replace "^CustomWinExit:", ""),
                [ref]$DeployParsedCode
            )
        ) {

            $DeployExitCode = $DeployParsedCode
        }


        $global:LASTEXITCODE = $DeployExitCode


        if ($PSCommandPath) {

            exit $DeployExitCode
        }


        return
    }


    Write-Log "Error no controlado: $DeployMessage" "ERROR"

    throw
}
