#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIR/hdr_white"
SOURCE="$DIR/hdr_white.swift"

if [ ! -f "$BINARY" ]; then
    echo "Compiling HDR White tool..."
    swiftc -o "$BINARY" "$SOURCE" -framework AppKit -framework Metal -framework MetalKit
    if [ $? -ne 0 ]; then
        echo "Compilation failed."
        read -p "Press Enter to close..."
        exit 1
    fi
fi

exec "$BINARY"
