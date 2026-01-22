#!/bin/bash

# Check for Sonarr path OR Radarr path
# Sonarr uses: sonarr_episodefile_path
# Radarr uses: radarr_moviefile_path
file_path="${sonarr_episodefile_path:-$radarr_moviefile_path}"

if [ -f "$file_path" ]; then
    touch "$file_path"
    echo "Timestamped: $file_path - $(date)" >> /tmp/media-timestamps.log
fi