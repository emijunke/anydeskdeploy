<#
.SYNOPSIS
    Instalacion basica desatendida de Windows.

.DESCRIPTION
    - Requiere PowerShell ejecutado como Administrador.
    - Instala la ultima version de Notepad++, 7-Zip, Firefox y Chrome.
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

.EXAMPLE
    .\Install-Win-Basic.ps1

.EXAMPLE
    irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-Win-Basic.ps1" | iex
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


$LogDir = "C:\ProgramData\WinBasicDeploy"

$LogFile = Join-Path $LogDir "Install-Win-Basic.log"

$TempDir = Join-Path $env:TEMP "WinBasicDeploy"

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



function Stop-WinBasicDeploy {

    param (
        [int]$Code
    )


    if ([string]::IsNullOrEmpty($PSCommandPath)) {

        throw "WinBasicDeployExit:$Code"
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
        [string]$Architecture
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


    Set-RegistryDword `
        -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
        -Name "TaskbarAl" `
        -Value 0
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


    $HiveName = "WinBasicTaskbar"

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


    $TaskName = "WinBasicExplorer"

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

    $Alignment = (
        Get-ItemProperty `
            -LiteralPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
            -Name "TaskbarAl"
    ).TaskbarAl


    return (
        [int]$SearchMode -eq 0 -and
        [int]$SearchCache -eq 1 -and
        [int]$Alignment -eq 0
    )
}



function Set-TaskbarLayout {

    Write-Log "Ocultando la busqueda y alineando la barra de tareas a la izquierda..."


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


    Write-Log "Campo de busqueda de la barra de tareas oculto." "OK"

    Write-Log "Iconos de la barra de tareas alineados a la izquierda." "OK"
}



try {

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null


    Write-Host ""
    Write-Host "============================================================"
    Write-Host " WINDOWS - INSTALACION BASICA"
    Write-Host "============================================================"
    Write-Host ""


    Write-Log "Inicio de la instalacion basica."

    Write-Log "Equipo: $env:COMPUTERNAME"

    Write-Log "Usuario: $env:USERDOMAIN\$env:USERNAME"


    if (-not (Test-Administrator)) {

        Write-Log "PowerShell no esta ejecutandose como Administrador." "ERROR"

        Write-Host ""
        Write-Host "Ejecute PowerShell como Administrador."
        Write-Host ""

        Stop-WinBasicDeploy -Code 10
    }


    Write-Log "Privilegios de administrador confirmados." "OK"


    $Architecture = Get-OsArchitecture

    Write-Log "Arquitectura: $Architecture"


    Install-BasicApplications -Architecture $Architecture


    try {

        Disable-WindowsFirewallPermanently

    }
    catch {

        Add-DeployFailure "Firewall: $($_.Exception.Message)"
    }


    try {

        Enable-RemoteDesktopWithoutNla

    }
    catch {

        Add-DeployFailure "Escritorio remoto: $($_.Exception.Message)"
    }


    try {

        Disable-IPv6Completely

    }
    catch {

        Add-DeployFailure "IPv6: $($_.Exception.Message)"
    }


    try {

        Set-TaskbarLayout

    }
    catch {

        Add-DeployFailure "Barra de tareas: $($_.Exception.Message)"
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

        Write-Host "Notepad++, 7-Zip, Firefox y Chrome: INSTALADOS O YA PRESENTES"
        Write-Host "Firewall de Windows             : DESHABILITADO"
        Write-Host "Escritorio remoto               : HABILITADO"
        Write-Host "Autenticacion a nivel de red    : DESMARCADA"
        Write-Host "IPv6                            : DESHABILITADO AL REINICIAR"
        Write-Host "Busqueda en la barra de tareas : OCULTA"
        Write-Host "Alineacion de la barra         : IZQUIERDA"
        Write-Host ""
        Write-Host "INSTALACION BASICA FINALIZADA" -ForegroundColor Green
        Write-Host ""
        Write-Host "Reinicie el equipo para completar la deshabilitacion de IPv6."
        Write-Host ""

        Write-Log "Instalacion basica finalizada." "OK"

        Stop-WinBasicDeploy -Code 0
    }


    Write-Host "INSTALACION BASICA FINALIZADA CON ERRORES" -ForegroundColor Yellow

    Write-Host ""

    foreach ($Failure in $Script:Failures) {

        Write-Host " - $Failure"
    }

    Write-Host ""
    Write-Host "Revise: $LogFile"
    Write-Host ""

    Write-Log "Instalacion basica finalizada con errores." "WARN"

    Stop-WinBasicDeploy -Code 1

}
catch {

    $DeployMessage = [string]$_.Exception.Message


    if ($DeployMessage -like "WinBasicDeployExit:*") {

        $DeployExitCode = 1

        $DeployParsedCode = 0


        if (
            [int]::TryParse(
                ($DeployMessage -replace "^WinBasicDeployExit:", ""),
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
