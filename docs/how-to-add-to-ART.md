# How to add to ART

> **Legacy integration:** ART integration launches the maintenance-only Python
> application. It is retained for compatibility and is not a target for new
> features. See [Legacy Python Application](legacy-python.md).

1. Follow the [legacy Python installation](installation.md#legacy-python) steps.
2. Copy all files in `ART-Commands` to the `usercommands` directory described in [ART User Commands](https://artraweditor.github.io/Usercommands).
3. Open `film_scan_converter_directory.sh` and `film_scan_converter_files.sh` for editing.
4. In **both** scripts, replace the whole `PYTHON=` placeholder line with a
   quoted absolute path, for example `PYTHON="/home/user/dev/Film-Scan-Converter/.venv/bin/python"`.
   The original placeholders have different spacing between the two scripts.
5. In **both** scripts, replace the whole `FSC_DIR=` placeholder line with a
   quoted repository root, for example `FSC_DIR="/home/user/dev/Film-Scan-Converter"`.
6. Make both scripts executable in `usercommands`:
   `chmod +x film_scan_converter_directory.sh film_scan_converter_files.sh`.
7. Launch ART to use the directory and selected-file conversion commands.

## Video Instructions
A video on how to install and use Film Scan Converter in ART is available [here](https://www.youtube.com/watch?v=8uGc7bAjnsI)
