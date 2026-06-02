#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building SpeedPatch DYLIB..."

gcc -c -o speedpatch.o speedpatch.c -I. 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to compile speedpatch.c"
    exit 1
fi

gcc -c -o fishhook.o fishhook.c -I. 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to compile fishhook.c"
    rm -f speedpatch.o
    exit 1
fi

gcc -dynamiclib -o libSpeedPatch.dylib speedpatch.o fishhook.o -framework CoreFoundation 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to link SpeedPatch DYLIB"
    rm -f speedpatch.o fishhook.o
    exit 1
fi

rm -f speedpatch.o fishhook.o

echo "Build successful: libSpeedPatch.dylib"
ls -lh libSpeedPatch.dylib
