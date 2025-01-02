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

case $O11Y in
    true|TRUE|on|ON|yes|YES)
        O11Y=on
        ;;
    *)
        # Default to full mode
        O11Y=off
        ;;
esac
echo "O11Y=$O11Y"

CONSOLE_USED_MARKER='/data/.console-used'
CONSOLE_USED='false'
if [ -f "$CONSOLE_USED_MARKER" ]; then
  CONSOLE_USED='true'
fi