#!/bin/bash

# set -x  # debug
set -euo pipefail  # production

# =================================================
# Entry Point Script for Desktop Docker Container
# =================================================

# ------------ Constants (Do not modify) ------------
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_NAME=$(basename "$0")

# ------------ Toolkit ------------

# 引入日志工具类
if [[ -f "logger.sh" ]]; then
  source logger.sh
  export LOG_LEVEL="DEBUG"
  export LOG_FILE="${SCRIPT_NAME%.*}.log"
else
  debug()    { echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $@"; }
  info()     { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $@"; }
  warn()     { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $@"; }
  error()    { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $@"; }
  critical() { echo "[CRITICAL] $(date '+%Y-%m-%d %H:%M:%S') - $@"; }
fi

# Create lock file to prevent multiple instances
create_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    error "Lock file exists: ${LOCK_FILE}. Another instance may be running."
    exit 1
  fi
  touch "${LOCK_FILE}"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ------------ Business ------------
create_user() {
  local username="${1:-${DEFAULT_USER}}"
  local password="$2"

  # Check if user exists, if not create it
  if id "${username}" >/dev/null 2>&1; then
    info "User '${username}' already exists"
    export USERNAME="${username}"

    # If password is provided, update it
    if [[ -n "${password}" ]]; then
      info "Updating password for user '${username}'"

      if ! passwd --stdin "${username}" <<< "${password}" &>/dev/null; then
        error "Failed to update password for user '${username}'"
        return 1
      fi

      info "Password for user '${username}' updated successfully"
      export PASSWORD="${password}"
    else
      export PASSWORD=""
    fi

    return 0
  fi

  # Generate a random password if not provided
  if [[ -z "${password}" ]]; then
    password=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 12) 2>/dev/null || {
      error "Failed to generate random password"
      return 1
    }
    info "No password provided, generated random password for user '${username}'"
  fi

  # shellcheck disable=SC2155
  local uid=$(shuf -i 2000-60000 -n 1)
  local gid=${uid}

  info "Creating user '${username}' with UID:GID ${uid}:${gid}"

  # Create group
  if ! groupadd --gid "${gid}" "${username}"; then
    error "Failed to create group '${username}' (GID: ${gid})"
    return 1
  fi

  salt=$(openssl rand -base64 12) || {
      echo "ERROR: Failed to generate salt" >&2
      return 1
  }

  encrypted_passwd=$(openssl passwd -6 -salt "${salt}" "${password}") || {
      echo "ERROR: Password encryption failed" >&2
      return 1
  }

  # Create user with sudo privileges
  if ! useradd --shell /bin/bash \
                --uid "${uid}" \
                --gid "${gid}" \
                --groups sudo \
                --password "${encrypted_passwd}" \
                --create-home \
                --home-dir "/home/${username}" \
                "${username}"; then
    error "Failed to create user '${username}' (UID: ${uid})"
    return 1
  fi

  # Add sudo rule safely
  temp_sudoers=$(mktemp)
  {
      echo "# Temporary sudoers addition for ${username}"
      echo "${username} ALL=(ALL) NOPASSWD: ALL"
  } > "${temp_sudoers}"
  # Validate temporary file
  if ! visudo -cf "${temp_sudoers}" >/dev/null 2>&1; then
      error "Invalid sudoers file"
      rm -f "${temp_sudoers}"
      return 1
  fi
  # Append to /etc/sudoers
  if ! cat "${temp_sudoers}" >> /etc/sudoers; then
      error "Failed to update /etc/sudoers"
      rm -f "${temp_sudoers}"
      return 1
  fi

  # Clean up temporary file
  rm -f "${temp_sudoers}"

  info "User '${username}' created with password: ${password} (Remember it! You will see it only once)"

  export USERNAME="${username}"
  export PASSWORD="${password}"
}

check_or_create_self_signed_ssl_cert() {
  local cert_dir="$1"
  local cert_filename="${2:-selfsigned}"
  local cert_file="${cert_dir}/${cert_filename}.crt"
  local key_file="${cert_dir}/${cert_filename}.key"
  local days="${3:-365}"

  # Check if certificate already exists
  if [[ -f "${cert_file}" ]] && [[ -f "${key_file}" ]]; then
    info "The self-signed SSL certificate already exists."
    info "  Certificate: ${cert_file}"
    info "  Private key: ${key_file}"
    info "  Valid   for: ${days} days"
    return 0
  fi

  # Create directories if they don't exist
  mkdir -p "${cert_dir}" || {
    error "Failed to create certificate directory: ${cert_dir}"
    return 1
  }

  # Check if OpenSSL is installed
  if ! command -v openssl &> /dev/null; then
    error "OpenSSL is not installed. Please install it first."
    return 1
  fi

  # Generate certificate  
  openssl req -x509 -nodes -days "${days}" -newkey rsa:2048 -sha256 \
    -keyout "${key_file}" -out "${cert_file}" \
    -subj "/C=CN/ST=Guangdong/L=Shenzhen/O=My Company Inc./OU=R&D/CN=localhost" 2>/dev/null

  # Set proper permissions
  chmod 644 "${cert_file}"
  chmod 600 "${key_file}"

  # Set ownership if USERNAME is set
  if [[ -n "${USERNAME}" ]]; then
    chown "${USERNAME}:${USERNAME}" "${cert_file}" "${key_file}" || {
      error "Failed to set ownership for certificate files"
      return 1
    }
  fi

  if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
    info "The self-signed SSL certificate created successfully"
    info "  Certificate: ${cert_file}"
    info "  Private key: ${key_file}"
    info "  Valid   for: ${days} days"
  else
    error "Failed to create self-signed SSL certificate"
    return 1
  fi

  return 0
}

start() {
  info "========================================"
  info "Starting desktop container"
  info "========================================"

  local username="$1"
  local password="$2"

  # ----- User -----

  # ----- SSL -----

  # ----- RDP -----
  # Remove existing sesman/xrdp PID files to prevent rdp sessions hanging on container restart
  [[ ! -f /var/run/xrdp/xrdp-sesman.pid ]] || rm -f /var/run/xrdp/xrdp-sesman.pid
  [[ ! -f /var/run/xrdp/xrdp.pid ]] || rm -f /var/run/xrdp/xrdp.pid

  info "Start xrdp-sesman"
  if ! /usr/sbin/xrdp-sesman >/dev/null 2>&1; then
    error "Failed to start xrdp-sesman"
    exit 1
  fi

  info "Start xrdp"
  if ! /usr/sbin/xrdp --nodaemon >/dev/null 2>&1; then
    error "Failed to start xrdp"
    exit 1
  fi

  # ----- NoMachine -----
  info "Start nxserver"
  if ! /etc/NX/nxserver --startup >/dev/null 2>&1; then
    error "Failed to start nxserver"
    exit 1
  fi

  # ----- Show connection info -----
  info "=========================================================================="
  info "The desktop container is configured with the following details:"
  info "• RDP: localhost:3390"
  info "• VNC: localhost:5900"
  info "• NoVNC: https://localhost:6080/vnc.html"
  info "• NoMachine: localhost:4000"
  info "• Username: ${username}"
  if [[ -n "${password}" ]]; then
    info "• Password: ${password}"
  else
    info "• Password: (only for first time setup, see logs for generated password)"
  fi
  info "=========================================================================="

  # ----- Supervisor -----
  info "Start supervisord with logging"
  exec /usr/bin/supervisord --nodaemon --configuration=/etc/supervisor/conf.d/supervisord.conf | \
    while read -r line; do
      info "supervisord: ${line}"
    done

  # This point should theoretically never be reached due to exec
  error "Supervisord unexpectedly exited"
  exit 1
}

show_help() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <mode> [options]

Environment Variables:

EOF
}

# ------------ Main ------------
main() {

  create_lock

  info "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION}"

  if [[ $# -eq 0 ]]; then
    show_help
    exit 1
  fi
}

main "$@"