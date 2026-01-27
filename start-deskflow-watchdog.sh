#!/bin/bash

# Wrapper script to start the Deskflow watchdog with proper environment.
# Locates the main watchdog script relative to itself, so it works
# regardless of where the directory is installed.

# Wait for GUI environment to be ready
sleep 10

# Set up environment variables
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Find the main watchdog script in the same directory as this wrapper
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/deskflow-watchdog.sh"
