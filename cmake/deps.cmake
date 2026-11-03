# ===========================================================================
# Where each of PDFium's dependencies comes from.
#
# Every dependency PDFium can take from outside has two settings:
#
#   PDFINATE_<DEP>_TARGET       the target (or list of targets) the embedding project already has for
#                               it. PDFinate links that instead of building its own copy. This is how
#                               a parent project that builds the same library shares one copy with
#                               PDFium, which a static link needs: two copies of zlib in one
#                               executable are duplicate symbols, or worse, two versions silently mixed.
#   PDFINATE_USE_SYSTEM_<DEP>   find an installed copy with find_package (or pkg-config) instead.
#
# With neither, the bundled copy under deps/ is built and folded into the pdfium library, and fetched
# first if it is not checked out (the Bundled section below).
#
#   <DEP>       upstream's name for the switch   what PDFium uses it for
#   ZLIB        use_system_zlib                  Flate streams
#   JPEG        use_system_libjpeg               DCT (JPEG) images
#   OPENJPEG    use_system_libopenjpeg2          JPX (JPEG 2000) images
#   LCMS2       use_system_lcms2                 ICC colour management
#   FREETYPE    use_system_freetype              font rendering
#   HARFBUZZ    use_system_harfbuzz              font subsetting when saving
#   ABSEIL      (none)                           a hash set, a small vector, scope guards
#   ICU         (none)                           character properties and the bidi algorithm
#   HIGHWAY     (none)                           SIMD image scaling and compositing
#   LIBYUV      (none)                           SIMD pixel-format conversions (PDFINATE_USE_LIBYUV)
#   FAST_FLOAT  (none)                           number parsing
#   DRAGONBOX   (none)                           number formatting
#   BROTLI      (none)                           the experimental BrotliDecode stream filter
#                                                (PDFINATE_ENABLE_BROTLI; never bundled)
#
# Upstream has no system switch for the last seven: PDFium includes their headers by their path in
# Chromium's tree ("third_party/abseil-cpp/absl/..."), not as the libraries install them. So when one
# comes from outside, PDFinate writes a forwarding header at each such path PDFium uses — the list is
# in the generated data — which includes the header as the library installs it (<absl/...>). It is the
# arrangement Chromium itself uses for a system ICU (its shim_headers).
#
# An outside copy need not be the revision pdfium/DEPS pins, but PDFium is only tested with that one.
# ===========================================================================

set(_pdfinate_deps ZLIB JPEG OPENJPEG LCMS2 FREETYPE HARFBUZZ ABSEIL ICU HIGHWAY LIBYUV FAST_FLOAT DRAGONBOX
                   BROTLI)
foreach(dep IN LISTS _pdfinate_deps)
    option(PDFINATE_USE_SYSTEM_${dep} "Use an installed ${dep} instead of the bundled copy" OFF)
    set(PDFINATE_${dep}_TARGET "" CACHE STRING
        "Targets of the embedding project to use as ${dep}, instead of the bundled copy")
    set(_pdfinate_${dep} "")
    if(PDFINATE_${dep}_TARGET)
        foreach(_target IN LISTS PDFINATE_${dep}_TARGET)
            if(NOT TARGET "${_target}")
                message(FATAL_ERROR "PDFinate: PDFINATE_${dep}_TARGET names ${_target}, "
                                    "which is not a target here.")
            endif()
        endforeach()
        set(PDFINATE_USE_SYSTEM_${dep} ON)
        list(LENGTH PDFINATE_${dep}_TARGET _count)
        if(_count EQUAL 1)
            set(_pdfinate_${dep} "${PDFINATE_${dep}_TARGET}")
        else()
            add_library(pdfinate_supplied_${dep} INTERFACE)
            target_link_libraries(pdfinate_supplied_${dep} INTERFACE ${PDFINATE_${dep}_TARGET})
            set(_pdfinate_${dep} pdfinate_supplied_${dep})
        endif()
    endif()
endforeach()
unset(_target)
unset(_count)

# --- Supplied from outside -------------------------------------------------------------------

if(PDFINATE_USE_SYSTEM_ZLIB)
    if(NOT _pdfinate_ZLIB)
        find_package(ZLIB REQUIRED)
        set(_pdfinate_ZLIB ZLIB::ZLIB)
    endif()
    pdfinate_gn_replace_libs("//third_party:system_zlib_config" "${_pdfinate_ZLIB}")
endif()

if(PDFINATE_USE_SYSTEM_JPEG)
    if(NOT _pdfinate_JPEG)
        find_package(JPEG REQUIRED)
        set(_pdfinate_JPEG JPEG::JPEG)
    endif()
    pdfinate_gn_replace_libs("//third_party:system_libjpeg_config" "${_pdfinate_JPEG}")
    # core/fxcodec asks for libjpeg-turbo's headers by name even when the library is a system one;
    # the headers that go with the supplied library are the right ones.
    pdfinate_gn_provide("//third_party/libjpeg_turbo:libjpeg_headers" "${_pdfinate_JPEG}")
endif()

if(PDFINATE_USE_SYSTEM_OPENJPEG)
    if(NOT _pdfinate_OPENJPEG)
        find_package(OpenJPEG REQUIRED CONFIG)
        set(_pdfinate_OPENJPEG openjp2)
    endif()
    pdfinate_gn_replace_libs("//third_party:libopenjpeg2_from_pkgconfig" "${_pdfinate_OPENJPEG}")
endif()

if(PDFINATE_USE_SYSTEM_LCMS2 AND NOT _pdfinate_LCMS2)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PDFINATE_LCMS2 REQUIRED IMPORTED_TARGET lcms2)
    set(_pdfinate_LCMS2 PkgConfig::PDFINATE_LCMS2)
endif()
if(PDFINATE_USE_SYSTEM_LCMS2)
    pdfinate_gn_replace_libs("//third_party:lcms2_from_pkgconfig" "${_pdfinate_LCMS2}")
endif()

if(PDFINATE_USE_SYSTEM_FREETYPE)
    if(NOT _pdfinate_FREETYPE)
        find_package(Freetype REQUIRED)
        set(_pdfinate_FREETYPE Freetype::Freetype)
    endif()
    pdfinate_gn_provide("//build/config/freetype:freetype" "${_pdfinate_FREETYPE}")
endif()

if(PDFINATE_USE_SYSTEM_HARFBUZZ AND NOT _pdfinate_HARFBUZZ)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PDFINATE_HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz harfbuzz-subset)
    set(_pdfinate_HARFBUZZ PkgConfig::PDFINATE_HARFBUZZ)
endif()
if(PDFINATE_USE_SYSTEM_HARFBUZZ)
    pdfinate_gn_replace_libs("//third_party/harfbuzz:harfbuzz_from_pkgconfig" "${_pdfinate_HARFBUZZ}")
endif()

# The six whose headers PDFium names by their Chromium path. Each finds its library's own CMake package
# when asked for the system copy; libyuv publishes none, so it can only come from a target.
if(PDFINATE_USE_SYSTEM_ABSEIL AND NOT _pdfinate_ABSEIL)
    find_package(absl REQUIRED)
    add_library(pdfinate_supplied_ABSEIL INTERFACE)
    target_link_libraries(pdfinate_supplied_ABSEIL INTERFACE absl::cleanup absl::flat_hash_set absl::inlined_vector)
    set(_pdfinate_ABSEIL pdfinate_supplied_ABSEIL)
endif()
if(PDFINATE_USE_SYSTEM_ICU AND NOT _pdfinate_ICU)
    find_package(ICU REQUIRED COMPONENTS uc)
    set(_pdfinate_ICU ICU::uc)
endif()
if(PDFINATE_USE_SYSTEM_HIGHWAY AND NOT _pdfinate_HIGHWAY)
    find_package(hwy REQUIRED)
    set(_pdfinate_HIGHWAY hwy::hwy)
endif()
if(PDFINATE_USE_SYSTEM_FAST_FLOAT AND NOT _pdfinate_FAST_FLOAT)
    find_package(FastFloat REQUIRED)
    set(_pdfinate_FAST_FLOAT FastFloat::fast_float)
endif()
if(PDFINATE_USE_SYSTEM_DRAGONBOX AND NOT _pdfinate_DRAGONBOX)
    find_package(dragonbox REQUIRED)
    set(_pdfinate_DRAGONBOX dragonbox::dragonbox)
endif()
# Brotli: upstream's experimental BrotliDecode filter (pdf_enable_brotli), off unless asked for. PDFinate
# does not bundle Brotli, so it needs a target or an installed copy.
option(PDFINATE_ENABLE_BROTLI "Decode the experimental BrotliDecode stream filter (needs Brotli)" OFF)
if(PDFINATE_ENABLE_BROTLI AND PDFINATE_USE_SYSTEM_BROTLI AND NOT _pdfinate_BROTLI)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PDFINATE_BROTLI REQUIRED IMPORTED_TARGET libbrotlidec)
    set(_pdfinate_BROTLI PkgConfig::PDFINATE_BROTLI)
endif()
if(PDFINATE_ENABLE_BROTLI AND NOT PDFINATE_USE_SYSTEM_BROTLI)
    message(FATAL_ERROR "PDFinate: PDFINATE_ENABLE_BROTLI needs Brotli from outside: name its decoder in "
                        "PDFINATE_BROTLI_TARGET, or set PDFINATE_USE_SYSTEM_BROTLI.")
endif()

if(PDFINATE_USE_SYSTEM_LIBYUV AND NOT _pdfinate_LIBYUV)
    message(FATAL_ERROR "PDFinate: libyuv installs no CMake package to find; name the embedding "
                        "project's libyuv target in PDFINATE_LIBYUV_TARGET instead.")
endif()

# libyuv is optional altogether (upstream's pdf_use_libyuv).
option(PDFINATE_USE_LIBYUV "Use libyuv for SIMD pixel-format conversions" ON)

# The labels each stands in for (comma-separated), and where in Chromium's tree PDFium looks for its
# headers.
set(_pdfinate_forwarded
    "ABSEIL|third_party/abseil-cpp/|//third_party/abseil-cpp:absl"
    "ICU|third_party/icu/source/common/|//third_party/icu:icuuc,//third_party/icu:icuuc_public"
    "HIGHWAY|third_party/highway/src/|//third_party/highway:libhwy"
    "LIBYUV|third_party/libyuv/include/|//third_party/libyuv:libyuv"
    "FAST_FLOAT|third_party/fast_float/src/include/|//third_party/fast_float:fast_float"
    "DRAGONBOX|third_party/dragonbox/src/include/|//third_party/dragonbox:dragonbox"
    "BROTLI|third_party/brotli/include/|//third_party/brotli:dec")
foreach(_entry IN LISTS _pdfinate_forwarded)
    string(REPLACE "|" ";" _entry "${_entry}")
    list(GET _entry 0 _dep)
    list(GET _entry 2 _labels)
    string(REPLACE "," ";" _labels "${_labels}")
    if(PDFINATE_USE_SYSTEM_${_dep})
        foreach(_label IN LISTS _labels)
            pdfinate_gn_provide("${_label}" "${_pdfinate_${_dep}}")
        endforeach()
    endif()
endforeach()
unset(_entry)
unset(_dep)
unset(_labels)
unset(_label)

# Called once the generated data is in: a forwarding header at each Chromium path PDFium includes from
# a dependency that comes from outside, in a directory searched before deps/, where the bundled copies
# would otherwise answer.
function(pdfinate_write_forwarding_headers)
    set(root "${PROJECT_BINARY_DIR}/pdfinate-forwarding")
    foreach(entry IN LISTS _pdfinate_forwarded)
        string(REPLACE "|" ";" entry "${entry}")
        list(GET entry 0 dep)
        list(GET entry 1 prefix)
        if(NOT PDFINATE_USE_SYSTEM_${dep})
            continue()
        endif()
        foreach(include IN LISTS PDFINATE_GN_DEPENDENCY_INCLUDES)
            string(FIND "${include}" "${prefix}" at)
            if(NOT at EQUAL 0)
                continue()
            endif()
            string(LENGTH "${prefix}" length)
            string(SUBSTRING "${include}" ${length} -1 installed)
            string(CONCAT content
                "// Written by PDFinate. PDFium names this header by its path in Chromium's tree, and\n"
                "// here ${dep} comes from outside, which installs it as <${installed}>.\n"
                "#include <${installed}>\n")
            # Written only when it differs, so a reconfigure does not rebuild everything including it.
            set(file "${root}/${include}")
            set(old "")
            if(EXISTS "${file}")
                file(READ "${file}" old)
            endif()
            if(NOT old STREQUAL content)
                file(WRITE "${file}" "${content}")
            endif()
        endforeach()
    endforeach()
    target_include_directories(pdfinate_compile_options BEFORE INTERFACE "${root}")
endfunction()

# --- Bundled ---------------------------------------------------------------------------------
# The bundled copies are submodules a recursive checkout leaves out (update = none in .gitmodules), so
# a project that supplies every one of them never downloads them. Each one this build compiles is
# fetched here if it is missing, with git, when PDFinate is a git checkout: a clone, a submodule and
# FetchContent's copy all are. Otherwise configure stops and names the command.
set(_pdfinate_bundled
    "ZLIB|third_party/zlib"
    "JPEG|third_party/libjpeg_turbo"
    "FREETYPE|third_party/freetype/src"
    "HARFBUZZ|third_party/harfbuzz/src"
    "ABSEIL|third_party/abseil-cpp"
    "ICU|third_party/icu"
    "HIGHWAY|third_party/highway/src"
    "LIBYUV|third_party/libyuv"
    "FAST_FLOAT|third_party/fast_float/src"
    "DRAGONBOX|third_party/dragonbox/src")
function(_pdfinate_missing_bundled out)
    set(missing "")
    foreach(entry IN LISTS _pdfinate_bundled)
        string(REPLACE "|" ";" entry "${entry}")
        list(GET entry 0 dep)
        list(GET entry 1 path)
        if(PDFINATE_USE_SYSTEM_${dep} OR (dep STREQUAL "LIBYUV" AND NOT PDFINATE_USE_LIBYUV))
            continue()
        endif()
        file(GLOB contents "${PDFINATE_DEPS_DIR}/${path}/*")
        if(NOT contents)
            list(APPEND missing "deps/${path}")
        endif()
    endforeach()
    set(${out} "${missing}" PARENT_SCOPE)
endfunction()

_pdfinate_missing_bundled(_missing)
if(_missing)
    find_package(Git QUIET)
    if(GIT_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
        list(JOIN _missing ", " _names)
        message(STATUS "PDFinate: fetching the bundled ${_names}")
        execute_process(COMMAND "${GIT_EXECUTABLE}" submodule update --init --checkout -- ${_missing}
                        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
        _pdfinate_missing_bundled(_missing)
    endif()
endif()
if(_missing)
    list(JOIN _missing " " _paths)
    message(FATAL_ERROR "PDFinate: the bundled dependencies this build compiles are not checked out. "
                        "From the top of PDFinate, run:\n"
                        "  git submodule update --init --checkout -- ${_paths}\n"
                        "or supply them from outside (PDFINATE_<DEP>_TARGET or PDFINATE_USE_SYSTEM_<DEP>).")
endif()
unset(_missing)
unset(_names)
unset(_paths)

# lcms2, OpenJPEG, FreeType, HarfBuzz, highway, fast_float and dragonbox are built from PDFium's own
# BUILD.gn files, through the generated data. These five have build files of their own in their own
# repositories, which the generator does not read, so their recipes are here.

if(NOT PDFINATE_USE_SYSTEM_ZLIB)
    include("${CMAKE_CURRENT_LIST_DIR}/deps/zlib.cmake")
    pdfinate_gn_provide("//third_party/zlib:zlib" pdfinate_bundled_zlib)
endif()

if(NOT PDFINATE_USE_SYSTEM_JPEG)
    include("${CMAKE_CURRENT_LIST_DIR}/deps/libjpeg_turbo.cmake")
    pdfinate_gn_provide("//third_party/libjpeg_turbo:libjpeg" pdfinate_bundled_jpeg)
    pdfinate_gn_provide("//third_party/libjpeg_turbo:libjpeg_headers" pdfinate_bundled_jpeg_headers)
endif()

if(PDFINATE_USE_LIBYUV AND NOT PDFINATE_USE_SYSTEM_LIBYUV)
    include("${CMAKE_CURRENT_LIST_DIR}/deps/libyuv.cmake")
    pdfinate_gn_provide("//third_party/libyuv:libyuv" pdfinate_bundled_libyuv_config)
endif()

if(NOT PDFINATE_USE_SYSTEM_ABSEIL)
    include("${CMAKE_CURRENT_LIST_DIR}/deps/abseil.cmake")
    pdfinate_gn_provide("//third_party/abseil-cpp:absl" pdfinate_bundled_abseil)
endif()

if(NOT PDFINATE_USE_SYSTEM_ICU)
    include("${CMAKE_CURRENT_LIST_DIR}/deps/icu.cmake")
    pdfinate_gn_provide("//third_party/icu:icuuc" pdfinate_bundled_icu)
    pdfinate_gn_provide("//third_party/icu:icuuc_public" pdfinate_bundled_icu_public)
endif()

# Chromium's compiler-flag configs. pdfinate_compile_options stands in for what of them matters.
pdfinate_gn_ignore("//build/config/compiler:")
pdfinate_gn_ignore("//build/config/sanitizers:")
