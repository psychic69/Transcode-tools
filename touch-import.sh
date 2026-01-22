#!/bin/bash

# Sonarr uses environment variables instead of arguments
# sonarr_episodefile_path is the standard variable for imports
episode_file="$sonarr_episodefile_path"

if [ -f "$episode_file" ]; then
    touch "$episode_file"
    echo "Timestamped: $episode_file - $(date)" >> /tmp/sonarr-timestamps.log
else
    echo "File not found or script triggered by non-import event: $sonarr_eventtype - $(date)" >> /tmp/sonarr-timestamps.log
fi