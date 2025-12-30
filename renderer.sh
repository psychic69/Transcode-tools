#!/bin/bash

# Script to map DRM render devices to hardware information
# Usage: ./renderer.sh

echo "=== DRM Render Device Mapping ==="
echo ""

# Find all render devices
for device in /dev/dri/renderD*; do
    if [ -e "$device" ]; then
        device_name=$(basename "$device")
        device_number=$(echo "$device_name" | sed 's/renderD//')
        
        echo "┌─────────────────────────────────────────"
        echo "│ Device: $device_name"
        echo "├─────────────────────────────────────────"
        
        # Get the card number (renderD128 = card0, renderD129 = card1, etc.)
        card_number=$((device_number - 128))
        card_device="/dev/dri/card${card_number}"
        
        if [ -e "$card_device" ]; then
            echo "│ Associated Card: card${card_number}"
            
            # Get PCI device path
            card_path=$(udevadm info --query=path --name="$card_device" 2>/dev/null)
            
            if [ -n "$card_path" ]; then
                # Extract PCI address
                pci_address=$(echo "$card_path" | grep -oP '0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | head -1)
                
                if [ -n "$pci_address" ]; then
                    echo "│ PCI Address: $pci_address"
                    
                    # Get device information from lspci
                    device_info=$(lspci -s "$pci_address" 2>/dev/null)
                    if [ -n "$device_info" ]; then
                        echo "│ Hardware Info: $device_info"
                    fi
                    
                    # Get vendor and device IDs
                    if [ -d "/sys/bus/pci/devices/$pci_address" ]; then
                        vendor=$(cat "/sys/bus/pci/devices/$pci_address/vendor" 2>/dev/null)
                        device_id=$(cat "/sys/bus/pci/devices/$pci_address/device" 2>/dev/null)
                        
                        if [ -n "$vendor" ] && [ -n "$device_id" ]; then
                            echo "│ Vendor ID: $vendor"
                            echo "│ Device ID: $device_id"
                        fi
                        
                        # Get driver information
                        driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_address/driver" 2>/dev/null)" 2>/dev/null)
                        if [ -n "$driver" ]; then
                            echo "│ Driver: $driver"
                        fi
                    fi
                fi
            fi
        fi
        
        echo "└─────────────────────────────────────────"
        echo ""
    fi
done

# Alternative method using udevadm directly on render devices
echo ""
echo "=== Additional Device Information ==="
echo ""

for device in /dev/dri/renderD*; do
    if [ -e "$device" ]; then
        device_name=$(basename "$device")
        echo "Device: $device_name"
        
        # Get udev properties
        udevadm info --query=property --name="$device" 2>/dev/null | grep -E "ID_PATH_TAG|ID_MODEL_ID|ID_VENDOR_ID|ID_PCI_CLASS" | while read -r line; do
            echo "  $line"
        done
        echo ""
    fi
done

# Check if no render devices found
if ! ls /dev/dri/renderD* 1> /dev/null 2>&1; then
    echo "No render devices found in /dev/dri/"
fi