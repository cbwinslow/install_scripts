#!/usr/bin/env bash
################################################################################
# File: /usr/local/bin/install_pihole.sh
# Author: Your Name
# Date: 2025-03-23
# Purpose: Demonstrate an automated Pi-hole installation procedure.
# Inputs: None
# Outputs: None
# Description: This script updates the system, installs Pi-hole, and confirms
#              the installation with basic error checking. It is meant for
#              Debian-based distributions.
################################################################################

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to print an error and exit
function error_exit() {
  echo "ERROR: $1"
  exit 1
}

# 1. Update and Upgrade the System
echo "Updating and upgrading system packages..."
apt-get update || error_exit "Failed to update package lists."
apt-get upgrade -y || error_exit "Failed to upgrade packages."

# 2. Download and Install Pi-hole
echo "Downloading and installing Pi-hole..."
# Always review the Pi-hole script if you have concerns
curl -sSL https://install.pi-hole.net | bash || error_exit "Pi-hole installation failed."

# 3. Provide Final Information
echo "Pi-hole installation script completed successfully."
echo "Remember to set up a static IP address for your device, configure your DNS settings,"
echo "and note the password for the Pi-hole admin interface."
echo "If needed, run: pihole -a -p  to change the password."

exit 0
