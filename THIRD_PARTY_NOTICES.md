# Third-Party Notices

Film Scan Converter is distributed under the GNU General Public License,
version 3. The complete project license is provided in `LICENSE` and the
corresponding source for each release is available from the release's Git tag:

<https://github.com/athoma28/Film-Scan-Converter>

The macOS application bundle contains dynamically linked copies of libraries
installed by Homebrew when the release artifact is built. The exact library
versions and install names are recorded by the release packager in
`BUNDLED-LIBRARIES.txt`. Complete license and copyright texts for the bundled
versions are included in `ThirdPartyLicenses/` at archive root and inside the
application bundle.

## RawTherapee RCD demosaic

`native/FilmScanEngine/Sources/CLibRawShim/RawTherapeePipeline.cpp` contains an
adaptation of RawTherapee's `rcd_demosaic.cc`, by Luis Sanz Rodriguez and Ingo
Weyrich. RawTherapee is licensed under GPLv3.

- Project: <https://github.com/Beep6581/RawTherapee>
- License: <https://github.com/Beep6581/RawTherapee/blob/dev/LICENSE>

## LibRaw

LibRaw provides camera-RAW decoding. The distributed build uses LibRaw under
the GNU Lesser General Public License 2.1 option offered by the project.

- Project: <https://www.libraw.org/>
- Source: <https://github.com/LibRaw/LibRaw>
- License: LGPL-2.1-only OR CDDL-1.0

## LLVM OpenMP runtime

The OpenMP runtime is used by the Homebrew LibRaw dependency closure.

- Project: <https://openmp.llvm.org/>
- Source: <https://github.com/llvm/llvm-project/tree/main/openmp>
- License: Apache-2.0 WITH LLVM-exception; legacy runtime portions also carry
  the University of Illinois/NCSA and MIT terms described by LLVM

## libjpeg-turbo

libjpeg-turbo provides JPEG support used by LibRaw.

- Project: <https://www.libjpeg-turbo.org/>
- Source: <https://github.com/libjpeg-turbo/libjpeg-turbo>
- License: IJG AND Zlib AND BSD-3-Clause

## JasPer

JasPer provides JPEG-2000 support used by LibRaw.

- Project: <https://jasper-software.github.io/jasper-manual/>
- Source: <https://github.com/jasper-software/jasper>
- License: JasPer-2.0

## Little CMS

Little CMS provides color-management support used by LibRaw.

- Project: <https://www.littlecms.com/>
- Source: <https://github.com/mm2/Little-CMS>
- License: MIT

The upstream source links above provide the complete corresponding source and
license texts for the unmodified shared libraries. Film Scan Converter does
not claim endorsement by any upstream project.
