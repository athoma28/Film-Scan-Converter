# How to add to ART

> **Legacy integration:** ART integration launches the maintenance-only Python
> application. It is retained for compatibility and is not a target for new
> features. See [Legacy Python Application](legacy-python.md).

1. Follow the steps in `installation.md` section `Manual Installation in Python venv`
2. Copy all files in `ART-Commands` to the `usercommands` directory described in [ART User Commands](https://artraweditor.github.io/Usercommands).
3. Open `film_scan_converter_directory.sh` and `film_scan_converter_files.sh` for editing
4. Replace `{path to your Film Scan Converter VENV  python executable}` with the path to your VENV python binary e.g. `/home/user/dev/Film-Scan-Converter/source/venv/bin/python`
5. Replace `{path to Film Scan Converter root dir}` with the path to Film Scan Converter, e.g. `/home/user/dev/Film-Scan-Converter`
6. Launch ART, you should now have additional options for selecting folders and files for conversion

## Video Intructions
A video on how to install and use Film Scan Converter in ART is available [here](https://www.youtube.com/watch?v=8uGc7bAjnsI)
