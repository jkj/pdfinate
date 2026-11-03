# PDFinate

**PDFinate** builds [PDFium](https://pdfium.googlesource.com/pdfium/), the PDF rendering
and manipulation library used by Google Chrome, from source with **CMake**. By default it
produces a single **static library** that is easy to embed in other projects.

Upstream PDFium is built with Chromium's tooling: `depot_tools`, `gclient`, GN, Ninja, and
a long list of dependencies pulled in through its `DEPS` file. That works well inside
Chromium but is hard to fit into anyone else's build. PDFinate does not fork the PDFium
source. It includes upstream PDFium **unmodified as a git submodule** and adds a plain
CMake build around it.

> **Status:** builds on macOS (Apple Silicon, clang). Renders of PDFium's own pixel tests match
> upstream's reference images, except those upstream lists as known failures and small font
> anti-aliasing differences. Linux and Windows have not been built yet.

## Goals

- **Static by default.** One self-contained static library containing PDFium and its
  bundled dependencies, like upstream's `pdf_is_complete_lib` GN option.
- **Upstream code left untouched.** PDFium and its dependencies are git submodules pinned
  to upstream commits. PDFinate never edits files inside them.
- **Plain CMake.** `cmake -B build && cmake --build build`, with no depot_tools, gclient,
  GN or Chromium toolchain required.
- **Easy to embed.** Works with `add_subdirectory`, `FetchContent` and `find_package`, and
  exposes a single `pdfinate::pdfium` target.
- **Shares dependencies with the embedding project.** Any dependency the embedding project
  already builds (zlib, libjpeg, OpenJPEG, lcms2, FreeType, HarfBuzz) can be handed to
  PDFinate by target name, so the final program holds one copy of each.
- **Same API as PDFium.** The `public/fpdf*.h` headers come straight from upstream, so
  existing PDFium code, examples and documentation still apply.
- **Easy to update.** What to compile comes from PDFium's own `BUILD.gn` files, translated
  by a script, so a new PDFium release means bumping submodules and rerunning it.

## Repository layout

```text
pdfinate/
├── CMakeLists.txt            The build
├── cmake/
│   ├── generated/            pdfium_gn.cmake: PDFium's BUILD.gn files as CMake data
│   ├── gn.cmake              Turns that data into targets
│   ├── deps.cmake            Where each dependency comes from
│   ├── deps/                 Recipes for bundled dependencies that BUILD.gn does not describe
│   └── platform.cmake        Platform variables the generated data depends on
├── tools/gn2cmake.py         Regenerates cmake/generated/pdfium_gn.cmake
├── samples/                  pdfinate_info, a small test program
├── pdfium/                   PDFium, unmodified (git submodule)
└── deps/                     Dependencies PDFium normally fetches with gclient, as git
    ├── build/                submodules at the same relative paths and revisions that
    └── third_party/          pdfium/DEPS specifies
        ├── abseil-cpp/
        ├── dragonbox/src/
        ├── fast_float/src/
        ├── freetype/src/
        ├── harfbuzz/src/
        ├── highway/src/
        ├── icu/
        ├── libjpeg_turbo/
        ├── libyuv/
        └── zlib/
```

PDFium includes headers by path from its repository root, for example
`#include "build/build_config.h"` or `#include "third_party/abseil-cpp/absl/..."`. Under
`gclient` those dependencies are checked out inside the PDFium tree. PDFinate keeps them
out of the `pdfium/` submodule. `deps/` mirrors the same paths, and both `pdfium/` and
`deps/` go on the include path, so PDFium compiles without modification.

## Getting the source

```sh
git clone --recursive https://github.com/<you>/pdfinate.git
```

If you already cloned without `--recursive`:

```sh
git submodule update --init --recursive
```

The dependency submodules are marked `shallow`, so only the pinned commit of each is
downloaded.

## Building

Requirements: CMake 3.21 or newer and a C++20 compiler. Upstream PDFium officially
supports only Clang. GCC works on a best-effort basis. MSVC is not supported upstream, so
use `clang-cl` on Windows.

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
cmake --install build --prefix /path/to/install
```

On macOS with llvm.org's clang (rather than Apple's), also pass
`-DCMAKE_OSX_SYSROOT=$(xcrun --show-sdk-path)`. Build one architecture at a time.

The install holds `lib/libpdfium.a`, the public headers under `include/pdfium`, PDFium's
licence, and a CMake package for `find_package(pdfinate)`.

### Options

| Option                      | Default         | Description                                                    |
| --------------------------- | --------------- | -------------------------------------------------------------- |
| `PDFINATE_USE_SYSTEM_<DEP>` | `OFF`           | Use an installed copy of `<DEP>` instead of the bundled one    |
| `PDFINATE_<DEP>_TARGET`     | empty           | Use this existing target as `<DEP>` instead of the bundled one |
| `PDFINATE_USE_LIBYUV`       | `ON`            | Use libyuv for SIMD pixel-format conversions                   |
| `PDFINATE_JPEG_SIMD`        | `ON`            | Build the bundled libjpeg-turbo's SIMD code (x86 needs `nasm`) |
| `PDFINATE_BUILD_SAMPLES`    | `ON` at top level | Build `samples/pdfinate_info`                                |
| `PDFINATE_INSTALL`          | `ON`            | Install the library and headers                                |
| `BUILD_SHARED_LIBS`         | `OFF`           | Build a shared library instead (not tested yet)                |

`<DEP>` is one of `ZLIB`, `JPEG`, `OPENJPEG`, `LCMS2`, `FREETYPE`, `HARFBUZZ`, `ABSEIL`,
`ICU`, `HIGHWAY`, `LIBYUV`, `FAST_FLOAT` or `DRAGONBOX`. A `PDFINATE_<DEP>_TARGET` may name
several targets, for example `"absl::cleanup;absl::flat_hash_set;absl::inlined_vector"`.

PDFium includes the last six by their path in Chromium's tree
(`"third_party/abseil-cpp/absl/..."`) rather than as the libraries install them
(`<absl/...>`). When one comes from outside, PDFinate writes a forwarding header at each
such path PDFium uses, as Chromium does for a system ICU. A supplied target must carry its
own include directory; libyuv's upstream CMake target does not, so add it
(`target_include_directories(yuv INTERFACE .../libyuv/include)`).

The bundled zlib, libjpeg-turbo, libyuv and highway carry SIMD code for x86 (SSE2 to
AVX-512) and Arm (NEON, and on 64-bit Arm SVE2 and, on Linux, SME), each chosen at run time
for the CPU it runs on. libjpeg-turbo's x86 code is NASM assembly: without `nasm` the build
warns and falls back to plain C.

XFA forms, JavaScript (V8) and Skia rendering are not supported.

## Using PDFinate in your project

### With FetchContent or add_subdirectory

```cmake
include(FetchContent)
FetchContent_Declare(pdfinate
  GIT_REPOSITORY https://github.com/<you>/pdfinate.git
  GIT_TAG        main)   # FetchContent initializes submodules recursively by default
FetchContent_MakeAvailable(pdfinate)

target_link_libraries(myapp PRIVATE pdfinate::pdfium)
```

You can also add PDFinate as a submodule of your own project and use
`add_subdirectory(third_party/pdfinate)`.

### Sharing dependencies your project already builds

If your project builds its own copy of a library PDFium uses, name your target before
adding PDFinate. PDFinate then links your copy and leaves its own out of `libpdfium.a`.
Any or all of the twelve can come from your project:

```cmake
set(PDFINATE_ZLIB_TARGET     zlibstatic)
set(PDFINATE_OPENJPEG_TARGET openjp2)
set(PDFINATE_FREETYPE_TARGET freetype)
add_subdirectory(third_party/pdfinate)
```

In a static program this matters: two copies of the same C library are duplicate symbols
at link time, or two versions silently mixed. The bundled copies of zlib and libjpeg-turbo
rename their symbols (`Cr_z_*`, `chromium_jpeg_*`), so they cannot collide, but they are
still a second copy.

### As an installed package

```cmake
find_package(pdfinate REQUIRED)
target_link_libraries(myapp PRIVATE pdfinate::pdfium)
```

The package is installed only when no dependency was supplied by target. Such a target
belongs to the embedding project, which installs it in its own way.

### Minimal example

```c
#include <fpdfview.h>
#include <stdio.h>

int main(int argc, char** argv) {
  if (argc < 2) return 1;

  FPDF_InitLibrary();
  FPDF_DOCUMENT doc = FPDF_LoadDocument(argv[1], NULL);
  if (doc) {
    printf("%d pages\n", FPDF_GetPageCount(doc));
    FPDF_CloseDocument(doc);
  }
  FPDF_DestroyLibrary();
  return 0;
}
```

`samples/pdfinate_info.c` extends this to render the first page into a PPM file.

The full API is documented in the headers under
[`pdfium/public/`](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/) and in
the [upstream PDFium docs](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/docs/).

## How the build works

`tools/gn2cmake.py` reads PDFium's `BUILD.gn` files, starting from the `//:pdfium` target,
and writes `cmake/generated/pdfium_gn.cmake`. That file records every GN target and config
the library can reach, with its sources, dependencies, defines and include directories.
Conditions that depend on the platform or on a PDFinate option become CMake `if()` blocks.
Settings PDFinate fixes, such as no XFA, no V8, no Skia and no Rust, are resolved by the
script.

At configure time, `cmake/gn.cmake` walks that graph and makes one CMake object library per
GN target. Labels outside the PDFium tree (abseil, ICU, zlib, libjpeg-turbo, libyuv) come
from recipes in `cmake/deps/`, or from the embedding project. The `pdfium` library is assembled
from all the objects.

The generated file records a checksum of each `BUILD.gn` it was made from. If any of them
changes, configure stops and asks for the script to be run again, so the CMake build cannot
silently fall behind PDFium.

## Relationship to upstream

The `pdfium/` submodule points directly at <https://pdfium.googlesource.com/pdfium> and
tracks a numbered `chromium/NNNN` branch, currently `chromium/8140`. Each `deps/`
submodule is pinned to the revision listed in `pdfium/DEPS`.

To move to a newer PDFium:

1. Check out the new commit or branch in `pdfium/`.
2. Update each `deps/` submodule to the revision in the new `pdfium/DEPS`. (A script to
   automate this is planned.)
3. Run `python3 tools/gn2cmake.py` and review the diff of
   `cmake/generated/pdfium_gn.cmake`.
4. If a dependency's own source list changed, update its recipe in `cmake/deps/`.

PDFinate never edits files inside the submodules. If upstream code really can't be built
as is, the preferred fix is a change sent upstream. Failing that, the CMake build can
substitute a replacement file kept in this repository. Either way the submodules stay
clean.

Problems with the CMake build or packaging belong in this repository. Bugs in PDFium
itself are best reported to the upstream project.

PDFinate is an independent project and is not affiliated with or endorsed by Google.

## Alternatives

- [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) publishes
  prebuilt PDFium shared libraries for many platforms every week, built with Google's
  tooling. If you don't need a static library or a CMake source build, use it instead.
- [madebr/pdfium-cmake](https://github.com/madebr/pdfium-cmake) is an earlier CMake build
  of PDFium that relies on system or Conan dependencies. It was last updated in 2023. The
  Conan Center `pdfium` package uses it and is still on PDFium `chromium/4629` (2021).

## License

PDFinate's own build files are released under the BSD 3-Clause license, the same license
PDFium uses (see [`LICENSE`](LICENSE)). PDFium is licensed under BSD 3-Clause and
Apache 2.0 (see `pdfium/LICENSE`). Each dependency under `deps/` keeps its own license.
