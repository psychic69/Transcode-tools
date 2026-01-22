#!/bin/bash

episode_file="$1"

if [ -f "$episode_file" ]; then
    touch "$episode_file"
    echo "Timestamped: $episode_file - $(date)" >> /tmp/sonarr-timestamps.log
fi