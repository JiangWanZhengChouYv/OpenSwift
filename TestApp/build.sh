#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building TestApp..."

gcc -o testapp testapp.c 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to compile testapp.c"
    exit 1
fi

# 签名
codesign --force --sign - testapp 2>&1
if [ $? -ne 0 ]; then
    echo "Warning: Failed to codesign testapp"
fi

echo "Build successful: testapp"
ls -lh testapp
