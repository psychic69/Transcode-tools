#!/bin/bash
# Path to save the recovery script on the flash drive
SAVE_PATH="/boot/config/docker_network_restore.sh"

echo "#!/bin/bash" > $SAVE_PATH
echo "# Auto-generated Recovery Script" >> $SAVE_PATH

# Get IDs of custom networks (excluding default bridge, host, none)
NETWORKS=$(docker network ls --filter "type=custom" --format "{{.Name}}")

for NET in $NETWORKS; do
    # Extract Driver
    DRIVER=$(docker network inspect $NET -f '{{.Driver}}')
    
    # Extract Subnet and Gateway (handling potential empty values)
    SUBNET=$(docker network inspect $NET -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
    GATEWAY=$(docker network inspect $NET -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
    PARENT=$(docker network inspect $NET -f '{{index .Options "parent"}}')

    # Construct the command
    CMD="docker network create -d $DRIVER"
    [ ! -z "$SUBNET" ] && CMD="$CMD --subnet=$SUBNET"
    [ ! -z "$GATEWAY" ] && CMD="$CMD --gateway=$GATEWAY"
    [ ! -z "$PARENT" ] && [ "$PARENT" != "<no value>" ] && CMD="$CMD -o parent=$PARENT"
    CMD="$CMD $NET"

    # Save to file with a check so it doesn't error if network exists
    echo "if [ ! \"\$(docker network ls | grep $NET)\" ]; then $CMD; fi" >> $SAVE_PATH
done

chmod +x $SAVE_PATH
echo "Network state saved to $SAVE_PATH"