#!/bin/bash
#
# Launch modded Motion with MotionKit injected.
#

set -euo pipefail

PRODUCT_NAME="${PRODUCT_NAME:-MotionKit}"
HOST_APP_NAME="${HOST_APP_NAME:-Motion}"
HOST_EXECUTABLE="${HOST_EXECUTABLE:-Motion}"
MOTIONKIT_PORT="${MOTIONKIT_PORT:-9878}"
MOTIONKIT_AUTOCREATE_DOCUMENT="${MOTIONKIT_AUTOCREATE_DOCUMENT:-0}"
MOTIONKIT_LAUNCH_MODE="${MOTIONKIT_LAUNCH_MODE:-open}"

MODDED_APP_ROOT="${MODDED_APP_ROOT:-$HOME/Applications/$PRODUCT_NAME}"
MODDED_APP="${MODDED_APP:-$MODDED_APP_ROOT/$HOST_APP_NAME.app}"
DYLIB="${DYLIB:-$MODDED_APP/Contents/Frameworks/$PRODUCT_NAME.framework/Versions/A/$PRODUCT_NAME}"

if [ ! -d "$MODDED_APP" ]; then
    echo "ERROR: Modded app not found at: $MODDED_APP"
    echo "Run 'make copy-app' and 'make deploy' first."
    exit 1
fi

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: MotionKit dylib not found at: $DYLIB"
    echo "Run 'make deploy' first."
    exit 1
fi

echo "=== Launching $HOST_APP_NAME with $PRODUCT_NAME ==="
echo "  App: $MODDED_APP"
echo "  Dylib: $DYLIB"
echo "  Bridge port: $MOTIONKIT_PORT"
echo ""

export MOTIONKIT_PORT
export MOTIONKIT_AUTOCREATE_DOCUMENT
export DYLD_INSERT_LIBRARIES="$DYLIB"

if [ "$MOTIONKIT_LAUNCH_MODE" = "exec" ]; then
    exec "$MODDED_APP/Contents/MacOS/$HOST_EXECUTABLE"
fi

exec open -na "$MODDED_APP"
