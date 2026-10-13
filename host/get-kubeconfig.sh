#!/usr/bin/env bash
# Trae el kubeconfig de un servidor con k3s y lo deja listo en el equipo local.
# Copia ~/.kube/config del servidor (lo deja ahí install-k3s.sh), cambia la dirección
# local del API por el nombre completo del servidor y renombra cluster, usuario y contexto
# de "default" al nombre del entorno, para que varios servidores convivan sin chocar.
# Resultado: ~/.kube/config-<entorno>, con el contexto <entorno>.
#
# Uso: bash get-kubeconfig.sh --server <host-ssh> --env <entorno> [--fqdn <nombre>]
#   --server  Host SSH del servidor (alias de ~/.ssh/config o nombre).
#   --env     Nombre del entorno: carpeta en terraform/envs/ y nombre del contexto.
#   --fqdn    Nombre con el que se llega al API desde este equipo. Por defecto, hostname -f del servidor.
set -euo pipefail

SERVER=""
ENVIRONMENT=""
FQDN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2:?--server necesita un valor}"; shift 2 ;;
    --env) ENVIRONMENT="${2:?--env necesita un valor}"; shift 2 ;;
    --fqdn) FQDN="${2:?--fqdn necesita un valor}"; shift 2 ;;
    *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SERVER" || -z "$ENVIRONMENT" ]]; then
  echo "Uso: bash get-kubeconfig.sh --server <host-ssh> --env <entorno> [--fqdn <nombre>]" >&2
  exit 1
fi
if [[ ! "$ENVIRONMENT" =~ ^[a-z0-9-]+$ ]]; then
  echo "El entorno solo admite minúsculas, dígitos y guiones: $ENVIRONMENT" >&2
  exit 1
fi

if [[ -z "$FQDN" ]]; then
  FQDN="$(ssh -o BatchMode=yes "$SERVER" 'hostname -f' | tr -d '[:space:]')" || true
  if [[ -z "$FQDN" ]]; then
    echo "No se pudo obtener el nombre de $SERVER por SSH." >&2
    exit 1
  fi
fi
# El nombre va dentro de un reemplazo de sed.
if [[ ! "$FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Nombre de servidor no válido: $FQDN" >&2
  exit 1
fi

target="$HOME/.kube/config-$ENVIRONMENT"
mkdir -p "$(dirname "$target")"
download="$(mktemp "$target.download.XXXXXX")"
trap 'rm -f "$download" "$download.new"' EXIT

if ! scp -q -o BatchMode=yes "${SERVER}:.kube/config" "$download"; then
  echo "No se pudo copiar ~/.kube/config desde $SERVER. ¿Se corrió install-k3s.sh?" >&2
  exit 1
fi

if ! grep -q 'https://127\.0\.0\.1:6443' "$download"; then
  echo "El kubeconfig de $SERVER no apunta a https://127.0.0.1:6443; no parece el de k3s." >&2
  exit 1
fi

# k3s nombra cluster, usuario y contexto "default"; se renombran al entorno.
sed -E \
  -e "s#https://127\.0\.0\.1:6443#https://${FQDN}:6443#" \
  -e "s#^([[:space:]]*(-[[:space:]]+)?(name|cluster|user|current-context):[[:space:]]+)default[[:space:]]*\$#\1${ENVIRONMENT}#" \
  "$download" > "$download.new"
chmod 600 "$download.new"
mv "$download.new" "$target"

echo "Kubeconfig en $target (contexto '$ENVIRONMENT', API https://${FQDN}:6443)."
