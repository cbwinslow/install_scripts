#!/usr/bin/env bash
###############################################################################
# Script Name: openllm_docker_setup.sh
# Author: ChatGPT
# Description:
#   This script automates the deployment of an OpenLLM instance in a Docker
#   container, intended for a Proxmox environment (or any other Debian/Ubuntu-like
#   host).
#
#   - Variables are declared at the top for easy customization.
#   - Includes advanced error handling (traps, exit codes, validations).
#   - Uses minimal user prompts; most decisions are scripted.
#
# Usage:
#   1. Make executable: chmod +x openllm_docker_setup.sh
#   2. Run (as root or via sudo): ./openllm_docker_setup.sh
#
# Notes:
#   - If Docker is absent and AUTO_INSTALL_DOCKER=true, the script automatically
#     installs Docker. Otherwise, script will exit if Docker is not found.
#   - The default container uses the "bentoml/openllm:latest" image, but you
#     can replace this with any other OpenLLM-compatible image.
#   - For GPU usage, ensure you have nvidia-docker runtime installed and modify
#     the "docker run" command accordingly (not included in this basic script).
###############################################################################

###############################################################################
#                          VARIABLE DECLARATIONS
###############################################################################
# Name of the Docker container.
CONTAINER_NAME="openllm_container"

# Docker image for OpenLLM. By default, using BentoML's official OpenLLM image.
OPENLLM_DOCKER_IMAGE="bentoml/openllm:latest"

# Host port on which OpenLLM will be exposed (e.g., a REST or gRPC endpoint).
OPENLLM_EXPOSED_PORT="3000"

# Directory on the host that will contain any needed data or logs (optional).
# For example: "/srv/openllm_data". Adjust if you have specific volume needs.
OPENLLM_DATA_DIR="/srv/openllm_data"

# If you want to run a specific model by default, you can set it here.
# For instance: "meta-llama/Llama-2-7b-chat-hf" or "stabilityai/stablelm-tuned-alpha-7b".
OPENLLM_MODEL_NAME="stabilityai/stablelm-tuned-alpha-7b"

# (Optional) Install Docker if not found. If set to false, the script will exit if Docker is missing.
AUTO_INSTALL_DOCKER=true

# Debian/Ubuntu Docker dependencies (adjust if needed).
DOCKER_DEPENDENCIES=("apt-transport-https" "ca-certificates" "curl" "gnupg" "lsb-release")

# Log file path (if you want to log script output to a file).
LOG_FILE="/var/log/openllm_setup.log"

###############################################################################
#                          ERROR HANDLING & TRAPS
###############################################################################
# Enable strict bash error settings:
# -E  : Functions inherit trap on ERR
# -u  : Treat unset variables as an error
# -o pipefail : Any failed command in a pipeline causes the pipeline to fail
set -Euo pipefail

# Trap function to handle errors (prints line number and exit code).
error_handler() {
  local exit_code=$?
  echo "[ERROR] Script encountered an error on line $1. Exit code: $exit_code"
  echo "Check logs for details. Exiting."
  exit "$exit_code"
}

# Trap function to handle script exit (whether successful or not).
cleanup_handler() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "[INFO] Script completed successfully."
  else
    echo "[INFO] Script exited with error code: $exit_code"
  fi
}

# Attach traps
trap 'error_handler $LINENO' ERR
trap cleanup_handler EXIT

###############################################################################
#                          UTILITY FUNCTIONS
###############################################################################
log() {
  # Logs a message to stdout and optionally to a specified log file.
  local message="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') : $message"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $message" >> "$LOG_FILE"
  fi
}

check_command_exists() {
  # Checks if a command is available on the system.
  command -v "$1" &>/dev/null
}

install_docker_if_missing() {
  # Installs Docker if it's not found, based on the AUTO_INSTALL_DOCKER variable.
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
  # Ensures the script is run as root or via sudo.
  if [[ $EUID -ne 0 ]]; then
    log "[ERROR] Please run this script as root or with sudo."
    exit 1
  fi
}

validate_port_availability() {
  # Checks if the desired port is already in use.
  if ss -tulpn | grep -q ":${OPENLLM_EXPOSED_PORT} "; then
    log "[ERROR] Port ${OPENLLM_EXPOSED_PORT} is already in use. Choose a different port."
    exit 1
  fi
}

create_data_directory() {
  # Creates the data directory if it doesn't exist.
  if [[ -d "$OPENLLM_DATA_DIR" ]]; then
    log "[INFO] Data directory $OPENLLM_DATA_DIR already exists."
  else
    log "[INFO] Creating data directory $OPENLLM_DATA_DIR"
    mkdir -p "$OPENLLM_DATA_DIR"
    if [[ ! -d "$OPENLLM_DATA_DIR" ]]; then
      log "[ERROR] Failed to create data directory $OPENLLM_DATA_DIR."
      exit 1
    fi
  fi
}

pull_docker_image() {
  # Pulls the specified OpenLLM Docker image.
  log "[INFO] Pulling Docker image: $OPENLLM_DOCKER_IMAGE"
  docker pull "$OPENLLM_DOCKER_IMAGE"
}

run_openllm_container() {
  # Runs the OpenLLM container with the specified configuration.
  log "[INFO] Running OpenLLM container with name: $CONTAINER_NAME"

  # If a container with the same name exists, remove it.
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    log "[INFO] A container named $CONTAINER_NAME already exists. Stopping and removing it..."
    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
  fi

  # Here we assume a typical run command:
  #   openllm start --model $OPENLLM_MODEL_NAME --port 3000
  # In the Docker container, that's usually done automatically, but let's pass
  # environment variables or custom commands as needed.

  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${OPENLLM_EXPOSED_PORT}:3000" \
    -v "${OPENLLM_DATA_DIR}:/openllm_data" \
    "$OPENLLM_DOCKER_IMAGE" \
    start --model "$OPENLLM_MODEL_NAME" --port 3000

  # Validate the container started successfully
  if [[ $(docker ps --format '{{.Names}}' | grep "^${CONTAINER_NAME}\$") == "$CONTAINER_NAME" ]]; then
    log "[INFO] OpenLLM container '$CONTAINER_NAME' is running."
  else
    log "[ERROR] OpenLLM container failed to start."
    exit 1
  fi
}

###############################################################################
#                            MAIN EXECUTION FLOW
###############################################################################
main() {
  log "[INFO] Starting OpenLLM Docker Setup Script..."

  # 1. Validate host environment
  validate_host_environment

  # 2. Check/install Docker
  install_docker_if_missing

  # 3. Double-check Docker command presence
  if ! check_command_exists "docker"; then
    log "[ERROR] Docker command not found after installation attempt. Exiting."
    exit 1
  fi

  # 4. Validate port availability
  validate_port_availability

  # 5. Validate or create data directory
  create_data_directory

  # 6. Pull the OpenLLM Docker image
  pull_docker_image

  # 7. Run the container
  run_openllm_container

  log "[INFO] OpenLLM Docker Setup Script completed."
  log "[INFO] Access your OpenLLM instance via http://<Your-Host-IP>:${OPENLLM_EXPOSED_PORT}"
  log "[INFO] You may configure additional parameters by editing script variables or container run command."
}

# Execute main function
main
