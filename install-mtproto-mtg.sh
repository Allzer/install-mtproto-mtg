#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

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
  if [[ "${EUID}" -ne 0 ]]; then
    die "запусти скрипт от root: sudo bash $0"
  fi
}

detect_debian() {
  [[ -r /etc/os-release ]] || die "не найден /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "этот скрипт рассчитан на Debian. Текущая ОС: ${PRETTY_NAME:-unknown}"
  [[ -n "${VERSION_CODENAME:-}" ]] || die "не удалось определить VERSION_CODENAME Debian"
  DEBIAN_CODENAME="${VERSION_CODENAME}"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

port_is_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn | awk '{print $4}' | grep -Eq "[:.]${p}$"
  else
    return 1
  fi
}

container_exists() {
  command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

container_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

install_base_packages() {
  info "Установка базовых пакетов"
  apt-get update
  apt-get install -y ca-certificates curl gnupg iproute2
}

install_qrencode_if_needed() {
  if command -v qrencode >/dev/null 2>&1; then
    return 0
  fi

  info "Установка qrencode для генерации QR-кода"
  apt-get update
  apt-get install -y qrencode
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    green "Docker уже установлен"
  else
    info "Установка Docker из официального apt-репозитория"

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat >/etc/apt/sources.list.d/docker.list <<DOCKER_REPO
# Docker official repository
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable
DOCKER_REPO

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker установлен, но daemon недоступен"
}

ask_port() {
  while true; do
    read -r -p "Внешний TCP-порт для MTProto [443]: " PORT
    PORT="${PORT:-443}"

    if ! valid_port "$PORT"; then
      yellow "Некорректный порт. Введи число от 1 до 65535."
      continue
    fi

    if port_is_busy "$PORT"; then
      yellow "Порт ${PORT}/tcp уже занят."
      read -r -p "Продолжить с этим портом всё равно? [y/N]: " busy_answer
      case "${busy_answer}" in
        y|Y|yes|YES|д|Д|да|ДА) break ;;
        *) yellow "Выбери другой порт, например 8443."; continue ;;
      esac
    fi

    break
  done
}

ask_domain() {
  read -r -p "Домен для FakeTLS/SNI secret [example.com]: " FRONT_DOMAIN
  FRONT_DOMAIN="${FRONT_DOMAIN:-example.com}"

  if [[ ! "$FRONT_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$FRONT_DOMAIN" != *.* ]]; then
    die "домен выглядит некорректно: ${FRONT_DOMAIN}"
  fi
}

detect_public_addr() {
  local detected_ip=""

  detected_ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  if [[ -z "${detected_ip}" ]]; then
    detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  printf '%s' "${detected_ip}"
}

load_env_if_exists() {
  if [[ -r "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
}

get_server_addr_from_links_file() {
  if [[ -r "${LINKS_FILE}" ]]; then
    awk -F': ' '/^Server: / {print $2; exit}' "${LINKS_FILE}" 2>/dev/null || true
  fi
}

ask_server_addr() {
  load_env_if_exists

  local default_addr="${SERVER_ADDR:-}"
  local from_links=""

  if [[ -z "${default_addr}" ]]; then
    from_links="$(get_server_addr_from_links_file)"
    default_addr="${from_links}"
  fi

  if [[ -z "${default_addr}" ]]; then
    default_addr="$(detect_public_addr)"
  fi

  read -r -p "IP или домен сервера для ссылки [${default_addr}]: " SERVER_ADDR
  SERVER_ADDR="${SERVER_ADDR:-$default_addr}"
  [[ -n "${SERVER_ADDR}" ]] || die "IP/домен сервера не задан"
}

resolve_server_addr_noninteractive() {
  load_env_if_exists

  local from_links=""
  if [[ -z "${SERVER_ADDR:-}" ]]; then
    from_links="$(get_server_addr_from_links_file)"
    SERVER_ADDR="${from_links}"
  fi

  if [[ -z "${SERVER_ADDR:-}" ]]; then
    SERVER_ADDR="$(detect_public_addr)"
  fi

  [[ -n "${SERVER_ADDR:-}" ]] || die "не удалось определить IP/домен сервера. Выполни установку заново или пропиши SERVER_ADDR в ${ENV_FILE}"
}

save_env() {
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  cat >"${ENV_FILE}" <<ENV_DATA
PORT="${PORT:-}"
FRONT_DOMAIN="${FRONT_DOMAIN:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
ENV_DATA

  chmod 600 "${ENV_FILE}"
}

read_secret_from_config() {
  [[ -r "${CONFIG_FILE}" ]] || return 1
  SECRET="$(awk -F'"' '/^[[:space:]]*secret[[:space:]]*=/ {print $2; exit}' "${CONFIG_FILE}")"
  [[ -n "${SECRET}" ]]
}

get_external_port() {
  local inspected_port=""

  load_env_if_exists

  if command -v docker >/dev/null 2>&1 && container_exists; then
    inspected_port="$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "3128/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
  fi

  if [[ -n "${inspected_port}" && "${inspected_port}" != "<no value>" ]]; then
    PORT="${inspected_port}"
  elif [[ -z "${PORT:-}" ]]; then
    PORT="443"
  fi
}

generate_secret() {
  info "Загрузка Docker-образа ${IMAGE}"
  docker pull "${IMAGE}"

  info "Генерация secret"
  SECRET="$(docker run --rm "${IMAGE}" generate-secret --hex "${FRONT_DOMAIN}" | tail -n1 | tr -d '[:space:]')"

  if [[ -z "${SECRET}" || "${SECRET}" != ee* ]]; then
    die "не удалось сгенерировать корректный secret"
  fi
}

write_config() {
  info "Создание конфига ${CONFIG_FILE}"
  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  cat >"${CONFIG_FILE}" <<MTG_CONFIG
secret = "${SECRET}"
bind-to = "0.0.0.0:${INTERNAL_PORT}"
MTG_CONFIG

  chmod 600 "${CONFIG_FILE}"
}

create_container() {
  info "Запуск MTProto-прокси"

  if container_exists; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi

  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -v "${CONFIG_FILE}:/config.toml:ro" \
    -p "${PORT}:${INTERNAL_PORT}/tcp" \
    "${IMAGE}" >/dev/null

  sleep 2
  docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" || {
    docker logs "${CONTAINER_NAME}" || true
    die "контейнер не запустился"
  }
}

open_firewall_if_needed() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Открытие порта в ufw"
    ufw allow "${PORT}/tcp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "Открытие порта в firewalld"
    firewall-cmd --permanent --add-port="${PORT}/tcp"
    firewall-cmd --reload
  fi
}

write_links_and_qr() {
  read_secret_from_config || die "не найден secret в ${CONFIG_FILE}. Сначала установи контейнер."
  get_external_port
  resolve_server_addr_noninteractive

  TME_URL="https://t.me/proxy?server=${SERVER_ADDR}&port=${PORT}&secret=${SECRET}"
  TG_URL="tg://proxy?server=${SERVER_ADDR}&port=${PORT}&secret=${SECRET}"

  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}"

  cat >"${LINKS_FILE}" <<LINKS
MTProto proxy via mtg
Server: ${SERVER_ADDR}
Port: ${PORT}
Secret: ${SECRET}
FakeTLS/SNI domain: ${FRONT_DOMAIN:-unknown}

Telegram HTTPS link:
${TME_URL}

Telegram tg:// link:
${TG_URL}

QR PNG:
${QR_PNG_FILE}
LINKS

  chmod 600 "${LINKS_FILE}"
  save_env

  install_qrencode_if_needed
  qrencode -o "${QR_PNG_FILE}" -s 8 -m 2 "${TME_URL}"
  chmod 600 "${QR_PNG_FILE}"

  printf '\nАдрес сервера для ссылки: %s\n' "${SERVER_ADDR}"
  printf 'Порт: %s/tcp\n' "${PORT}"
  printf '\nHTTPS-ссылка для Telegram:\n%s\n' "${TME_URL}"
  printf '\ntg:// ссылка:\n%s\n' "${TG_URL}"
  printf '\nСохранено:\n  %s\n  %s\n' "${LINKS_FILE}" "${QR_PNG_FILE}"

  printf '\nQR-код для сканирования:\n'
  qrencode -t ANSIUTF8 "${TME_URL}"
}

print_container_diagnostics() {
  if ! container_exists; then
    return 0
  fi

  printf '\nДиагностика контейнера:\n'
  docker inspect -f 'State: {{.State.Status}} | Running: {{.State.Running}} | ExitCode: {{.State.ExitCode}} | RestartCount: {{.RestartCount}} | StartedAt: {{.State.StartedAt}}' "${CONTAINER_NAME}" 2>/dev/null || true
  docker inspect -f 'Image: {{.Config.Image}} | Command: {{json .Config.Cmd}}' "${CONTAINER_NAME}" 2>/dev/null || true

  printf '\nПроброс портов Docker:\n'
  docker port "${CONTAINER_NAME}" 2>/dev/null || true

  printf '\nСлушающие TCP-порты на хосте для этого порта:\n'
  get_external_port
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" || yellow "ss не показывает прослушивание ${PORT}/tcp. Проверь firewall/Docker."
  else
    yellow "ss не найден."
  fi

  printf '\nПоследние события Docker по контейнеру:\n'
  docker events \
    --since 1h \
    --until "$(date --iso-8601=seconds)" \
    --filter "container=${CONTAINER_NAME}" \
    --format '{{.Time}} {{.Action}} {{.Actor.Attributes.name}}' 2>/dev/null | tail -n 20 || true
}

show_status() {
  load_env_if_exists

  if ! command -v docker >/dev/null 2>&1; then
    yellow "Docker не установлен. Контейнер ${CONTAINER_NAME} отсутствует."
    return 0
  fi

  printf '\nКонтейнер: %s\n' "${CONTAINER_NAME}"

  if container_exists; then
    docker ps -a \
      --filter "name=^/${CONTAINER_NAME}$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    yellow "Контейнер не найден."
    return 0
  fi

  if [[ -r "${CONFIG_FILE}" ]]; then
    read_secret_from_config || true
    get_external_port
    resolve_server_addr_noninteractive || true
    printf '\nКонфиг: %s\n' "${CONFIG_FILE}"
    printf 'Адрес сервера для ссылки: %s\n' "${SERVER_ADDR:-не найден}"
    printf 'Порт: %s/tcp\n' "${PORT}"
    printf 'Secret: %s\n' "${SECRET:-не найден}"
  fi

  printf '\nПоследние логи docker logs:\n'
  local logs=""
  logs="$(docker logs --tail 50 "${CONTAINER_NAME}" 2>&1 || true)"
  if [[ -n "${logs}" ]]; then
    printf '%s\n' "${logs}"
  else
    yellow "docker logs пуст. Для mtg это возможно при нормальной работе, если не было ошибок/подключений. Ниже смотри диагностику Docker."
  fi

  print_container_diagnostics
}

install_proxy() {
  detect_debian
  install_base_packages
  ask_port
  ask_domain
  ask_server_addr
  install_docker_if_needed
  generate_secret
  write_config
  create_container
  open_firewall_if_needed
  save_env
  write_links_and_qr

  green "\nГотово. MTProto-прокси установлен и запущен."
}

remove_proxy() {
  if command -v docker >/dev/null 2>&1 && container_exists; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
    green "Контейнер ${CONTAINER_NAME} удалён."
  else
    yellow "Контейнер ${CONTAINER_NAME} не найден."
  fi

  read -r -p "Удалить конфиги и ссылки из ${CONFIG_DIR}? [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES|д|Д|да|ДА)
      rm -rf "${CONFIG_DIR}"
      green "Директория ${CONFIG_DIR} удалена."
      ;;
    *)
      yellow "Конфиги оставлены: ${CONFIG_DIR}"
      ;;
  esac
}

start_proxy() {
  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  container_exists || die "контейнер ${CONTAINER_NAME} не найден. Сначала выполни установку."

  docker start "${CONTAINER_NAME}" >/dev/null
  green "Контейнер ${CONTAINER_NAME} запущен."
}

stop_proxy() {
  command -v docker >/dev/null 2>&1 || die "Docker не установлен"
  container_exists || die "контейнер ${CONTAINER_NAME} не найден."

  docker stop "${CONTAINER_NAME}" >/dev/null
  green "Контейнер ${CONTAINER_NAME} остановлен."
}

menu_install_remove() {
  printf '\n1) Установить / переустановить контейнер\n'
  printf '2) Удалить контейнер\n'
  printf '0) Назад\n'
  read -r -p "Выбери пункт: " action

  case "${action}" in
    1) install_proxy ;;
    2) remove_proxy ;;
    0) return 0 ;;
    *) yellow "Некорректный пункт." ;;
  esac
}

menu_status_links_qr() {
  show_status

  if [[ -r "${CONFIG_FILE}" ]]; then
    printf '\nГенерация ссылки и QR-кода подключения\n'
    write_links_and_qr
  else
    yellow "QR и ссылку нельзя создать: нет ${CONFIG_FILE}."
  fi
}

menu_start_stop() {
  printf '\n1) Запустить контейнер\n'
  printf '2) Остановить контейнер\n'
  printf '0) Назад\n'
  read -r -p "Выбери пункт: " action

  case "${action}" in
    1) start_proxy ;;
    2) stop_proxy ;;
    0) return 0 ;;
    *) yellow "Некорректный пункт." ;;
  esac
}

main_menu() {
  while true; do
    printf '\n'
    blue "MTProto mtg manager"
    printf '1) Установка / удаление контейнера\n'
    printf '2) Статус контейнера + генерация QR и ссылки для подключения MTProto\n'
    printf '3) Запустить / остановить контейнер\n'
    printf '0) Выход\n'
    read -r -p "Выбери пункт: " choice

    case "${choice}" in
      1) menu_install_remove ;;
      2) menu_status_links_qr ;;
      3) menu_start_stop ;;
      0) exit 0 ;;
      *) yellow "Некорректный пункт." ;;
    esac
  done
}

main() {
  require_root
  main_menu
}

main "$@"
