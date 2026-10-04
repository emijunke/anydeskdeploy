# Instalacion desatendida de AnyDesk
Script de PowerShell para instalar AnyDesk en servidores y PCs administrados. Deja el servicio en inicio automatico, configura la password de acceso desatendido y no muestra la aplicacion al usuario que esta delante del equipo.
## Que hace
- Instala AnyDesk en silencio desde el sitio oficial y comprueba la firma digital.
- Si hay una copia portable en uso, no la cierra. Asi se conserva la sesion remota con la que se lanzo el script.
- Si el servicio AnyDesk ya esta en ejecucion, no lo reinicia.
- Configura el servicio como Automatic y la password de acceso desatendido.
- Oculta la entrada local de la aplicacion:
  - no crea icono de escritorio ni acceso del menu Inicio;
  - quita accesos directos, anclajes de la barra de tareas y el inicio automatico de la ventana;
  - en una instalacion nueva, cierra la ventana que abre el instalador y deja solo el servicio;
  - desactiva las solicitudes entrantes (`ad.security.interactive_access=2`). Solo entra quien usa la password de acceso desatendido.
- Escribe el log en `C:\ProgramData\AnyDeskDeploy\AnyDesk_Deploy.log`. La password no se guarda en el log.
Durante una sesion remota, AnyDesk sigue mostrando el marco de pantalla y la barra de sesion. El programa tambien sigue apareciendo en Aplicaciones y caracteristicas, para poder desinstalarlo.
## Requisitos
- Windows con PowerShell 5.1.
- PowerShell ejecutado como Administrador.
- Salida a Internet hacia `https://download.anydesk.com` solo cuando AnyDesk todavia no esta instalado como servicio.
- Password de acceso desatendido de al menos 8 caracteres.
## Uso
En una consola de PowerShell abierta como Administrador:
```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD'
```
Si no se pasa la password, el script la pide de forma oculta.
Para conservar iconos, menu Inicio y la ventana al iniciar sesion:
```powershell
.\Install-AnyDesk.ps1 -UnattendedPassword 'PASSWORD' -ShowUserInterface
```
## Codigos de salida
| Codigo | Significado |
| --- | --- |
| 0 | Instalacion correcta |
| 1 | Termino con advertencias |
| 10 | La consola no es de Administrador |
| 11 | Password ausente o de menos de 8 caracteres |
| 20-24 | Fallo de descarga, archivo o instalador |
| 25-27 | El servicio o el ejecutable no quedaron instalados |
| 30-31 | El servicio no esta disponible o no arranca |
| 40-41 | No se pudo configurar la password |
## Notas
En un equipo donde el servicio ya estaba instalado, el script no cierra una ventana que ya este abierta y no reinicia el servicio. Los accesos directos y el inicio de la ventana se quitan igual; la ventana desaparece en el proximo cierre de sesion. La opcion de solicitudes entrantes queda escrita en `C:\ProgramData\AnyDesk\system.conf` y AnyDesk la toma al iniciar el servicio.
Para desinstalar despues:
```powershell
& "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe" --silent --remove
```
