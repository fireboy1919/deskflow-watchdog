#!/bin/bash
# Diagnostic script to test stuck key detection

echo "=== Keyboard Devices ==="
xinput list | grep keyboard

echo ""
echo "=== Master Keyboard State ==="
master_id=$(xinput list --id-only "Virtual core keyboard" 2>/dev/null)
echo "Master ID: $master_id"
xinput query-state "$master_id" | grep -E "key\[(50|62|37|105|64|108|133|134|67)\]"

echo ""
echo "=== Physical Keyboard State ==="
physical_id=$(xinput list | grep "slave  keyboard" \
    | grep -v -E "XTEST|Power Button|Video Bus|Sleep Button|Hotkey|HID events" \
    | head -1 | grep -oP 'id=\K[0-9]+')
echo "Physical ID: $physical_id"
if [ -n "$physical_id" ]; then
    xinput query-state "$physical_id" | grep -E "key\[(50|62|37|105|64|108|133|134|67)\]"
else
    echo "Could not find physical keyboard"
fi

echo ""
echo "=== All Key States on Master ==="
xinput query-state "$master_id" | grep "key\[" | grep "down"

echo ""
echo "=== xset Lock Status ==="
xset q | grep -A 2 "LED mask"

echo ""
echo "Legend:"
echo "  Shift_L=50, Shift_R=62"
echo "  Control_L=37, Control_R=105"
echo "  Alt_L=64, Alt_R=108"
echo "  Super_L=133, Super_R=134"
echo "  F1=67 (Deskflow switch key)"
