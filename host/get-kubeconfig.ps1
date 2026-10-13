<#
.SYNOPSIS
Trae el kubeconfig de un servidor con k3s y lo deja listo en el equipo local.

.DESCRIPTION
Copia ~/.kube/config del servidor (lo deja ahí install-k3s.sh), cambia la dirección
local del API por el nombre completo del servidor y renombra cluster, usuario y contexto
de "default" al nombre del entorno, para que varios servidores convivan sin chocar.
Resultado: ~/.kube/config-<Environment>, con el contexto <Environment>.

.EXAMPLE
.\get-kubeconfig.ps1 -Server mi-servidor -Environment dev
#>
param(
    # Host SSH del servidor (alias de ~/.ssh/config o nombre).
    [Parameter(Mandatory)] [string] $Server,
    # Nombre del entorno: carpeta en terraform/envs/ y nombre del contexto.
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9-]+$')] [string] $Environment,
    # Nombre con el que se llega al API desde este equipo. Por defecto, hostname -f del servidor.
    [string] $Fqdn
)

$ErrorActionPreference = 'Stop'

if (-not $Fqdn) {
    $Fqdn = (ssh -o BatchMode=yes $Server 'hostname -f').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Fqdn) { throw "No se pudo obtener el nombre de $Server por SSH." }
}

$target = Join-Path $env:USERPROFILE ".kube\config-$Environment"
$download = "$target.download"
New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null

scp -o BatchMode=yes "${Server}:.kube/config" $download
if ($LASTEXITCODE -ne 0) { throw "No se pudo copiar ~/.kube/config desde $Server. ¿Se corrió install-k3s.sh?" }

try {
    $config = [IO.File]::ReadAllText($download)
    if ($config -notmatch 'https://127\.0\.0\.1:6443') { throw "El kubeconfig de $Server no apunta a https://127.0.0.1:6443; no parece el de k3s." }

    $config = $config -replace 'https://127\.0\.0\.1:6443', "https://${Fqdn}:6443"
    # k3s nombra cluster, usuario y contexto "default"; se renombran al entorno.
    $config = $config -replace '(?m)^(\s*(?:-\s+)?(?:name|cluster|user|current-context):\s+)default\s*$', "`${1}$Environment"

    [IO.File]::WriteAllText($target, $config, (New-Object Text.UTF8Encoding($false)))
}
finally {
    Remove-Item -LiteralPath $download -ErrorAction SilentlyContinue
}

Write-Output "Kubeconfig en $target (contexto '$Environment', API https://${Fqdn}:6443)."
