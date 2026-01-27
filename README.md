# Deskflow Watchdog

A systemd watchdog that solves two problems with Deskflow on Linux:

1. **Stuck modifier keys** -- When Deskflow's connection drops, it can leave Shift, Ctrl, Alt, or Super stuck in the "down" state. This happens because Deskflow injects keystrokes via X11's XTEST extension, and a connection interruption can send a key-down without a matching key-up. The result is that all your typing comes out in capitals, shortcuts fire unexpectedly, etc.

2. **Random disconnections** -- Deskflow's client can silently lose its connection to the server. The watchdog detects this and automatically reconnects via GUI automation (F5 restart), then releases any modifier keys that got stuck during the drop.

## How it works

**Stuck key detection** compares the X11 master keyboard state against the physical keyboard state using `xinput query-state`. A modifier reported as "down" on the master keyboard but not on the physical keyboard means Deskflow injected a key-down without a key-up. The physical keyboard is auto-detected by filtering out virtual/system devices (XTEST, Power Button, Video Bus, etc.), so it works with PS/2, USB, and Bluetooth keyboards.

**Stuck key release** uses `xdotool keyup` to release all modifier keys, `xset r on` to reset repeat state, and `setxkbmap -option` to reset the keyboard layout.

**Connection monitoring** tracks the Deskflow GUI and client processes. If the client process isn't running or keeps restarting (runtime under 15 seconds), it detects a connection failure and attempts automatic reconnection up to 3 times.

## Requirements

- **Deskflow** on `$PATH`
- **X11 session** (Xorg or XWayland) -- does not work on pure Wayland
- Command-line tools: `xinput`, `xdotool`, `xset`, `setxkbmap`
  - Debian/Ubuntu: `sudo apt install xinput xdotool x11-xserver-utils x11-xkb-utils`
  - Fedora: `sudo dnf install xinput xdotool xorg-x11-server-utils xorg-x11-xkb-utils`
  - Arch: `sudo pacman -S xorg-xinput xdotool xorg-xset xorg-setxkbmap`

## Installation

1. **Copy this directory** to your home folder:
   ```bash
   cp -r deskflow-watchdog ~/deskflow-watchdog
   ```

2. **Make the scripts executable:**
   ```bash
   chmod +x ~/deskflow-watchdog/*.sh
   ```

3. **Install the systemd user service:**
   ```bash
   mkdir -p ~/.config/systemd/user
   cp ~/deskflow-watchdog/deskflow-watchdog.service \
      ~/.config/systemd/user/deskflow-watchdog.service
   ```

   If you placed the directory somewhere other than `~/deskflow-watchdog/`, edit the `ExecStart=` line in the service file to match.

4. **Enable and start the service:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable deskflow-watchdog.service
   systemctl --user start deskflow-watchdog.service
   ```

5. **Verify it's running:**
   ```bash
   systemctl --user status deskflow-watchdog.service
   ```

## Configuration

Edit `deskflow-watchdog.sh` to adjust these variables at the top of the file:

| Variable | Default | Description |
|---|---|---|
| `CHECK_INTERVAL` | `10` | Seconds between main loop iterations |
| `PERIODIC_KEY_CHECK_INTERVAL` | `10` | Seconds between stuck key checks |
| `MAX_RECONNECT_ATTEMPTS` | `3` | Reconnection attempts before waiting |
| `CONNECTION_STABLE_TIME` | `30` | Seconds a connection must be up to be "stable" |

### Optional: Disable Caps Lock

To permanently disable Caps Lock (useful if Deskflow keeps toggling it), uncomment this line in `unstick_modifier_keys()`:

```bash
# setxkbmap -option caps:none 2>/dev/null
```

## Logs

Logs are written to `~/.local/share/deskflow-watchdog.log`. To follow in real time:

```bash
tail -f ~/.local/share/deskflow-watchdog.log
```

## Uninstalling

```bash
systemctl --user stop deskflow-watchdog.service
systemctl --user disable deskflow-watchdog.service
rm ~/.config/systemd/user/deskflow-watchdog.service
systemctl --user daemon-reload
rm -rf ~/deskflow-watchdog
```
