#!/bin/bash

# Python interpreter to use
PYTHON={path to your Film Scan Converter VENV python executable}

# directory where Film-Scan-Converter is located
FSC_DIR={path to Film Scan Converter root dir}

f=""

for file in "$@"; do
	if [[ -z "$f" ]]; then
		f=${file}
	else
		f="${f}, ${file}"
	fi
done

d="$(dirname "$1")/converted"

"${PYTHON}" "${FSC_DIR}/source/Film Scan Converter.pyw" "-f" "$f" "-o" "$d" &
