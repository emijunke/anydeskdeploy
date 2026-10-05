# INSTALL ANYDESK
$UnattendedPassword = 'PASSWORD'
irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-AnyDesk.ps1" | iex


# INSTALL BASIC & CONFIG WIN (7z, Notepad++, RDP, FW-OFF)
irm "https://raw.githubusercontent.com/emijunke/anydeskdeploy/main/Install-Win-Basic.ps1" | iex
