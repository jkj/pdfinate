# zlib — Chromium's copy, at the revision pdfium/DEPS pins, built the way its BUILD.gn builds it.
#
# Its zconf.h includes chromeconf.h, which renames every symbol Cr_z_*, so this copy cannot collide
# with another zlib in the same program.
#
# SIMD, as Chromium has it: on x86 and x64 (but not iOS) SSSE3 Adler-32, SSE2 inflate and slide-hash,
# and SSE4.2/PCLMUL CRC-32; on 32- and 64-bit Arm, NEON Adler-32, inflate and slide-hash, and the
# Armv8 CRC-32 instructions. Each is picked at run time by cpu_features.c, and the code carries its
# own per-function target attributes, so no compiler flags are needed. The SIMD inflate replaces
# zlib's own inflate.c with contrib/optimizations/inflate.c. Any other CPU gets the portable code.
set(_dir "${PDFINATE_DEPS_DIR}/third_party/zlib")
set(_sources adler32.c compress.c cpu_features.c crc32.c deflate.c gzclose.c gzlib.c gzread.c
             gzwrite.c infback.c inffast.c inftrees.c trees.c uncompr.c zutil.c)
set(_defines ZLIB_IMPLEMENTATION)

set(_x86 FALSE)
set(_arm FALSE)
if((PDFINATE_CPU STREQUAL "x86" OR PDFINATE_CPU STREQUAL "x64") AND NOT PDFINATE_IS_IOS)
    set(_x86 TRUE)
elseif(PDFINATE_CPU STREQUAL "arm" OR PDFINATE_CPU STREQUAL "arm64")
    set(_arm TRUE)
endif()

if(PDFINATE_CPU STREQUAL "x64" OR PDFINATE_CPU STREQUAL "arm64")
    list(APPEND _defines DEFLATE_COMPARE256_64LE INFLATE_CHUNK_READ_64LE DEFLATE_CHUNK_WRITE_64LE)
endif()

if(_x86)
    list(APPEND _sources adler32_simd.c contrib/optimizations/inffast_chunk.c
                         contrib/optimizations/inflate.c crc32_simd.c crc_folding.c)
    list(APPEND _defines ADLER32_SIMD_SSSE3 INFLATE_CHUNK_SIMD_SSE2 CRC32_SIMD_SSE42_PCLMUL
                         DEFLATE_SLIDE_HASH_SSE2)
    if(WIN32)
        list(APPEND _defines X86_WINDOWS)
    else()
        list(APPEND _defines X86_NOT_WINDOWS)
    endif()
elseif(_arm)
    list(APPEND _sources adler32_simd.c contrib/optimizations/inffast_chunk.c
                         contrib/optimizations/inflate.c crc32_simd.c)
    list(APPEND _defines ADLER32_SIMD_NEON INFLATE_CHUNK_SIMD_NEON DEFLATE_SLIDE_HASH_NEON
                         CRC32_ARMV8_CRC32)
    # How cpu_features.c asks the system whether the CPU has the CRC instructions.
    if(PDFINATE_IS_ANDROID)
        list(APPEND _defines ARMV8_OS_ANDROID)
    elseif(PDFINATE_IS_MAC)
        list(APPEND _defines ARMV8_OS_MACOS)
    elseif(PDFINATE_IS_IOS)
        list(APPEND _defines ARMV8_OS_IOS)
    elseif(PDFINATE_IS_WIN)
        list(APPEND _defines ARMV8_OS_WINDOWS)
    else()
        list(APPEND _defines ARMV8_OS_LINUX)
    endif()
else()
    list(APPEND _sources inflate.c)
    list(APPEND _defines CPU_NO_SIMD)
endif()

list(TRANSFORM _sources PREPEND "${_dir}/")
add_library(pdfinate_bundled_zlib OBJECT ${_sources})
target_compile_definitions(pdfinate_bundled_zlib PRIVATE ${_defines})
if(NOT WIN32)
    # zlib's gz* functions want the POSIX file API.
    target_compile_definitions(pdfinate_bundled_zlib PRIVATE HAVE_UNISTD_H HAVE_STDARG_H)
endif()
target_include_directories(pdfinate_bundled_zlib PUBLIC "${_dir}")
target_link_libraries(pdfinate_bundled_zlib PRIVATE pdfinate_third_party_options)
set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_zlib)
unset(_dir)
unset(_sources)
unset(_defines)
unset(_x86)
unset(_arm)
