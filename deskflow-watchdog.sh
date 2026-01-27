#!/bin/bash
#
# Deskflow Watchdog
#
# Monitors Deskflow for:
#   1. Stuck modifier keys (Shift, Ctrl, Alt, Super) caused by Deskflow's
#      XTEST key injection losing key-up events on connection interruption
#   2. Caps Lock / Scroll Lock stuck in "on" state
#   3. Deskflow connection failures, with automatic reconnection
#
# Detection works by comparing the X11 master keyboard state against the
# physical keyboard state. A modifier "down" on master but not on physical
# means Deskflow sent a key-down without a matching key-up.
#
# Requirements: xinput, xdotool, xset, setxkbmap, deskflow
# Environment:  X11 (Xorg or XWayland). Does not work on pure Wayland.

LOG_FILE="$HOME/.local/share/deskflow-watchdog.log"
CHECK_INTERVAL=10
MAX_RECONNECT_ATTEMPTS=3
RECONNECT_COUNT=0
CONNECTION_STABLE_TIME=30
PERIODIC_KEY_CHECK_INTERVAL=10  # Check for stuck keys every 10 seconds
LAST_KEY_CHECK_TIME=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_for_stuck_keys() {
    # Detect modifier keys stuck by Deskflow (via XTEST) by comparing
    # master keyboard state vs physical keyboard state.
    # A key "down" on master but not on physical = stuck from Deskflow.
    if ! command -v xinput >/dev/null 2>&1; then
        return 1
    fi

    # Modifier keycodes: Shift_L=50, Shift_R=62, Control_L=37, Control_R=105,
    #                    Alt_L=64, Alt_R=108, Super_L=133, Super_R=134
    local -A modifier_names=(
        [50]="Shift_L" [62]="Shift_R"
        [37]="Control_L" [105]="Control_R"
        [64]="Alt_L" [108]="Alt_R"
        [133]="Super_L" [134]="Super_R"
    )

    # Look up device IDs dynamically (they can change between boots)
    local master_id physical_id
    master_id=$(xinput list --id-only "Virtual core keyboard" 2>/dev/null)

    # Auto-detect the physical keyboard: find the first slave keyboard that
    # isn't a virtual/system device. Works across PS/2, USB, Bluetooth keyboards.
    physical_id=$(xinput list | grep "slave  keyboard" \
        | grep -v -E "XTEST|Power Button|Video Bus|Sleep Button|Hotkey|HID events" \
        | head -1 | grep -oP 'id=\K[0-9]+')

    if [ -z "$master_id" ] || [ -z "$physical_id" ]; then
        return 1
    fi

    local master_state physical_state
    master_state=$(xinput query-state "$master_id" 2>/dev/null)
    physical_state=$(xinput query-state "$physical_id" 2>/dev/null)

    if [ -z "$master_state" ]; then
        return 1
    fi

    # Find modifiers down on master but NOT on physical keyboard
    local stuck_keys=()
    for keycode in "${!modifier_names[@]}"; do
        if echo "$master_state" | grep -q "key\[$keycode\]=down"; then
            if ! echo "$physical_state" | grep -q "key\[$keycode\]=down"; then
                stuck_keys+=("${modifier_names[$keycode]}")
            fi
        fi
    done

    if [ ${#stuck_keys[@]} -gt 0 ]; then
        # Confirm it's truly stuck by rechecking after a short delay
        sleep 0.5
        master_state=$(xinput query-state "$master_id" 2>/dev/null)
        physical_state=$(xinput query-state "$physical_id" 2>/dev/null)

        local confirmed_stuck=()
        for keycode in "${!modifier_names[@]}"; do
            if echo "$master_state" | grep -q "key\[$keycode\]=down"; then
                if ! echo "$physical_state" | grep -q "key\[$keycode\]=down"; then
                    confirmed_stuck+=("${modifier_names[$keycode]}")
                fi
            fi
        done

        if [ ${#confirmed_stuck[@]} -gt 0 ]; then
            log "Detected stuck keys (Deskflow/XTEST, not physical): ${confirmed_stuck[*]}"
            return 0
        fi
    fi

    # Also check LED locks via xset (Caps Lock, Scroll Lock)
    if command -v xset >/dev/null 2>&1; then
        local xset_output
        xset_output=$(xset q 2>/dev/null)
        local lock_stuck=()
        echo "$xset_output" | grep -q "Caps Lock:.*on" && lock_stuck+=("Caps Lock")
        echo "$xset_output" | grep -q "Scroll Lock:.*on" && lock_stuck+=("Scroll Lock")
        if [ ${#lock_stuck[@]} -gt 0 ]; then
            log "Detected stuck lock keys: ${lock_stuck[*]}"
            return 0
        fi
    fi

    return 1
}

unstick_modifier_keys() {
    log "Releasing stuck modifier keys..."

    # Method 1: Use xdotool to force key release (comprehensive)
    if command -v xdotool >/dev/null 2>&1; then
        # Release all variations of modifier keys
        xdotool keyup Shift_L Shift_R Control_L Control_R Alt_L Alt_R Super_L Super_R Caps_Lock 2>/dev/null
        xdotool keyup shift ctrl alt super hyper meta 2>/dev/null
    fi

    # Method 2: Reset keyboard state with xset
    if command -v xset >/dev/null 2>&1; then
        xset r on 2>/dev/null
    fi

    # Method 3: Reset keyboard layout and toggle caps lock
    if command -v setxkbmap >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1; then
        setxkbmap -option 2>/dev/null
        # Uncomment the next line if you want Caps Lock disabled permanently:
        # setxkbmap -option caps:none 2>/dev/null
        xdotool key Caps_Lock Caps_Lock 2>/dev/null
    fi

    log "Modifier keys released"
}

is_deskflow_gui_running() {
    pgrep -f "^deskflow$|deskflow-gui" > /dev/null 2>&1
}

is_client_process_running() {
    pgrep -f "deskflow-core client" > /dev/null 2>&1
}

get_client_runtime() {
    local client_pid
    client_pid=$(pgrep -f "deskflow-core client")

    if [ -z "$client_pid" ]; then
        echo "0"
        return
    fi

    local start_time
    start_time=$(ps -o lstart= -p "$client_pid" 2>/dev/null | xargs -I {} date -d "{}" +%s 2>/dev/null)
    local current_time
    current_time=$(date +%s)

    if [ -n "$start_time" ]; then
        echo $((current_time - start_time))
    else
        echo "0"
    fi
}

is_connection_healthy() {
    if ! is_deskflow_gui_running; then
        return 1
    fi

    if ! is_client_process_running; then
        return 1
    fi

    # Check if client has been running long enough to be considered stable
    local runtime
    runtime=$(get_client_runtime)

    if [ "$runtime" -gt "$CONNECTION_STABLE_TIME" ]; then
        return 0
    else
        return 1
    fi
}

has_recent_connection_failure() {
    # Check for recent connection failures in the client process behavior
    local client_pid
    client_pid=$(pgrep -f "deskflow-core client")

    if [ -z "$client_pid" ]; then
        return 0  # No client = failure
    fi

    local runtime
    runtime=$(get_client_runtime)

    # If client keeps restarting (runtime < 15 seconds), it's failing
    if [ "$runtime" -lt 15 ]; then
        return 0  # Recent failure
    fi

    return 1  # No recent failure detected
}

click_reconnect_button() {
    log "Attempting to click reconnect button via GUI automation..."

    # Find the Deskflow window
    local window_id
    window_id=$(xdotool search --name "^Deskflow$" | head -1)

    if [ -z "$window_id" ]; then
        log "Could not find Deskflow window"
        return 1
    fi

    # Bring window to front
    xdotool windowactivate "$window_id"
    sleep 1

    # Look for buttons with text containing "Start", "Restart", or "Connect"
    # First try to find and click a "Restart" button
    if xdotool search --name "Restart" 2>/dev/null | head -1 | xargs -I {} xdotool windowactivate {} 2>/dev/null; then
        log "Found and clicked Restart button"
        return 0
    fi

    # Alternative: try keyboard shortcut (F5 for restart in Deskflow)
    log "Trying keyboard shortcut to restart core..."
    xdotool windowactivate "$window_id"
    sleep 0.5
    xdotool key F5

    log "Sent F5 restart command to Deskflow window"
    return 0
}

start_deskflow_if_needed() {
    if ! is_deskflow_gui_running; then
        log "Deskflow GUI not running, starting it..."
        DISPLAY=${DISPLAY:-:0} nohup deskflow > /tmp/deskflow-auto.log 2>&1 &
        sleep 10

        if is_deskflow_gui_running; then
            log "Deskflow GUI started successfully"
            return 0
        else
            log "Failed to start Deskflow GUI"
            return 1
        fi
    fi
    return 0
}

attempt_reconnection() {
    RECONNECT_COUNT=$((RECONNECT_COUNT + 1))
    log "Reconnection attempt $RECONNECT_COUNT/$MAX_RECONNECT_ATTEMPTS"

    # Ensure GUI is running
    if ! start_deskflow_if_needed; then
        log "Cannot reconnect - GUI failed to start"
        return 1
    fi

    # Try to click the reconnect button
    if click_reconnect_button; then
        log "Reconnect command sent successfully"

        # Wait for reconnection to establish
        local wait_count=0
        while [ $wait_count -lt 8 ]; do  # Wait up to 80 seconds
            sleep 10
            wait_count=$((wait_count + 1))

            if is_connection_healthy; then
                log "Reconnection successful - connection stable!"
                unstick_modifier_keys  # Fix stuck keys after reconnection
                RECONNECT_COUNT=0
                return 0
            fi

            log "Waiting for reconnection to stabilize... ($((wait_count * 10))s/80s)"
        done

        log "Reconnect command sent but connection not established"
        return 1
    else
        log "Failed to send reconnect command"
        return 1
    fi
}

log "Deskflow automated reconnect watchdog starting..."

# Ensure Deskflow is running initially
start_deskflow_if_needed

# Main monitoring loop
while true; do
    # Periodic check for stuck keys (even during healthy connections)
    current_time=$(date +%s)
    if [ $((current_time - LAST_KEY_CHECK_TIME)) -ge $PERIODIC_KEY_CHECK_INTERVAL ]; then
        if check_for_stuck_keys; then
            unstick_modifier_keys
        fi
        LAST_KEY_CHECK_TIME=$current_time
    fi

    if is_connection_healthy; then
        # Connection is healthy, reset reconnect counter
        if [ $RECONNECT_COUNT -gt 0 ]; then
            log "Connection healthy, resetting reconnect counter"
            RECONNECT_COUNT=0
        fi
    elif is_deskflow_gui_running; then
        # GUI running but connection not healthy
        if has_recent_connection_failure; then
            log "Recent connection failure detected"
            unstick_modifier_keys  # Fix stuck keys on disconnect

            if [ $RECONNECT_COUNT -lt $MAX_RECONNECT_ATTEMPTS ]; then
                attempt_reconnection
            else
                log "Max reconnection attempts reached. Waiting before reset..."
                sleep 60
                RECONNECT_COUNT=0
            fi
        else
            log "Client process exists but connection not yet stable, waiting..."
        fi
    else
        # GUI not running at all
        log "Deskflow GUI not running"
        RECONNECT_COUNT=0  # Reset counter for fresh start
        start_deskflow_if_needed
    fi

    sleep $CHECK_INTERVAL
done
