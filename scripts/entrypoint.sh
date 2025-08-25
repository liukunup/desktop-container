#!/bin/bash

# set -x  # Uncomment for debugging

# Ensure script exits on error and unset variables
set -euo pipefail

# =================================================
# Entry Point Script for Desktop Docker Container
# =================================================

# ------------ Constants (Do not modify) ------------
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_NAME=$(basename "$0")

# ------------ Constants (Do not modify) ----------
readonly SCRIPT_VERSION="1.0.0"
# shellcheck disable=SC2155
readonly SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}") || exit 1
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"

# ------------ Environment Variables --------------
: "${DISPLAY:=:0}"
: "${RESOLUTION:=1280x720}"
: "${DEPTH:=24}"
: "${DEFAULT_USER:=billy}"
: "${USERNAME:=}"
: "${PASSWORD:=}"

# ------------ Toolkit ------------

# Load logger if available, else define basic logging functions
LOGGER_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/logger.sh"
if [[ -f "${LOGGER_SCRIPT}" && -r "${LOGGER_SCRIPT}" ]]; then
  # shellcheck disable=SC1090
  source "${LOGGER_SCRIPT}"
  export LOG_LEVEL="INFO"
  export LOG_FILE="/var/log/${SCRIPT_NAME%.*}.log"
else
  debug()    { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S') || return 1; echo "[DEBUG] ${timestamp} - $*"; }
  info()     { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S') || return 1; echo "[INFO] ${timestamp} - $*"; }
  warn()     { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S') || return 1; echo "[WARN] ${timestamp} - $*"; }
  error()    { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S') || return 1; echo "[ERROR] ${timestamp} - $*"; }
  critical() { local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S') || return 1; echo "[CRITICAL] ${timestamp} - $*"; }
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

use_default_self_signed_ssl_cert() {
  local cert_dir="$1"
  local cert_name="${2:-selfsigned}"

  # Create certificate directory if it doesn't exist
  mkdir -p "${cert_dir}" || {
    error "Failed to create certificate directory: ${cert_dir}"
    return 1
  }

  if [[ ! -f "${cert_dir}/${cert_name}.pem" || ! -f "${cert_dir}/${cert_name}.key" ]]; then
    # PEM
    if [[ -f "/etc/ssl/certs/ssl-cert-snakeoil.pem" ]]; then
      [[ ! -f "${cert_dir}/${cert_name}.pem" ]] || rm -f "${cert_dir}/${cert_name}.pem"
      ln -s "/etc/ssl/certs/ssl-cert-snakeoil.pem" "${cert_dir}/${cert_name}.pem"
    else
      error "Default self-signed SSL certificate not found at /etc/ssl/certs/ssl-cert-snakeoil.pem"
      return 1
    fi
    # Private key
    if [[ -f "/etc/ssl/private/ssl-cert-snakeoil.key" ]]; then
      [[ ! -f "${cert_dir}/${cert_name}.key" ]] || rm -f "${cert_dir}/${cert_name}.key"
      ln -s "/etc/ssl/private/ssl-cert-snakeoil.key" "${cert_dir}/${cert_name}.key"
    else
      error "Default self-signed SSL private key not found at /etc/ssl/private/ssl-cert-snakeoil.key"
      return 1
    fi
  else
    info "Using existing self-signed SSL certificate"
    return 0
  fi

  info "Using default self-signed SSL certificate"
  debug "  Certificate: ${cert_dir}/${cert_name}.pem"
  debug "  Private key: ${cert_dir}/${cert_name}.key"

  return 0
}

start_desktop() {
  info "========================================"
  info "Starting Desktop Container"
  info "========================================"

  local username="$1"
  local password="$2"

  # ----- User -----
  create_user "${USERNAME}" "${PASSWORD}"

  # ----- SSL -----

  # Remove existing D-Bus PID files to prevent hanging on container restart
  [[ ! -f /run/dbus/pid ]] || rm -f /run/dbus/pid || error "Failed to remove existing D-Bus PID file"

  # ----- VNC -----
  # First time startup or password has been changed
  if [[ -n "${PASSWORD}" ]]; then
    # Generate VNC password file
    local passwd_dir="/home/${USERNAME}/.vnc"
    local passwd_file="${passwd_dir}/passwd"
    mkdir -p "${passwd_dir}" || {
      error "Failed to create required directories: ${passwd_dir}"
      exit 1
    }
    /usr/bin/x11vnc -storepasswd "${PASSWORD}" "${passwd_file}" >/dev/null 2>&1 || {
      error "Failed to generate VNC password file"
      exit 1
    }
    chmod 600 "${passwd_file}" || {
      error "Failed to set permissions on VNC password file"
      exit 1
    }
    chown "${USERNAME}:${USERNAME}" "${passwd_file}" || {
      error "Failed to set ownership for user home directory"
      exit 1
    }
  fi

  use_default_self_signed_ssl_cert "/opt/certs" "novnc"
  cert_status=$?
  if [[ "${cert_status}" -ne 0 ]]; then
    error "ERROR: SSL certificate configuration failed"
    exit 1
  fi

  # ----- RDP -----
  local cert_dir="/home/${USERNAME}/.certs"
  local cert_name="rdp"
  # Configure SSL certificate
  use_default_self_signed_ssl_cert "${cert_dir}" "${cert_name}"
  cert_status=$?
  if [[ "${cert_status}" -ne 0 ]]; then
    error "ERROR: SSL certificate configuration failed"
    exit 1
  fi
  # Ensure user is in ssl-cert group
  if ! id -nG "${USERNAME}" | grep -qw "ssl-cert"; then
    usermod -aG ssl-cert "${USERNAME}" || {
      error "Failed to add user ${USERNAME} to ssl-cert group"
      exit 1
    }
  fi
  # Configure xrdp to use the self-signed certificate
  sed -i "s|^certificate=.*|certificate=${cert_dir}/${cert_name}.pem|" /etc/xrdp/xrdp.ini
  sed -i "s|^key_file=.*|key_file=${cert_dir}/${cert_name}.key|" /etc/xrdp/xrdp.ini

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
  exec /usr/bin/supervisord --nodaemon --configuration=/etc/supervisord.conf | \
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

Available modes:
desktop         Start Desktop
keepalive       Just keep container alive

Environment Variables:

EOF
}

# ------------ Main ------------


# ------------ Main Script ------------
main() {
  create_lock

  info "=========================================="
  info "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION}"
  info "=========================================="

  current_user=$(id) || current_user="unknown"
  info "Running as ${current_user}"
  info "Log file: ${LOG_FILE}"

  if [[ $# -eq 0 ]]; then
    show_help
    exit 1
  fi

  local mode=$1
  shift

  case ${mode} in
    desktop)        start_desktop ;;
    keepalive)      run_keepalive ;;
    help|--help|-h) show_help ;;
    *) 
      error "Unknown mode: ${mode}"
      show_help
      exit 1
      ;;
  esac
}

main "$@"