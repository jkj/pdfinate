# ===========================================================================
# PDFinate — PDFium, built with CMake.
#
# The PDFium sources in pdfium/ and the dependencies in deps/ are upstream's, untouched. What to
# compile comes from PDFium's own BUILD.gn files, translated by tools/gn2cmake.py into
# cmake/generated/pdfium_gn.cmake. The rest of the build is in cmake/:
#
#   platform.cmake   the platform variables the generated data is conditioned on
#   gn.cmake         turning the generated data into targets
#   deps.cmake       where each dependency comes from: bundled, the system, or the embedding project
#   deps/            recipes for the bundled dependencies PDFium's BUILD.gn files do not describe
#
# The result is one library, pdfinate::pdfium: static by default, holding PDFium and every bundled
# dependency, so a program links that one archive and whatever dependencies it supplied itself.
# ===========================================================================
cmake_minimum_required(VERSION 3.21)
project(pdfinate VERSION 0.1.0 LANGUAGES C CXX)

option(BUILD_SHARED_LIBS "Build pdfium as a shared library instead of a static one" OFF)
option(PDFINATE_BUILD_SAMPLES "Build the sample programs in samples/" ${PROJECT_IS_TOP_LEVEL})

set(PDFINATE_PDFIUM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/pdfium")
set(PDFINATE_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps")
if(NOT EXISTS "${PDFINATE_PDFIUM_DIR}/BUILD.gn" OR NOT EXISTS "${PDFINATE_DEPS_DIR}/build/build_config.h")
    message(FATAL_ERROR "PDFinate: pdfium/ and deps/build are not checked out. "
                        "Run: git submodule update --init")
endif()

include(cmake/platform.cmake)
include(cmake/gn.cmake)

# Upstream builds PDFium with clang and nothing else. GCC may work; MSVC's own compiler does not.
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(WARNING "PDFinate: PDFium is only tested upstream with clang; this is "
                    "${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}.")
endif()

# Objects compiled into a shared library must be position-independent. A static build leaves the
# choice to the embedding project's CMAKE_POSITION_INDEPENDENT_CODE.
if(BUILD_SHARED_LIBS)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# --- Compile settings ------------------------------------------------------------------------
# What every PDFium object needs, standing in for the parts of Chromium's //build configs that
# matter outside Chromium. The include directories are GN's "//": PDFium includes every header by
# its path from the top of the source tree, and that tree is pdfium/ with deps/ laid over it.
add_library(pdfinate_compile_options INTERFACE)
target_compile_features(pdfinate_compile_options INTERFACE cxx_std_20)
target_include_directories(pdfinate_compile_options INTERFACE "${PDFINATE_PDFIUM_DIR}" "${PDFINATE_DEPS_DIR}")
if(WIN32)
    # GN's default Windows configs (lean_and_mean, nominmax, unicode, winver). Without
    # WIN32_LEAN_AND_MEAN, windows.h brings winspool.h, whose SetForm macro renames
    # CPDF_AnnotContext::SetForm in any file that sees windows.h after the class.
    target_compile_definitions(pdfinate_compile_options INTERFACE
        WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE _CRT_SECURE_NO_DEPRECATE
        _WIN32_WINNT=0x0A00 WINVER=0x0A00)
endif()
if(MSVC)
    target_compile_options(pdfinate_compile_options INTERFACE /utf-8 /Zc:__cplusplus)
endif()
if(BUILD_SHARED_LIBS)
    # Exports the FPDF_* API from the library (public/fpdfview.h).
    target_compile_definitions(pdfinate_compile_options INTERFACE COMPONENT_BUILD)
endif()

# Third-party code is compiled with its warnings off: they are upstream's to fix, not ours.
add_library(pdfinate_third_party_options INTERFACE)
target_link_libraries(pdfinate_third_party_options INTERFACE pdfinate_compile_options)
if(MSVC)
    target_compile_options(pdfinate_third_party_options INTERFACE /w)
else()
    target_compile_options(pdfinate_third_party_options INTERFACE -w)
endif()

# --- PDFium ----------------------------------------------------------------------------------
include(cmake/deps.cmake)
include(cmake/generated/pdfium_gn.cmake)
pdfinate_write_forwarding_headers()
pdfinate_gn_build("//:pdfium")

add_library(pdfium cmake/link_language.cpp)
add_library(pdfinate::pdfium ALIAS pdfium)
pdfinate_gn_objects(_gn_objects)
get_property(_bundled_objects GLOBAL PROPERTY PDFINATE_BUNDLED_OBJECTS)
foreach(_target IN LISTS _gn_objects _bundled_objects)
    target_sources(pdfium PRIVATE $<TARGET_OBJECTS:${_target}>)
endforeach()
pdfinate_gn_link_interface(_link)
# Threads for the bundled code: abseil's synchronization, and zlib's one-time CPU detection.
find_package(Threads REQUIRED)
target_link_libraries(pdfium PUBLIC ${_link} Threads::Threads)
target_include_directories(pdfium PUBLIC
    $<BUILD_INTERFACE:${PDFINATE_PDFIUM_DIR}/public>
    $<INSTALL_INTERFACE:include/pdfium>)
if(BUILD_SHARED_LIBS)
    target_compile_definitions(pdfium INTERFACE COMPONENT_BUILD)
endif()
unset(_gn_objects)
unset(_bundled_objects)
unset(_target)

if(PDFINATE_BUILD_SAMPLES)
    add_subdirectory(samples)
endif()

# --- Installing ------------------------------------------------------------------------------
# The library, and PDFium's public headers under include/pdfium.
#
# A CMake package (find_package(pdfinate)) is installed too, unless a dependency came from the
# embedding project by target: that target belongs to the embedding project, which installs and
# describes it in its own way, so a package naming it could not be found anywhere else.
include(GNUInstallDirs)
option(PDFINATE_INSTALL "Install the pdfium library and its headers" ON)
if(PDFINATE_INSTALL)
    install(TARGETS pdfium EXPORT pdfinateTargets
            ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
    install(DIRECTORY "${PDFINATE_PDFIUM_DIR}/public/" DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/pdfium
            FILES_MATCHING PATTERN "*.h")
    install(FILES "${PDFINATE_PDFIUM_DIR}/LICENSE" DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses/pdfium)

    # The licences of the bundled code inside the library, which a program shipping it ships too. A
    # dependency supplied from outside is not in the library, and its licence is the supplier's to
    # ship. FreeType is under the FreeType License or the GPL, at the user's choice: both texts go.
    set(_licenses "agg23:${PDFINATE_PDFIUM_DIR}/third_party/agg23/copying")
    if(NOT PDFINATE_USE_SYSTEM_ABSEIL)
        list(APPEND _licenses "abseil:${PDFINATE_DEPS_DIR}/third_party/abseil-cpp/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_ICU)
        list(APPEND _licenses "icu:${PDFINATE_DEPS_DIR}/third_party/icu/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_HIGHWAY)
        list(APPEND _licenses "highway:${PDFINATE_DEPS_DIR}/third_party/highway/src/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_FAST_FLOAT)
        list(APPEND _licenses "fast_float:${PDFINATE_DEPS_DIR}/third_party/fast_float/src/LICENSE-MIT"
                              "fast_float:${PDFINATE_DEPS_DIR}/third_party/fast_float/src/LICENSE-APACHE"
                              "fast_float:${PDFINATE_DEPS_DIR}/third_party/fast_float/src/LICENSE-BOOST")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_DRAGONBOX)
        list(APPEND _licenses "dragonbox:${PDFINATE_DEPS_DIR}/third_party/dragonbox/src/LICENSE-Apache2-LLVM"
                              "dragonbox:${PDFINATE_DEPS_DIR}/third_party/dragonbox/src/LICENSE-Boost")
    endif()
    if(PDFINATE_USE_LIBYUV AND NOT PDFINATE_USE_SYSTEM_LIBYUV)
        list(APPEND _licenses "libyuv:${PDFINATE_DEPS_DIR}/third_party/libyuv/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_ZLIB)
        list(APPEND _licenses "zlib:${PDFINATE_DEPS_DIR}/third_party/zlib/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_JPEG)
        list(APPEND _licenses "libjpeg-turbo:${PDFINATE_DEPS_DIR}/third_party/libjpeg_turbo/LICENSE.md")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_OPENJPEG)
        list(APPEND _licenses "openjpeg:${PDFINATE_PDFIUM_DIR}/third_party/libopenjpeg/src/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_LCMS2)
        list(APPEND _licenses "lcms2:${PDFINATE_PDFIUM_DIR}/third_party/lcms/src/LICENSE")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_FREETYPE)
        list(APPEND _licenses "freetype:${PDFINATE_DEPS_DIR}/third_party/freetype/src/LICENSE.TXT"
                              "freetype:${PDFINATE_DEPS_DIR}/third_party/freetype/src/docs/FTL.TXT"
                              "freetype:${PDFINATE_DEPS_DIR}/third_party/freetype/src/docs/GPLv2.TXT")
    endif()
    if(NOT PDFINATE_USE_SYSTEM_HARFBUZZ)
        list(APPEND _licenses "harfbuzz:${PDFINATE_DEPS_DIR}/third_party/harfbuzz/src/COPYING")
    endif()
    foreach(_license IN LISTS _licenses)
        string(FIND "${_license}" ":" _colon)
        string(SUBSTRING "${_license}" 0 ${_colon} _name)
        math(EXPR _colon "${_colon} + 1")
        string(SUBSTRING "${_license}" ${_colon} -1 _file)
        install(FILES "${_file}" DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses/${_name})
    endforeach()
    unset(_licenses)
    unset(_license)
    unset(_colon)
    unset(_name)
    unset(_file)

    set(_supplied FALSE)
    set(_find "")
    foreach(_dep IN LISTS _pdfinate_deps)
        if(PDFINATE_${_dep}_TARGET)
            set(_supplied TRUE)
        endif()
    endforeach()
    if(NOT _supplied)
        # What the package must find again for the system dependencies its link interface names.
        foreach(_pair ZLIB:ZLIB JPEG:JPEG OPENJPEG:OpenJPEG FREETYPE:Freetype)
            string(REPLACE ":" ";" _pair "${_pair}")
            list(GET _pair 0 _dep)
            list(GET _pair 1 _package)
            if(PDFINATE_USE_SYSTEM_${_dep})
                string(APPEND _find "find_dependency(${_package})\n")
            endif()
        endforeach()
        if(PDFINATE_USE_SYSTEM_LCMS2 OR PDFINATE_USE_SYSTEM_HARFBUZZ)
            string(APPEND _find "find_dependency(PkgConfig)\n")
        endif()
        if(PDFINATE_USE_SYSTEM_LCMS2)
            string(APPEND _find "pkg_check_modules(PDFINATE_LCMS2 REQUIRED IMPORTED_TARGET lcms2)\n")
        endif()
        if(PDFINATE_USE_SYSTEM_HARFBUZZ)
            string(APPEND _find "pkg_check_modules(PDFINATE_HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz harfbuzz-subset)\n")
        endif()
        set(PDFINATE_FIND_DEPENDENCIES "${_find}")
        include(CMakePackageConfigHelpers)
        configure_package_config_file(cmake/pdfinateConfig.cmake.in
            "${CMAKE_CURRENT_BINARY_DIR}/pdfinateConfig.cmake"
            INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/pdfinate)
        write_basic_package_version_file("${CMAKE_CURRENT_BINARY_DIR}/pdfinateConfigVersion.cmake"
            COMPATIBILITY SameMinorVersion)
        install(EXPORT pdfinateTargets NAMESPACE pdfinate:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/pdfinate)
        install(FILES "${CMAKE_CURRENT_BINARY_DIR}/pdfinateConfig.cmake"
                      "${CMAKE_CURRENT_BINARY_DIR}/pdfinateConfigVersion.cmake"
                DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/pdfinate)
    endif()
    unset(_supplied)
    unset(_find)
    unset(_pair)
    unset(_dep)
    unset(_package)
endif()
unset(_link)
