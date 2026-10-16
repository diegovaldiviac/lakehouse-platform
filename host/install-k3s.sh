#!/usr/bin/env bash
# Instala k3s de un nodo en Linux con systemd. Si SELinux está activo (RHEL y derivados) usa el
# soporte de SELinux de k3s; si firewalld o ufw están activos, abre el API y las redes del cluster.
# Uso: sudo bash install-k3s.sh [--fqdn <nombre>] [--registries <ruta/a/registries.yaml>]
# Sin --fqdn usa el nombre completo del servidor (hostname -f).
set -euo pipefail

K3S_VERSION="v1.35.9+k3s1"
POD_CIDR="10.42.0.0/16"
SERVICE_CIDR="10.43.0.0/16"
NODE_FQDN=""
REGISTRIES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) NODE_FQDN="${2:?--fqdn necesita un valor}"; shift 2 ;;
    --registries) REGISTRIES_FILE="${2:?--registries necesita una ruta}"; shift 2 ;;
    *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
  esac
done
NODE_FQDN="${NODE_FQDN:-$(hostname -f)}"

if [[ -n "$REGISTRIES_FILE" && ! -f "$REGISTRIES_FILE" ]]; then
  echo "No existe $REGISTRIES_FILE" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Ejecutar con sudo." >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:?Ejecutar con sudo desde el usuario que va a usar kubectl}"

SELINUX=false
if command -v getenforce >/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  SELINUX=true
fi

install -d -m 0755 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
selinux: ${SELINUX}
write-kubeconfig-mode: "0600"
tls-san:
  - ${NODE_FQDN}
  - $(hostname -s)
cluster-cidr: ${POD_CIDR}
service-cidr: ${SERVICE_CIDR}
# Sin Traefik: el ingress (Contour) se instala aparte.
disable:
  - traefik
EOF

if [[ -n "$REGISTRIES_FILE" ]]; then
  install -m 0600 "$REGISTRIES_FILE" /etc/rancher/k3s/registries.yaml
fi

# Sin las redes de pods y servicios permitidas, el firewall corta el tráfico entre pods.
# 30443 y 30843 son los NodePort de Keycloak y Trino (keycloak_node_port y trino_node_port en workloads.tfvars).
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=6443/tcp
  firewall-cmd --permanent --add-port=30443/tcp
  firewall-cmd --permanent --add-port=30843/tcp
  firewall-cmd --permanent --zone=trusted --add-source="$POD_CIDR"
  firewall-cmd --permanent --zone=trusted --add-source="$SERVICE_CIDR"
  firewall-cmd --reload
elif command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 6443/tcp
  ufw allow 30443/tcp
  ufw allow 30843/tcp
  ufw allow from "$POD_CIDR" to any
  ufw allow from "$SERVICE_CIDR" to any
fi

# Con SELinux en distribuciones RPM, el instalador agrega el repo rpm.rancher.io e instala k3s-selinux.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -

# Ruta absoluta: el secure_path de sudo no siempre incluye /usr/local/bin.
/usr/local/bin/k3s kubectl wait --for=condition=Ready node --all --timeout=300s

user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
install -d -m 0700 -o "$TARGET_USER" "$user_home/.kube"
install -m 0600 -o "$TARGET_USER" /etc/rancher/k3s/k3s.yaml "$user_home/.kube/config"

echo "k3s ${K3S_VERSION} listo en ${NODE_FQDN}. Kubeconfig en ${user_home}/.kube/config"
