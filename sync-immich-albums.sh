#!/usr/bin/env bash

set -e

# Default values
IMMICH_URL="${IMMICH_URL:-http://localhost:2283}"
ALBUMS=""
ROOT_DIR=""

# Check for required dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq to use this script."
    exit 1
fi

# Usage function
usage() {
    cat << EOF
Usage: $0 --albums <album_ids> --root <root_directory> [options]

Required:
  --albums      Comma-separated list of album IDs
  --root        Root directory where album folders will be created

Optional:
  --url         Immich server URL (default: http://localhost:2283)
                Can also be set via IMMICH_URL environment variable

Environment Variables:
  IMMICH_API_KEY    API key for Immich server (required)
  IMMICH_URL        Immich server URL (optional, defaults to http://localhost:2283)

Example:
  export IMMICH_API_KEY="your-api-key"
  $0 --albums "album-id-1,album-id-2" --root /path/to/albums

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --albums)
            ALBUMS="$2"
            shift 2
            ;;
        --root)
            ROOT_DIR="$2"
            shift 2
            ;;
        --url)
            IMMICH_URL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$IMMICH_API_KEY" ]]; then
    echo "Error: IMMICH_API_KEY environment variable is not set"
    exit 1
fi

if [[ -z "$ALBUMS" ]]; then
    echo "Error: --albums parameter is required"
    usage
fi

if [[ -z "$ROOT_DIR" ]]; then
    echo "Error: --root parameter is required"
    usage
fi

# Create root directory if it doesn't exist
mkdir -p "$ROOT_DIR"

# Function to query album details
get_album() {
    local album_id="$1"
    curl -s -X GET \
        "${IMMICH_URL}/api/albums/${album_id}" \
        -H "x-api-key: ${IMMICH_API_KEY}" \
        -H "Accept: application/json"
}

# Function to sanitize album name for directory
sanitize_name() {
    local name="$1"
    # Replace invalid characters with underscores
    echo "$name" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

# Function to process a single album
process_album() {
    local album_id="$1"
    
    echo "Processing album: $album_id"
    
    # Get album data
    local album_data
    album_data=$(get_album "$album_id")
    
    # Check if album exists (check for error message)
    if echo "$album_data" | jq -e '.message' &> /dev/null; then
        echo "Error: Failed to fetch album $album_id"
        echo "$album_data" | jq -r '.message'
        return 1
    fi
    
    # Extract album name using jq
    local album_name
    album_name=$(echo "$album_data" | jq -r '.albumName')
    
    if [[ -z "$album_name" ]] || [[ "$album_name" == "null" ]]; then
        echo "Error: Could not extract album name for $album_id"
        return 1
    fi
    
    echo "  Album name: $album_name"
    
    # Sanitize album name for directory
    local dir_name
    dir_name=$(sanitize_name "$album_name")
    local album_dir="${ROOT_DIR}/${dir_name}"
    
    # Create album directory
    mkdir -p "$album_dir"
    
    # Extract asset original paths using jq
    local asset_count
    asset_count=$(echo "$album_data" | jq -r '.assets | length')
    
    if [[ "$asset_count" -eq 0 ]]; then
        echo "  No assets found in album"
    else
        echo "  Found $asset_count assets"
    fi
    
    # Create a temporary file to track current album assets
    local current_assets_file
    current_assets_file=$(mktemp)
    
    # Create symlinks for each asset
    echo "$album_data" | jq -r '.assets[]? | "\(.id)|\(.originalPath)"' | while IFS='|' read -r asset_id original_path; do
        if [[ -z "$original_path" ]] || [[ "$original_path" == "null" ]]; then
            continue
        fi
        
        # Check if original file exists
        if [[ ! -f "$original_path" ]]; then
            echo "  Warning: Original file not found: $original_path"
            continue
        fi
        
        # Extract extension from original path
        local filename
        filename=$(basename "$original_path")
        local extension="${filename##*.}"
        
        # If there's no extension (filename == extension), leave it empty
        if [[ "$filename" == "$extension" ]]; then
            extension=""
        fi
        
        # Create symlink path using asset ID and extension
        local symlink_path
        if [[ -n "$extension" ]]; then
            symlink_path="${album_dir}/${asset_id}.${extension}"
        else
            symlink_path="${album_dir}/${asset_id}"
        fi
        
        # Create or update symlink
        if [[ ! -L "$symlink_path" ]]; then
            ln -s "$original_path" "$symlink_path"
            echo "  Created: $symlink_path -> $original_path"
        elif [[ "$(readlink -f "$symlink_path" 2>/dev/null)" != "$original_path" ]]; then
            # Update symlink if it points to a different location
            rm "$symlink_path"
            ln -s "$original_path" "$symlink_path"
            echo "  Updated: $symlink_path -> $original_path"
        fi
        
        # Track this asset
        echo "$symlink_path" >> "$current_assets_file"
    done
    
    # Remove stale symlinks
    echo "  Checking for stale symlinks..."
    local removed_count=0
    
    while IFS= read -r symlink; do
        # Skip if not a symlink
        if [[ ! -L "$symlink" ]]; then
            continue
        fi
        
        # Check if this symlink is in our current assets list
        if ! grep -Fxq "$symlink" "$current_assets_file"; then
            echo "  Removing stale symlink: $symlink"
            rm "$symlink"
            removed_count=$((removed_count + 1))
        fi
    done < <(find "$album_dir" -type l)
    
    if [[ $removed_count -gt 0 ]]; then
        echo "  Removed $removed_count stale symlink(s)"
    fi
    
    # Clean up temp file
    rm "$current_assets_file"
    
    echo "  Completed album: $album_name"
}

# Main processing loop
echo "Starting Immich album sync..."
echo "Server: $IMMICH_URL"
echo "Root directory: $ROOT_DIR"
echo ""

IFS=',' read -ra ALBUM_ARRAY <<< "$ALBUMS"

for album_id in "${ALBUM_ARRAY[@]}"; do
    # Trim whitespace
    album_id=$(echo "$album_id" | xargs)
    
    if [[ -n "$album_id" ]]; then
        process_album "$album_id"
        echo ""
    fi
done

echo "Sync completed successfully!"
