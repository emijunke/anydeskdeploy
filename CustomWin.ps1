<#
.SYNOPSIS
    Menu para elegir que personalizar en Windows.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Al ejecutarse muestra una lista para tildar que se quiere aplicar.
    - Puede instalar Notepad++, 7-Zip, Firefox y Chrome.
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


    if ($LogFile) {

        Add-Content -Path $LogFile -Value $Line -Encoding UTF8
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

        [string]$Sha256
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

        $ExitCode = Invoke-InstallerProcess `
            -FilePath $Destination `
            -Arguments "/S"
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



function Get-CandidatePaths {

    param (
        [string[]]$RelativePaths,
        [string[]]$ExtraPaths
    )


    $Roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432
    )

    $Paths = New-Object System.Collections.Generic.List[string]


    foreach ($Root in $Roots) {

        if ([string]::IsNullOrWhiteSpace($Root)) {

            continue
        }


        foreach ($RelativePath in $RelativePaths) {

            if ([string]::IsNullOrWhiteSpace($RelativePath)) {

                continue
            }


            $FullPath = Join-Path $Root $RelativePath

            if (-not $Paths.Contains($FullPath)) {

                $Paths.Add($FullPath)
            }
        }
    }


    foreach ($ExtraPath in $ExtraPaths) {

        if ([string]::IsNullOrWhiteSpace($ExtraPath)) {

            continue
        }


        if (-not $Paths.Contains($ExtraPath)) {

            $Paths.Add($ExtraPath)
        }
    }


    return @($Paths)
}



function Get-UninstallEntries {

    $Entries = New-Object System.Collections.Generic.List[object]

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


                    $Entries.Add([pscustomobject]@{
                        DisplayName    = $DisplayName.Trim()
                        DisplayVersion = $DisplayVersion.Trim()
                    })
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


    return @($Entries)
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


    $Candidates = @(
        Get-CandidatePaths `
            -RelativePaths $RelativePaths `
            -ExtraPaths $ExtraPaths
    )


    foreach ($Candidate in $Candidates) {

        if (Test-Path -LiteralPath $Candidate) {

            return [pscustomobject]@{
                Version  = Get-FileVersionText -Path $Candidate
                Location = $Candidate
            }
        }
    }


    foreach ($Entry in @(Get-UninstallEntries)) {

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
            }


            Install-SetupPackage `
                -Name $Package.Name `
                -Uri $Url `
                -FileName $Package.File `
                -Kind $Package.Kind `
                -Sha256 $Sha256

        }
        catch {

            Add-DeployFailure "$($Package.Name): $($_.Exception.Message)"
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


    $PreviousErrorAction = $ErrorActionPreference

    $ErrorActionPreference = "Continue"

    $Started = $false


    try {

        & $Schtasks /Create /TN $TaskName /TR "$env:SystemRoot\explorer.exe" /SC ONCE /ST 00:00 /F /RL LIMITED > $null


        if ($LASTEXITCODE -eq 0) {

            & $Schtasks /Run /TN $TaskName > $null


            for ($Wait = 1; $Wait -le 20; $Wait++) {

                if (Get-Process -Name "explorer" -ErrorAction SilentlyContinue) {

                    $Started = $true

                    break
                }


                Start-Sleep -Milliseconds 250
            }
        }
    }
    finally {

        & $Schtasks /Delete /TN $TaskName /F > $null

        $ErrorActionPreference = $PreviousErrorAction
    }


    if ($Started -or (Get-Process -Name "explorer" -ErrorAction SilentlyContinue)) {

        return
    }


    Start-Process -FilePath "$env:SystemRoot\explorer.exe"

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


    $LiveRoots = New-Object System.Collections.Generic.List[string]

    $LiveRoots.Add("HKCU:")


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

                if (-not $LiveRoots.Contains($LoadedUser)) {

                    $LiveRoots.Add($LoadedUser)
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


    $AppNames = @(
        $Selected | Where-Object {
            $_ -in @("Notepad++", "7-Zip", "Firefox", "Google Chrome")
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
