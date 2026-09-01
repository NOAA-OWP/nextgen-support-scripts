#!/bin/bash

NGENCERF_APP=/ngencerf-app

echo "================================================================================"
echo "                        Full Cluster Cleanup Script                            "
echo "================================================================================"
echo ""
echo "This script will remove all files and configurations created by configure_cluster.sh"
echo ""
echo "WARNING: This will delete:"
echo "  - All cloned repositories in /ngencerf-app"
echo "  - All Singularity containers in /ngencerf-app/singularity"
echo "  - All static files in /ngencerf-app/data"
echo "  - All Docker images (optional)"
echo "  - The logrotate cron job"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

# ------------------------------------------------------------------------------
# Remove cloned repositories
# ------------------------------------------------------------------------------
echo "Removing cloned repositories..."
cd $NGENCERF_APP

if [[ -d "nwm-automation-scripts" ]]; then
    sudo rm -rf nwm-automation-scripts 2>/dev/null || {
        # If rm fails (e.g., script running from inside), use find
        sudo find nwm-automation-scripts -delete 2>/dev/null || true
    }
    echo "  - Removed nwm-automation-scripts"
fi

if [[ -d "ngencerf-ui" ]]; then
    rm -rf ngencerf-ui
    echo "  - Removed ngencerf-ui"
fi

if [[ -d "ngencerf-server" ]]; then
    rm -rf ngencerf-server
    echo "  - Removed ngencerf-server"
fi

if [[ -d "ngencerf-docker" ]]; then
    rm -rf ngencerf-docker
    echo "  - Removed ngencerf-docker"
fi

if [[ -d "ngen" ]]; then
    rm -rf ngen
    echo "  - Removed ngen"
fi

if [[ -d "nwm-cal-mgr" ]]; then
    rm -rf nwm-cal-mgr
    echo "  - Removed nwm-cal-mgr"
fi

if [[ -d "ngen-forcing" ]]; then
    rm -rf ngen-forcing
    echo "  - Removed ngen-forcing"
fi

if [[ -d "nwm-fcst-mgr" ]]; then
    rm -rf nwm-fcst-mgr
    echo "  - Removed nwm-fcst-mgr"
fi

if [[ -d "nwm-verf" ]]; then
    rm -rf nwm-verf
    echo "  - Removed nwm-verf"
fi

echo ""

# ------------------------------------------------------------------------------
# Remove Singularity containers
# ------------------------------------------------------------------------------
echo "Removing Singularity containers..."
if [[ -d "$NGENCERF_APP/singularity" ]]; then
    rm -rf $NGENCERF_APP/singularity
    echo "  - Removed singularity directory"
else
    echo "  - No singularity directory found"
fi

echo ""

# ------------------------------------------------------------------------------
# Remove static files
# ------------------------------------------------------------------------------
echo "Removing static files..."
if [[ -d "$NGENCERF_APP/data" ]]; then
    sudo rm -rf $NGENCERF_APP/data
    echo "  - Removed data directory"
else
    echo "  - No data directory found"
fi

echo ""

# ------------------------------------------------------------------------------
# Remove Docker images (optional)
# ------------------------------------------------------------------------------
echo "Do you want to remove Docker images? (They take time to re-download)"
read -p "Remove Docker images? (yes/no): " REMOVE_DOCKER

if [[ "$REMOVE_DOCKER" == "yes" ]]; then
    echo "Removing Docker images..."

    docker rmi ghcr.io/ngwpc/ngen:latest 2>/dev/null && echo "  - Removed ngen image" || echo "  - ngen image not found"
    docker rmi ghcr.io/ngwpc/nwm-cal-mgr:latest 2>/dev/null && echo "  - Removed nwm-cal-mgr image" || echo "  - nwm-cal-mgr image not found"
    docker rmi ghcr.io/ngwpc/ngen-bmi-forcing:latest 2>/dev/null && echo "  - Removed ngen-bmi-forcing image" || echo "  - ngen-bmi-forcing image not found"
    docker rmi ghcr.io/ngwpc/ngen-coastal:latest 2>/dev/null && echo "  - Removed ngen-coastal image" || echo "  - ngen-coastal image not found"
    docker rmi ghcr.io/ngwpc/ngen-sfincs-forcing:latest 2>/dev/null && echo "  - Removed ngen-sfincs-forcing image" || echo "  - ngen-sfincs-forcing image not found"
    docker rmi ghcr.io/ngwpc/nwm-fcst-mgr:latest 2>/dev/null && echo "  - Removed nwm-fcst-mgr image" || echo "  - nwm-fcst-mgr image not found"
    docker rmi ghcr.io/ngwpc/nwm-verf:latest 2>/dev/null && echo "  - Removed nwm-verf image" || echo "  - nwm-verf image not found"

    echo ""
    echo "Running docker system prune to clean up unused data..."
    docker system prune -f
else
    echo "  - Skipping Docker image removal"
fi

echo ""

# ------------------------------------------------------------------------------
# Remove logrotate cron job
# ------------------------------------------------------------------------------
echo "Removing logrotate cron job..."
if [[ -f "/etc/cron.d/ngencerf-logrotate" ]]; then
    sudo rm -f /etc/cron.d/ngencerf-logrotate
    echo "  - Removed logrotate cron job"
else
    echo "  - No logrotate cron job found"
fi

echo ""
echo "================================================================================"
echo "Cleanup complete!"
echo "================================================================================"
echo ""
echo "Your cluster has been reset to a clean state."
echo "You can now run configure_cluster.sh again to set it up."
echo ""
