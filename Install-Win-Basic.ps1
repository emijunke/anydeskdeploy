
[13 lines collapsed]

      desde equipos con Autenticacion a nivel de red".
    - Deshabilita IPv6 en los adaptadores y en el sistema.
      El cambio de IPv6 queda completo despues de reiniciar.
    - Oculta el campo de busqueda de la barra de tareas y alinea
      los iconos a la izquierda.
    - Genera log en C:\ProgramData\WinBasicDeploy.
.EXAMPLE

[1148 lines collapsed]

function Set-TaskbarLayoutOnKey {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RegistryRoot
    )
    Set-RegistryDword `
        -Path "$RegistryRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" `
        -Name "SearchboxTaskbarMode" `
        -Value 0
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
function Set-TaskbarLayout {
    Write-Log "Ocultando la busqueda y alineando la barra de tareas a la izquierda..."
    Set-TaskbarLayoutOnKey -RegistryRoot "HKCU:"
    $ProfileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    foreach ($Profile in @(Get-ChildItem -LiteralPath $ProfileList -ErrorAction SilentlyContinue)) {
        $Sid = $Profile.PSChildName
        if ($Sid -notlike "S-1-5-21-*" -and $Sid -notlike "S-1-12-1-*") {
            continue
