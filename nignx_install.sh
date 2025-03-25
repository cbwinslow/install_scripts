#!/usr/bin/env bash
###############################################################################
# Script Name: nginx_reverse_proxy_setup.sh
# Author: ChatGPT
# Description:
#   This script automates the setup of an Nginx reverse proxy inside a Docker
#   container. It can optionally deploy a Cloudflare tunnel container (cloudflared)
#   if desired (for inbound traffic from Cloudflare). The script also handles
#   Docker installation if AUTO_INSTALL_DOCKER is set to true.
#
# Usage:
#   1. Make it executable: chmod +x nginx_reverse_proxy_setup.sh
#   2. Run (as root or via sudo): ./nginx_reverse_proxy_setup.sh
#   3. Customize variables in the "VARIABLE DECLARATIONS" section.
#
# Notes:
#   - For production HTTPS usage, you might prefer to generate or mount valid
#     TLS certificates in /etc/nginx/certs. Alternatively, rely on Cloudflare SSL.
#   - If using Cloudflare Tunnel, supply valid Cloudflare credentials (see below).
###############################################################################

###############################################################################
#                          VARIABLE DECLARATIONS
###############################################################################
# Name of the Nginx container.
NGINX_CONTAINER_NAME="nginx_reverse_proxy"

# Docker image for Nginx. The official 'nginx:latest' is used here.
NGINX_DOCKER_IMAGE="nginx:latest"

# Host ports to bind to the container (HTTP and HTTPS).
# If you only want to run HTTP, set NGINX_HTTPS_PORT="" (blank) or skip it.
NGINX_HTTP_PORT="80"
NGINX_HTTPS_PORT="443"

# Directory on the host that will contain Nginx config files.
# We'll mount this directory into the container at /etc/nginx/conf.d
NGINX_CONFIG_DIR="/srv/nginx_config"

# (Optional) Directory for SSL certificates (if you plan to use local certs).
# For example, /srv/nginx_certs with server.crt and server.key inside.
NGINX_CERTS_DIR="/srv/nginx_certs"

# If you need a custom default.conf or advanced config, place it in
# $NGINX_CONFIG_DIR prior to running the script. We'll copy an example below.

# (Optional) Deploy a Cloudflare tunnel container (cloudflared).
# If set to true, the script will also create and run the 'cloudflared' container.
# Real usage requires valid credentials (a Cloudflare tunnel token or config).
DEPLOY_CLOUDFLARE_TUNNEL=false

# Name of the Cloudflare container and Docker image.
CLOUDFLARE_CONTAINER_NAME="cloudflared_tunnel"
CLOUDFLARE_DOCKER_IMAGE="cloudflare/cloudflared:latest"

# Directory or file path for Cloudflare tunnel credentials/config.
# For example: /srv/cloudflared/ (containing .json or .pem credential files).
# Real usage with 'cloudflared tunnel run' also requires a named tunnel in Cloudflare.
CLOUDFLARE_CRED_DIR="/srv/cloudflared"

# (Optional) Install Docker if not found. If false, the script exits if Docker is missing.
AUTO_INSTALL_DOCKER=true

# Debian/Ubuntu Docker dependencies.
DOCKER_DEPENDENCIES=("apt-transport-https" "ca-certificates" "curl" "gnupg" "lsb-release")

# Log file path (if you want to log script output to a file).
LOG_FILE="/var/log/nginx_reverse_proxy_setup.log"

###############################################################################
#                          ERROR HANDLING & TRAPS
###############################################################################
# Strict bash settings.
set -Euo pipefail

error_handler() {
  local exit_code=$?
  echo "[ERROR] Script encountered an error on line $1. Exit code: $exit_code"
  exit "$exit_code"
}

cleanup_handler() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "[INFO] Script completed successfully."
  else
    echo "[INFO] Script exited with error code: $exit_code"
  fi
}

trap 'error_handler $LINENO' ERR
trap cleanup_handler EXIT

###############################################################################
#                          UTILITY FUNCTIONS
###############################################################################
log() {
  local message="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') : $message"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $message" >> "$LOG_FILE"
  fi
}

check_command_exists() {
  command -v "$1" &>/dev/null
}

install_docker_if_missing() {
  if ! check_command_exists "docker"; then
    if [[ "$AUTO_INSTALL_DOCKER" == "true" ]]; then
      log "[INFO] Docker not found. Installing Docker..."

      apt-get update -y
      apt-get install -y "${DOCKER_DEPENDENCIES[@]}"
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io

      systemctl enable docker
      systemctl start docker

      log "[INFO] Docker installation completed."
    else
      log "[ERROR] Docker is not installed and AUTO_INSTALL_DOCKER=false. Exiting."
      exit 1
    fi
  else
    log "[INFO] Docker is already installed."
  fi
}

validate_host_environment() {
  if [[ $EUID -ne 0 ]]; then
    log "[ERROR] Please run this script as root or use sudo."
    exit 1
  fi
}

validate_port_availability() {
  # If user sets the variable to an empty string, skip the check.
  if [[ -n "$NGINX_HTTP_PORT" ]]; then
    if ss -tulpn | grep -q ":${NGINX_HTTP_PORT} "; then
      log "[ERROR] Port ${NGINX_HTTP_PORT} is already in use. Choose a different port."
      exit 1
    fi
  fi
  if [[ -n "$NGINX_HTTPS_PORT" ]]; then
    if ss -tulpn | grep -q ":${NGINX_HTTPS_PORT} "; then
      log "[ERROR] Port ${NGINX_HTTPS_PORT} is already in use. Choose a different port."
      exit 1
    fi
  fi
}

prepare_nginx_directories() {
  # Create config directory if missing.
  if [[ ! -d "$NGINX_CONFIG_DIR" ]]; then
    log "[INFO] Creating Nginx config directory at $NGINX_CONFIG_DIR"
    mkdir -p "$NGINX_CONFIG_DIR"
  else
    log "[INFO] Nginx config directory already exists at $NGINX_CONFIG_DIR"
  fi

  # Create cert directory if using local certs.
  if [[ -n "$NGINX_HTTPS_PORT" ]]; then
    if [[ ! -d "$NGINX_CERTS_DIR" ]]; then
      log "[INFO] Creating Nginx cert directory at $NGINX_CERTS_DIR"
      mkdir -p "$NGINX_CERTS_DIR"
    else
      log "[INFO] Nginx cert directory already exists at $NGINX_CERTS_DIR"
    fi
  fi

  # Optional: place a default reverse proxy config if none is present.
  local default_conf="$NGINX_CONFIG_DIR/default.conf"
  if [[ ! -f "$default_conf" ]]; then
    log "[INFO] Placing a basic reverse proxy config in $default_conf"
    cat <<EOF > "$default_conf"
server {
    listen 80;
    server_name _;

    # Example: pass all traffic to another internal service at 127.0.0.1:8080
    location / {
        proxy_pass http://127.0.0.1:8080; 
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

# If using HTTPS, you'd have a separate server block listening on 443 with ssl_certificate, etc.
EOF
  fi
}

run_nginx_container() {
  log "[INFO] Running Nginx container named $NGINX_CONTAINER_NAME"

  # Remove old container if present.
  if docker ps -a --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER_NAME}\$"; then
    log "[INFO] A container named $NGINX_CONTAINER_NAME already exists. Stopping and removing it..."
    docker stop "$NGINX_CONTAINER_NAME" || true
    docker rm "$NGINX_CONTAINER_NAME" || true
  fi

  # Build port arguments dynamically.
  local port_args=()
  if [[ -n "$NGINX_HTTP_PORT" ]]; then
    port_args+=("-p" "${NGINX_HTTP_PORT}:80")
  fi
  if [[ -n "$NGINX_HTTPS_PORT" ]]; then
    port_args+=("-p" "${NGINX_HTTPS_PORT}:443")
  fi

  # For HTTPS, mount certificates in /etc/nginx/certs (if you have them).
  # Then inside your nginx.conf or default.conf, you'd reference those certs.
  local volume_args=("-v" "${NGINX_CONFIG_DIR}:/etc/nginx/conf.d")
  if [[ -n "$NGINX_HTTPS_PORT" ]]; then
    volume_args+=("-v" "${NGINX_CERTS_DIR}:/etc/nginx/certs")
  fi

  docker run -d \
    --name "$NGINX_CONTAINER_NAME" \
    "${port_args[@]}" \
    "${volume_args[@]}" \
    "$NGINX_DOCKER_IMAGE"

  # Validate container is up.
  if [[ $(docker ps --format '{{.Names}}' | grep "^${NGINX_CONTAINER_NAME}\$") == "$NGINX_CONTAINER_NAME" ]]; then
    log "[INFO] Nginx reverse proxy container '$NGINX_CONTAINER_NAME' is running."
  else
    log "[ERROR] Failed to start the Nginx container."
    exit 1
  fi
}

deploy_cloudflare_tunnel() {
  # This is a minimal example. Real usage requires:
  # 1. Running `cloudflared tunnel login` on the host or in a container
  # 2. Creating a named tunnel in Cloudflare, e.g.: `cloudflared tunnel create mytunnel`
  # 3. Placing the generated credentials file (e.g., /root/.cloudflared/<TUNNEL_ID>.json) 
  #    or cert.pem in the $CLOUDFLARE_CRED_DIR
  # 4. Creating config.yml referencing your domain or routes.

  log "[INFO] Deploying Cloudflare tunnel container named $CLOUDFLARE_CONTAINER_NAME"

  # Remove old container if present.
  if docker ps -a --format '{{.Names}}' | grep -q "^${CLOUDFLARE_CONTAINER_NAME}\$"; then
    log "[INFO] Container $CLOUDFLARE_CONTAINER_NAME already exists. Stopping and removing..."
    docker stop "$CLOUDFLARE_CONTAINER_NAME" || true
    docker rm "$CLOUDFLARE_CONTAINER_NAME" || true
  fi

  # Ensure credentials directory exists
  if [[ ! -d "$CLOUDFLARE_CRED_DIR" ]]; then
    log "[INFO] Creating Cloudflare credentials directory at $CLOUDFLARE_CRED_DIR"
    mkdir -p "$CLOUDFLARE_CRED_DIR"
  fi

  # Basic 'cloudflared' usage is: `cloudflared tunnel run <tunnelName>`
  # or `cloudflared tunnel --config /path/to/config.yml run`
  # You must have your config in $CLOUDFLARE_CRED_DIR. Example: config.yml
  # We'll assume you have a config.yml that references the correct credentials.

  docker run -d \
    --name "$CLOUDFLARE_CONTAINER_NAME" \
    --network host \
    -v "${CLOUDFLARE_CRED_DIR}:/home/nonroot/.cloudflared" \
    "$CLOUDFLARE_DOCKER_IMAGE" \
    tunnel run

  # Using "--network host" so cloudflared can listen locally. Alternatively, you can
  # specify ports, but typically cloudflared picks ephemeral local ports to proxy.

  # Confirm container started
  if [[ $(docker ps --format '{{.Names}}' | grep "^${CLOUDFLARE_CONTAINER_NAME}\$") == "$CLOUDFLARE_CONTAINER_NAME" ]]; then
    log "[INFO] Cloudflare tunnel container '$CLOUDFLARE_CONTAINER_NAME' is running."
    log "[INFO] Ensure your config.yml in $CLOUDFLARE_CRED_DIR is correct for domain routing."
  else
    log "[ERROR] Cloudflare tunnel container failed to start."
    exit 1
  fi
}

###############################################################################
#                            MAIN EXECUTION FLOW
###############################################################################
main() {
  log "[INFO] Starting Nginx Reverse Proxy Setup Script..."

  # 1. Validate environment
  validate_host_environment

  # 2. Check/install Docker if missing
  install_docker_if_missing
  if ! check_command_exists "docker"; then
    log "[ERROR] Docker command not found after installation. Exiting."
    exit 1
  fi

  # 3. Validate ports
  validate_port_availability

  # 4. Prepare Nginx directories and config
  prepare_nginx_directories

  # 5. Run the Nginx container
  run_nginx_container

  # 6. (Optional) Deploy Cloudflare tunnel
  if [[ "$DEPLOY_CLOUDFLARE_TUNNEL" == "true" ]]; then
    deploy_cloudflare_tunnel
  fi

  log "[INFO] Nginx Reverse Proxy Setup Script completed."
  log "[INFO] Nginx is listening on port $NGINX_HTTP_PORT (and $NGINX_HTTPS_PORT if set)."
  if [[ "$DEPLOY_CLOUDFLARE_TUNNEL" == "true" ]]; then
    log "[INFO] Cloudflare tunnel is running in container '$CLOUDFLARE_CONTAINER_NAME'."
  fi
  log "[INFO] Adjust your DNS records or Cloudflare config to point traffic to this server."
  log "[INFO] Customize your reverse proxy config in $NGINX_CONFIG_DIR."
}

main
