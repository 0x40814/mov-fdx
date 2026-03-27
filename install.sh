#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="O11V4"
INSTALL_DIR="/opt/o11"
SERVICE_NAME="o11v4"
SERVICE_FILE="${SERVICE_NAME}.service"
PM2_APP_NAME="licserver"
O11_PORT="8484"
LOG_FILE="/var/log/o11-install.log"
PACKAGE_ZIP_FILE="${O11_ZIP_FILE:-o11-package.zip}"
PACKAGE_ZIP_URL="${O11_ZIP_URL:-https://SEU-LINK-DO-ZIP-AQUI}"
ZIP_PASSWORD="${O11_ZIP_PASSWORD:-}"
TEMP_DIR="/tmp/o11-installer"
TEMP_EXTRACT_DIR="${TEMP_DIR}/package"
TEMP_DOWNLOAD_ZIP="${TEMP_DIR}/${PACKAGE_ZIP_FILE}"
SCRIPT_PATH="${BASH_SOURCE[0]:-${0:-.}}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PACKAGE_SOURCE_DIR=""
PACKAGE_SOURCE_LABEL=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
else
  C_RESET=""
  C_BLUE=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

print_banner() {
  cat <<'EOF'
==================================================
  O11V4 Installer
==================================================
EOF
}

section() {
  printf "\n%s==>%s %s\n" "$C_BLUE" "$C_RESET" "$1"
}

info() {
  printf "%s[INFO]%s %s\n" "$C_CYAN" "$C_RESET" "$1"
}

success() {
  printf "%s[OK]%s   %s\n" "$C_GREEN" "$C_RESET" "$1"
}

warn() {
  printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$1"
}

error() {
  printf "%s[ERRO]%s %s\n" "$C_RED" "$C_RESET" "$1" >&2
}

fail() {
  local line="$1"
  error "Falha na linha ${line}. Consulte ${LOG_FILE} para mais detalhes."
  exit 1
}

run_step() {
  local message="$1"
  shift

  info "$message"
  if ( "$@" ) >>"$LOG_FILE" 2>&1; then
    success "$message"
  else
    error "$message"
    tail -n 20 "$LOG_FILE" >&2 || true
    exit 1
  fi
}

run_shell_step() {
  local message="$1"
  local command="$2"

  info "$message"
  if bash -lc "$command" >>"$LOG_FILE" 2>&1; then
    success "$message"
  else
    error "$message"
    tail -n 20 "$LOG_FILE" >&2 || true
    exit 1
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Execute este script como root: sudo ./install.sh"
    exit 1
  fi
}

require_environment() {
  command -v apt-get >/dev/null 2>&1 || {
    error "Este instalador suporta apenas Debian/Ubuntu com apt-get."
    exit 1
  }

  command -v systemctl >/dev/null 2>&1 || {
    error "systemd nao foi encontrado. Nao foi possivel criar o service."
    exit 1
  }
}

prepare_log() {
  : >"$LOG_FILE"
  chmod 640 "$LOG_FILE"
}

cleanup_temp() {
  rm -rf "$TEMP_DIR"
}

zip_url_configured() {
  [[ -n "$PACKAGE_ZIP_URL" && "$PACKAGE_ZIP_URL" != "https://SEU-LINK-DO-ZIP-AQUI" ]]
}

zip_requires_password() {
  local zip_path="$1"
  python3 - "$zip_path" <<'PY'
import sys
import zipfile

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path) as zf:
    encrypted = any(info.flag_bits & 0x1 for info in zf.infolist())
raise SystemExit(0 if encrypted else 1)
PY
}

prompt_zip_password() {
  if [[ ! -t 0 ]]; then
    error "O ZIP parece protegido por senha. Defina O11_ZIP_PASSWORD para instalacao nao interativa."
    exit 1
  fi

  printf "%s[INFO]%s Digite a senha do ZIP: " "$C_CYAN" "$C_RESET" >&2
  read -rsp "" ZIP_PASSWORD
  printf "\n" >&2

  if [[ -z "$ZIP_PASSWORD" ]]; then
    error "Nenhuma senha informada para o ZIP."
    exit 1
  fi
}

extract_zip_with_7z() {
  local zip_path="$1"

  if [[ -n "${ZIP_PASSWORD:-}" ]]; then
    7z x -y "-p${ZIP_PASSWORD}" "-o${TEMP_EXTRACT_DIR}" "$zip_path"
  else
    7z x -y "-o${TEMP_EXTRACT_DIR}" "$zip_path"
  fi
}

extract_zip_contents() {
  local zip_path="$1"

  rm -rf "$TEMP_EXTRACT_DIR"
  mkdir -p "$TEMP_EXTRACT_DIR"

  if zip_requires_password "$zip_path" && [[ -z "${ZIP_PASSWORD:-}" ]]; then
    prompt_zip_password
  fi

  if extract_zip_with_7z "$zip_path"; then
    return 0
  fi

  if [[ -n "${ZIP_PASSWORD:-}" ]]; then
    error "A senha informada em O11_ZIP_PASSWORD esta incorreta."
    return 1
  fi

  return 1
}

verify_package_dir() {
  local package_dir="$1"
  local required_files=(
    "device.wvd"
    "lic.cr"
    "o11.cfg"
    "o11v4"
    "server.js"
  )

  local missing=()
  local file
  for file in "${required_files[@]}"; do
    if [[ ! -e "${package_dir}/${file}" ]]; then
      missing+=("$file")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    error "Pacote incompleto em ${package_dir}. Arquivos ausentes: ${missing[*]}"
    exit 1
  fi
}

prepare_package_from_directory() {
  verify_package_dir "$SCRIPT_DIR"
  PACKAGE_SOURCE_DIR="$SCRIPT_DIR"
  PACKAGE_SOURCE_LABEL="arquivos locais"
}

prepare_package_from_zip() {
  local zip_path="$1"
  local binary_path

  extract_zip_contents "$zip_path"

  binary_path="$(find "$TEMP_EXTRACT_DIR" -type f -name 'o11v4' | head -n 1)"
  if [[ -z "$binary_path" ]]; then
    error "Nao foi possivel localizar o arquivo o11v4 dentro do ZIP."
    exit 1
  fi

  PACKAGE_SOURCE_DIR="$(dirname "$binary_path")"
  verify_package_dir "$PACKAGE_SOURCE_DIR"
  PACKAGE_SOURCE_LABEL="zip $(basename "$zip_path")"
}

prepare_package_source() {
  local configured_zip="${SCRIPT_DIR}/${PACKAGE_ZIP_FILE}"
  local zip_candidates=()

  mkdir -p "$TEMP_DIR"

  if [[ -f "$configured_zip" ]]; then
    prepare_package_from_zip "$configured_zip"
    return 0
  fi

  mapfile -t zip_candidates < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.zip' | sort)
  if (( ${#zip_candidates[@]} == 1 )); then
    warn "Usando o unico ZIP encontrado no diretorio: $(basename "${zip_candidates[0]}")"
    prepare_package_from_zip "${zip_candidates[0]}"
    return 0
  fi

  if (( ${#zip_candidates[@]} > 1 )); then
    error "Mais de um ZIP encontrado. Defina O11_ZIP_FILE para escolher o pacote correto."
    exit 1
  fi

  if zip_url_configured; then
    curl -fL "$PACKAGE_ZIP_URL" -o "$TEMP_DOWNLOAD_ZIP"
    prepare_package_from_zip "$TEMP_DOWNLOAD_ZIP"
    return 0
  fi

  warn "Nenhum ZIP encontrado e a URL do pacote nao foi configurada."
  warn "Tentando usar os arquivos ja extraidos no diretorio atual."
  prepare_package_from_directory
}

install_python_packages() {
  local packages=(
    "pywidevine"
    "requests_toolbelt"
    "dnspython"
    "pythondns"
    "pytz"
    "2captcha-python"
    "flask"
  )

  if python3 -m pip help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    python3 -m pip install --break-system-packages --no-cache-dir "${packages[@]}"
  else
    python3 -m pip install --no-cache-dir "${packages[@]}"
  fi
}

sync_project_files() {
  mkdir -p "$INSTALL_DIR"

  if [[ "$PACKAGE_SOURCE_DIR" == "$INSTALL_DIR" ]]; then
    warn "Os arquivos ja estao em ${INSTALL_DIR}. Copia ignorada."
    return 0
  fi

  cp -a "${PACKAGE_SOURCE_DIR}/." "$INSTALL_DIR/"
}

configure_permissions() {
  chmod 755 "${INSTALL_DIR}/o11v4"
  find "$INSTALL_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} +
  mkdir -p "${INSTALL_DIR}/certs" "${INSTALL_DIR}/dl" "${INSTALL_DIR}/hls"
}

configure_licserver() {
  if pm2 describe "$PM2_APP_NAME" >/dev/null 2>&1; then
    pm2 delete "$PM2_APP_NAME"
  fi

  pm2 start "${INSTALL_DIR}/server.js" --name "$PM2_APP_NAME" --cwd "$INSTALL_DIR"
  pm2 startup systemd -u root --hp /root
  pm2 save --force
}

install_o11_service() {
  cat >"/etc/systemd/system/${SERVICE_FILE}" <<EOF
[Unit]
Description=O11V4 service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/o11v4 -p ${O11_PORT}
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "/etc/systemd/system/${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

show_summary() {
  local service_status="inativo"

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    service_status="ativo"
  fi

  cat <<EOF

==================================================
Instalacao finalizada
==================================================
Diretorio........: ${INSTALL_DIR}
Origem do pacote.: ${PACKAGE_SOURCE_LABEL}
Service..........: ${SERVICE_NAME} (${service_status})
Comando do O11...: ${INSTALL_DIR}/o11v4 -p ${O11_PORT}
Licserver........: PM2 (${PM2_APP_NAME})
Log do instalador: ${LOG_FILE}

Comandos uteis:
  systemctl status ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  pm2 status
  pm2 logs ${PM2_APP_NAME}
EOF
}

main() {
  export DEBIAN_FRONTEND=noninteractive

  print_banner
  require_root
  require_environment
  prepare_log
  trap cleanup_temp EXIT
  trap 'fail "${LINENO}"' ERR

  section "Resumo da instalacao"
  info "Origem dos arquivos : ${SCRIPT_DIR}"
  info "Destino dos arquivos: ${INSTALL_DIR}"
  info "Porta do O11        : ${O11_PORT}"
  info "ZIP esperado        : ${PACKAGE_ZIP_FILE}"
  info "Senha do ZIP        : ${ZIP_PASSWORD:+via O11_ZIP_PASSWORD}"
  info "Log detalhado       : ${LOG_FILE}"

  section "Pacotes do sistema"
  run_step "Atualizando a lista de pacotes" apt-get update -y
  run_step "Instalando dependencias basicas" apt-get install -y ca-certificates curl ffmpeg gnupg openssl p7zip-full python3 python3-pip software-properties-common unzip
  run_shell_step "Configurando repositorio Node.js LTS" "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -"
  run_step "Instalando Node.js" apt-get install -y nodejs

  section "Pacote da aplicacao"
  run_step "Preparando pacote de instalacao" prepare_package_source
  run_step "Copiando arquivos para ${INSTALL_DIR}" sync_project_files
  run_step "Ajustando permissoes e diretorios" configure_permissions

  section "Dependencias da aplicacao"
  run_step "Instalando bibliotecas Python" install_python_packages
  run_step "Instalando PM2 globalmente" npm install -g pm2
  run_step "Instalando Express localmente" npm install --prefix "$INSTALL_DIR" --no-save express

  section "Servicos"
  run_step "Configurando licserver no PM2" configure_licserver
  run_step "Instalando service ${SERVICE_NAME}" install_o11_service
  run_step "Validando service ${SERVICE_NAME}" systemctl is-active --quiet "$SERVICE_NAME"
  run_step "Validando processo ${PM2_APP_NAME}" pm2 describe "$PM2_APP_NAME"

  show_summary
}

main "$@"
