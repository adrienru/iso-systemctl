#!/usr/bin/env bash
# Ubuntu workstation bootstrap: developer tools + Neovim/LazyVim + Docker Engine/Compose.
# Safe to re-run. On Docker containers it installs packages but does not try to start dockerd.

set -Eeuo pipefail

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Ejecuta con sudo: sudo bash ubuntu-devkit.sh"

. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Este script está preparado para Ubuntu; detectado: ${PRETTY_NAME:-desconocido}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) NVIM_ARCH="linux-x86_64" ;;
  arm64) NVIM_ARCH="linux-arm64" ;;
  *) die "Arquitectura no soportada para Neovim oficial: $ARCH" ;;
esac

IN_CONTAINER=0
[[ -f /.dockerenv ]] && IN_CONTAINER=1
grep -qaE '(docker|containerd|kubepods|podman)' /proc/1/cgroup 2>/dev/null && IN_CONTAINER=1 || true

log "Actualizando Ubuntu e instalando herramientas de desarrollo/redes"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git \
  build-essential cmake pkg-config \
  python3 python3-pip python3-venv pipx \
  nodejs npm \
  ripgrep fd-find fzf tree tmux htop ncdu jq \
  unzip zip xz-utils \
  nmap whois netcat-openbsd tcpdump traceroute dnsutils net-tools openssl

log "Instalando Neovim reciente (tarball oficial)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fL --retry 3 \
  "https://github.com/neovim/neovim/releases/latest/download/nvim-${NVIM_ARCH}.tar.gz" \
  -o "$tmpdir/nvim.tar.gz"
tar -xzf "$tmpdir/nvim.tar.gz" -C "$tmpdir"
rm -rf /opt/nvim
mv "$tmpdir/nvim-${NVIM_ARCH}" /opt/nvim
ln -sfn /opt/nvim/bin/nvim /usr/local/bin/nvim

log "Preparando LazyVim para el usuario que ejecutó sudo"
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" ]] || die "No pude localizar HOME para $TARGET_USER"
fi
NVIM_CONFIG="$TARGET_HOME/.config/nvim"
if [[ ! -d "$NVIM_CONFIG" ]]; then
  install -d -m 0755 "$(dirname "$NVIM_CONFIG")"
  git clone https://github.com/LazyVim/starter "$NVIM_CONFIG"
  rm -rf "$NVIM_CONFIG/.git"
elif [[ ! -f "$NVIM_CONFIG/lua/config/lazy.lua" ]]; then
  warn "Ya existe $NVIM_CONFIG y no parece ser LazyVim. No la sobrescribo."
  warn "Si quieres instalar LazyVim manualmente, respalda esa carpeta primero."
else
  log "LazyVim ya está configurado; no se modifica."
fi
if [[ "$TARGET_HOME" != "/root" ]]; then
  chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$TARGET_HOME/.config/nvim" 2>/dev/null || true
fi

log "Configurando el repositorio oficial de Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "$CODENAME" ]] || die "No pude detectar el codename de Ubuntu"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if [[ "$IN_CONTAINER" -eq 1 ]]; then
  warn "Detecté que estoy dentro de un contenedor: Docker CLI/Compose quedan instalados, pero no inicio el daemon."
  warn "Esto es normal: el contenedor de prueba no necesita systemd ni Docker-in-Docker."
else
  log "Habilitando Docker Engine en el VPS"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  else
    warn "systemctl no está disponible; inicia Docker manualmente en este sistema."
  fi
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
    warn "El usuario $SUDO_USER fue añadido al grupo docker. Cierra sesión y vuelve a entrar para usar Docker sin sudo."
  fi
fi

log "Verificación de versiones"
nvim --version | head -n 1
git --version
python3 --version
node --version || true
docker --version
docker compose version

if [[ "$IN_CONTAINER" -eq 1 ]]; then
  log "Prueba terminada. En el contenedor, 'docker compose version' debe funcionar; 'docker ps' requiere un daemon."
else
  log "Instalación terminada. Prueba: docker run --rm hello-world"
  log "Para abrir tu entorno: nvim"
fi
