#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/source" || exit

VENV_DIR="$DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    echo "Installing dependencies..."
    pip install -r requirements.txt
else
    source "$VENV_DIR/bin/activate"
fi

python3 "Film Scan Converter.pyw"
