#!/usr/bin/env bash
###############################################################################
# Script Name: langchain_langraph_langsmith_gpu_setup.sh
# Author: ChatGPT
# Description:
#   This script automates the setup of a Docker container that includes
#   LangChain, Langraph, and LangSmith, with optional GPU support for either
#   NVIDIA or AMD. It dynamically generates a Dockerfile based on your choice
#   of GPU support ("NVIDIA", "AMD", or "NONE").
#
# Usage:
#   1. Make it executable: chmod +x langchain_langraph_langsmith_gpu_setup.sh
#   2. Run (as root or via sudo): ./langchain_langraph_langsmith_gpu_setup.sh
#   3. Adjust environment variables in the "VARIABLE DECLARATIONS" section.
#
# Notes:
#   - The script checks/installs Docker if AUTO_INSTALL_DOCKER=true.
#   - For NVIDIA GPU usage, ensure the host OS has the NVIDIA driver and
#     nvidia-container-toolkit. You can run the container with "--gpus all".
#   - For AMD GPU usage, you often need ROCm drivers on host, and may pass
#     /dev/dri or other devices into the container.
#   - This script provides a minimal demonstration; real-world HPC or
#     advanced usage will likely require more steps.
###############################################################################

###############################################################################
#                          VARIABLE DECLARATIONS
###############################################################################
# Name of the Docker container
CONTAINER_NAME="langchain_gpu_container"

# Name/Tag for the Docker image to be built
CUSTOM_DOCKER_IMAGE_NAME="myorg/langchain-libraries-gpu:latest"

# Exposed port where we’ll run a demo service (Langraph in this example)
LANGCHAIN_EXPOSED_PORT="3000"

# Directory on the host to mount into the container
LANGCHAIN_DATA_DIR="/srv/langchain_data"

# GPU support: "NVIDIA", "AMD", or "NONE"
GPU_SUPPORT="NONE"

# (Optional) Install Docker if not found. If set to false, script will exit if Docker is missing.
AUTO_INSTALL_DOCKER=true

# Debian/Ubuntu Docker dependencies (adjust if needed).
DOCKER_DEPENDENCIES=("apt-transport-https" "ca-certificates" "curl" "gnupg" "lsb-release")

# Log file path (if you want to log script output to a file).
LOG_FILE="/var/log/langchain_gpu_setup.log"

###############################################################################
#                          ERROR HANDLING & TRAPS
###############################################################################
set -Euo pipefail  # Strict bash settings: error on unset vars, pipeline failures
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
  if ss -tulpn | grep -q ":${LANGCHAIN_EXPOSED_PORT} "; then
    log "[ERROR] Port ${LANGCHAIN_EXPOSED_PORT} is already in use. Choose a different port."
    exit 1
  fi
}

create_data_directory() {
  if [[ -d "$LANGCHAIN_DATA_DIR" ]]; then
    log "[INFO] Data directory $LANGCHAIN_DATA_DIR already exists."
  else
    log "[INFO] Creating data directory $LANGCHAIN_DATA_DIR"
    mkdir -p "$LANGCHAIN_DATA_DIR"
    if [[ ! -d "$LANGCHAIN_DATA_DIR" ]]; then
      log "[ERROR] Failed to create data directory $LANGCHAIN_DATA_DIR."
      exit 1
    fi
  fi
}

create_dockerfile() {
  BUILD_DIR=$(mktemp -d)
  export BUILD_DIR

  # Decide base image depending on GPU_SUPPORT
  local base_image="python:3.10"
  local extra_instructions=""

  if [[ "$GPU_SUPPORT" == "NVIDIA" ]]; then
    # Using an NVIDIA CUDA runtime base image with Python installed.
    # Adjust CUDA version as needed.
    base_image="nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04"
    # Minimal extra instructions: install Python 3.10, pip, etc.
    extra_instructions=$(cat <<EOT

# Install Python 3.10 (runtime) in the CUDA base
RUN apt-get update && apt-get install -y python3.10 python3.10-distutils curl && \\
    ln -sf /usr/bin/python3.10 /usr/bin/python && \\
    curl -sS https://bootstrap.pypa.io/get-pip.py | python

EOT
)
  elif [[ "$GPU_SUPPORT" == "AMD" ]]; then
    # Using an AMD ROCm base image example
    # For a real production environment, you might need the official rocm/dev image
    base_image="rocm/dev-ubuntu-22.04:5.6-complete"
    extra_instructions=$(cat <<EOT

# Ensure Python 3.10 is installed in the ROCm base
RUN apt-get update && apt-get install -y python3.10 python3.10-distutils curl && \\
    ln -sf /usr/bin/python3.10 /usr/bin/python && \\
    curl -sS https://bootstrap.pypa.io/get-pip.py | python

# (Optional) Additional ROCm libraries or environment variables can be added here.
EOT
)
  else
    # GPU_SUPPORT = "NONE", default python:3.10 (already has python3.10, pip, etc.)
    base_image="python:3.10"
  fi

  cat <<EOF > "$BUILD_DIR/Dockerfile"
###############################################################################
# Auto-generated Dockerfile for LangChain, Langraph, LangSmith
# GPU_SUPPORT = $GPU_SUPPORT
###############################################################################
FROM ${base_image}

# If necessary, set DEBIAN_FRONTEND=noninteractive to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

${extra_instructions}

# Install packages
RUN pip install --no-cache-dir langchain langraph langsmith

# Expose port for demonstration
EXPOSE 3000

WORKDIR /app

# Example entrypoint: run Langraph with a local server
CMD ["langraph", "serve", "--host", "0.0.0.0", "--port", "3000"]
EOF

  log "[INFO] Dockerfile created at $BUILD_DIR/Dockerfile for GPU_SUPPORT=$GPU_SUPPORT"
}

build_docker_image() {
  log "[INFO] Building Docker image: $CUSTOM_DOCKER_IMAGE_NAME"
  docker build -t "$CUSTOM_DOCKER_IMAGE_NAME" "$BUILD_DIR"
}

run_langchain_container() {
  log "[INFO] Running container with name: $CONTAINER_NAME"

  # Remove existing container if present
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    log "[INFO] A container named $CONTAINER_NAME already exists. Stopping and removing it..."
    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
  fi

  # Decide if we need GPU flags in "docker run"
  local gpu_flag=""
  if [[ "$GPU_SUPPORT" == "NVIDIA" ]]; then
    # For NVIDIA, typically pass "--gpus all"
    gpu_flag="--gpus all"
  elif [[ "$GPU_SUPPORT" == "AMD" ]]; then
    # AMD usage is more complicated; you might pass devices manually
    # e.g. `--device=/dev/dri --group-add video`
    # We'll show an example placeholder:
    gpu_flag="--device=/dev/dri --group-add video"
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    $gpu_flag \
    -p "${LANGCHAIN_EXPOSED_PORT}:3000" \
    -v "${LANGCHAIN_DATA_DIR}:/app/data" \
    "$CUSTOM_DOCKER_IMAGE_NAME"

  if [[ $(docker ps --format '{{.Names}}' | grep "^${CONTAINER_NAME}\$") == "$CONTAINER_NAME" ]]; then
    log "[INFO] Container '$CONTAINER_NAME' is now running."
  else
    log "[ERROR] Container failed to start."
    exit 1
  fi
}

main() {
  log "[INFO] Starting LangChain/Langraph/LangSmith GPU-Aware Docker Setup Script..."

  validate_host_environment
  install_docker_if_missing

  if ! check_command_exists "docker"; then
    log "[ERROR] Docker command not found after installation attempt. Exiting."
    exit 1
  fi

  validate_port_availability
  create_data_directory
  create_dockerfile
  build_docker_image
  run_langchain_container

  log "[INFO] Setup Script completed."
  log "[INFO] Access the container via http://<Host-IP>:${LANGCHAIN_EXPOSED_PORT}"
  log "[INFO] Docker image used: $CUSTOM_DOCKER_IMAGE_NAME"
  log "[INFO] GPU support mode: $GPU_SUPPORT"
  log "[INFO] To stop the container: docker stop ${CONTAINER_NAME}"
  log "[INFO] To remove it: docker rm ${CONTAINER_NAME}"
}

main
