#!/bin/bash

function waitForApiServer() {
    readinessCheck "Higress API Server" 18443
}

function waitForController() {
    readinessCheck "Higress Controller" 15051
}

function waitForPilot() {
    readinessCheck "Higress Pilot" 15010
}

function readinessCheck() {
    # $1=name
    # $2=port
    while true; do
        echo "Checking the readiness of $1..."
        nc -z 127.0.0.1 $2
        if [ $? -eq 0 ]; then
            break
        fi
        sleep 1
    done
}

function createDir() {
    sudo mkdir -p "$1"
}

function isO11yInstalled() {
    if [ -f "/usr/local/bin/promtail" ] && [ -f "/usr/local/bin/prometheus" ] && [ -f "/usr/local/bin/grafana.sh" ] && [ -f "/usr/local/bin/loki" ]; then
        return 0
    else
        return 1
    fi
}

case $MODE in
    gateway|console|full)
        # Known modes
        ;;
    *)
        # Default to full mode
        MODE=full
        ;;
esac
echo "Mode=$MODE"

if ! isO11yInstalled; then
    echo "O11Y components are not installed."
    # Disable O11Y
    O11Y=off
fi

case $O11Y in
    true|TRUE|on|ON|yes|YES)
        O11Y=on
        ;;
    *)
        # Default to off
        O11Y=off
        ;;
esac
echo "O11Y=$O11Y"

case $USE_PLUGIN_SERVER in
    false|FALSE|off|OFF|no|NO|N|n)
        USE_PLUGIN_SERVER=off
        ;;
    *)
        # Default to on
        USE_PLUGIN_SERVER=on
        ;;
esac
echo "USE_PLUGIN_SERVER=$USE_PLUGIN_SERVER"

CONSOLE_USED_MARKER='/data/.console-used'
CONSOLE_USED='false'
if [ -f "$CONSOLE_USED_MARKER" ]; then
  CONSOLE_USED='true'
fi