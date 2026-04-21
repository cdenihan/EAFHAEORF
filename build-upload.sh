#!/bin/sh
set -e

ROBOT_IP="192.168.124.1"

# Build using only workspace-local cache/output folders
zig build \
    --cache-dir .zig-cache \
    --global-cache-dir .zig-cache \
    --prefix zig-out

# Clean up legacy/extra folders Zig may have created in previous runs
rm -rf zig-cache zig-pkg .wombat-sdk-cache

LOCAL_FILE="zig-out/bin/botball_user_program"
REMOTE_FILE="/home/kipr/Documents/KISS/Default User/EAFHAEORF/bin/botball_user_program"

# Compute hashes
LOCAL_HASH=$(sha256sum "$LOCAL_FILE" | awk '{print $1}')
REMOTE_HASH=$(ssh kipr@"$ROBOT_IP" "sha256sum '$REMOTE_FILE' 2>/dev/null | awk '{print \$1}'")

if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
    echo "Binary unchanged, skipping upload."
else
    echo "Binary changed, uploading..."
    scp "$LOCAL_FILE" kipr@"$ROBOT_IP":/home/kipr/botball_user_program
    ssh kipr@"$ROBOT_IP" "sudo mv '/home/kipr/botball_user_program' '$REMOTE_FILE'"
    ssh kipr@"$ROBOT_IP" "sudo chmod +x '$REMOTE_FILE'"
    echo "Upload complete."
fi