#!/usr/bin/env sh
set -eu

APP_NAME="mtg"
CONTAINER_NAME="mtg-proxy"
IMAGE="nineseconds/mtg:2"
CONFIG_DIR="/opt/mtg"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
LINKS_FILE="${CONFIG_DIR}/client-links.txt"
QR_PNG_FILE="${CONFIG_DIR}/mtproto-qr.png"
ENV_FILE="${CONFIG_DIR}/install.env"
INTERNAL_PORT="3128"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }
info() { printf '\n==> %s\n' "$*"; }
die() { red "Ошибка: $*"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Запусти от root: sudo sh $0"
  fi
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
  esac
}

port_is_busy() {
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1$"
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

install_base_packages() {
  apk update
  apk add ca-certificates curl iproute2
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  apk add docker docker-cli containerd runc openrc
  rc-update add docker boot
  service docker start || true

  sleep 2
  docker info >/dev/null 2>&1 || die "Docker не запустился"
}

ask_port() {
  while true; do
    read -r -p "Порт [443]: " PORT
    PORT="${PORT:-443}"

    valid_port "$PORT" || { yellow "Некорректный порт"; continue; }

    if port_is_busy "$PORT"; then
      yellow "Порт занят"
      continue
    fi
    break
  done
}

ask_domain() {
  read -r -p "Домен [example.com]: " FRONT_DOMAIN
  FRONT_DOMAIN="${FRONT_DOMAIN:-example.com}"
}

detect_ip() {
  curl -fsS4 https://api.ipify.org || hostname -I | awk '{print $1}'
}

ask_server() {
  DEFAULT="$(detect_ip)"
  read -r -p "IP/домен [${DEFAULT}]: " SERVER_ADDR
  SERVER_ADDR="${SERVER_ADDR:-$DEFAULT}"
}

generate_secret() {
  docker pull "${IMAGE}"
  SECRET="$(docker run --rm "${IMAGE}" generate-secret --hex "${FRONT_DOMAIN}" | tail -n1 | tr -d ' ')"
}

write_config() {
  mkdir -p "${CONFIG_DIR}"
  cat >"${CONFIG_FILE}" <<EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:${INTERNAL_PORT}"
EOF
}

create_container() {
  container_exists && docker rm -f "${CONTAINER_NAME}" >/dev/null

  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --privileged \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    -v "${CONFIG_FILE}:/config.toml:ro" \
    -p "${PORT}:${INTERNAL_PORT}/tcp" \
    "${IMAGE}" >/dev/null

  sleep 2
  docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" || die "Не запустился"
}

show_links() {
  URL="https://t.me/proxy?server=${SERVER_ADDR}&port=${PORT}&secret=${SECRET}"
  echo ""
  echo "Ссылка:"
  echo "$URL"
}

install() {
  install_base_packages
  install_docker_if_needed
  ask_port
  ask_domain
  ask_server
  generate_secret
  write_config
  create_container
  show_links

  green "Готово"
}

require_root
install
