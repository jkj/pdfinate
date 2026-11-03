# libjpeg-turbo — Chromium's copy, at the revision pdfium/DEPS pins, with the source lists of its
# BUILD.gn. libjpeg-turbo builds its sample-handling code three times, for 8-, 12- and 16-bit samples;
# the 12- and 16-bit builds are the same files compiled with BITS_IN_JSAMPLE set.
#
# MANGLE_JPEG_NAMES renames every symbol chromium_jpeg_* (src/jpeglibmangler.h), so this copy cannot
# collide with another libjpeg in the same program.
#
# SIMD, as Chromium has it, chosen at run time by libjpeg-turbo's own CPU detection:
#   Arm     NEON intrinsics, which need nothing beyond the C compiler.
#   x86     MMX/SSE2/AVX2 in NASM assembly, which needs the nasm assembler. Without one, the build
#           warns and uses the portable C code; PDFINATE_JPEG_SIMD=OFF asks for that outright.
set(_dir "${PDFINATE_DEPS_DIR}/third_party/libjpeg_turbo")

set(_jpeg16 jcapistd.c jccolor.c jcdiffct.c jclossls.c jcmainct.c jcprepct.c jcsample.c jdapistd.c
            jdcolor.c jddiffct.c jdlossls.c jdmainct.c jdpostct.c jdsample.c jutils.c)
set(_jpeg12 ${_jpeg16} jccoefct.c jcdctmgr.c jdcoefct.c jddctmgr.c jdmerge.c jfdctfst.c jfdctint.c
            jidctflt.c jidctfst.c jidctint.c jidctred.c jquant1.c jquant2.c)
set(_jpeg8 ${_jpeg12} jcapimin.c jchuff.c jcicc.c jcinit.c jclhuff.c jcmarker.c jcmaster.c jcomapi.c
           jcparam.c jcphuff.c jctrans.c jdapimin.c jdatadst.c jdatasrc.c jdhuff.c jdicc.c jdinput.c
           jdlhuff.c jdmarker.c jdmaster.c jdphuff.c jdtrans.c jerror.c jfdctflt.c jmemmgr.c
           jmemnobs.c jpeg_nbits.c)
list(TRANSFORM _jpeg16 PREPEND "${_dir}/src/")
list(TRANSFORM _jpeg12 PREPEND "${_dir}/src/")
list(TRANSFORM _jpeg8 PREPEND "${_dir}/src/")

add_library(pdfinate_bundled_jpeg_headers INTERFACE)
target_include_directories(pdfinate_bundled_jpeg_headers INTERFACE "${_dir}/src")
target_compile_definitions(pdfinate_bundled_jpeg_headers INTERFACE MANGLE_JPEG_NAMES)

option(PDFINATE_JPEG_SIMD "Build the bundled libjpeg-turbo's SIMD code (needs nasm on x86)" ON)
set(_simd_defines "")
set(_simd_sources "")
if(PDFINATE_JPEG_SIMD AND (PDFINATE_CPU STREQUAL "arm64" OR PDFINATE_CPU STREQUAL "arm"))
    set(_simd_defines NEON_INTRINSICS WITH_SIMD)
    set(_simd_sources
        simd/arm/jccolor-neon.c simd/arm/jcgray-neon.c simd/arm/jcphuff-neon.c
        simd/arm/jcsample-neon.c simd/arm/jdcolor-neon.c simd/arm/jdmerge-neon.c
        simd/arm/jdsample-neon.c simd/arm/jfdctfst-neon.c simd/arm/jfdctint-neon.c
        simd/arm/jidctfst-neon.c simd/arm/jidctint-neon.c simd/arm/jidctred-neon.c
        simd/arm/jquanti-neon.c)
    if(PDFINATE_CPU STREQUAL "arm64")
        list(APPEND _simd_sources simd/arm/aarch64/jchuff-neon.c simd/arm/aarch64/jsimd.c)
    else()
        list(APPEND _simd_sources simd/arm/aarch32/jchuff-neon.c simd/arm/aarch32/jsimd.c)
    endif()
    list(TRANSFORM _simd_sources PREPEND "${_dir}/")
elseif(PDFINATE_JPEG_SIMD AND (PDFINATE_CPU STREQUAL "x86" OR PDFINATE_CPU STREQUAL "x64"))
    include(CheckLanguage)
    check_language(ASM_NASM)
    if(CMAKE_ASM_NASM_COMPILER)
        enable_language(ASM_NASM)
        if(PDFINATE_CPU STREQUAL "x64")
            set(_arch x86_64)
            set(_asm jccolor-avx2 jccolor-sse2 jcgray-avx2 jcgray-sse2 jchuff-sse2 jcphuff-sse2
                     jcsample-avx2 jcsample-sse2 jdcolor-avx2 jdcolor-sse2 jdmerge-avx2 jdmerge-sse2
                     jdsample-avx2 jdsample-sse2 jfdctflt-sse jfdctfst-sse2 jfdctint-avx2
                     jfdctint-sse2 jidctflt-sse2 jidctfst-sse2 jidctint-avx2 jidctint-sse2
                     jidctred-sse2 jquantf-sse2 jquanti-avx2 jquanti-sse2 jsimdcpu)
            set(_asm_defines __x86_64__ PIC)
        else()
            set(_arch i386)
            set(_asm jccolor-avx2 jccolor-mmx jccolor-sse2 jcgray-avx2 jcgray-mmx jcgray-sse2
                     jchuff-sse2 jcphuff-sse2 jcsample-avx2 jcsample-mmx jcsample-sse2 jdcolor-avx2
                     jdcolor-mmx jdcolor-sse2 jdmerge-avx2 jdmerge-mmx jdmerge-sse2 jdsample-avx2
                     jdsample-mmx jdsample-sse2 jfdctflt-3dn jfdctflt-sse jfdctfst-mmx
                     jfdctfst-sse2 jfdctint-avx2 jfdctint-mmx jfdctint-sse2 jidctflt-3dn
                     jidctflt-sse jidctflt-sse2 jidctfst-mmx jidctfst-sse2 jidctint-avx2
                     jidctint-mmx jidctint-sse2 jidctred-mmx jidctred-sse2 jquant-3dn jquant-mmx
                     jquant-sse jquantf-sse2 jquanti-avx2 jquanti-sse2 jsimdcpu)
            set(_asm_defines __x86__ PIC)
        endif()
        # The object format, which jsimdext.inc keys its symbol naming and sections on.
        if(PDFINATE_IS_WIN AND PDFINATE_CPU STREQUAL "x64")
            list(APPEND _asm_defines MSVC WIN64)
        elseif(PDFINATE_IS_WIN)
            list(APPEND _asm_defines MSVC WIN32)
        elseif(PDFINATE_IS_APPLE)
            list(APPEND _asm_defines MACHO)
        else()
            list(APPEND _asm_defines ELF)
        endif()
        list(TRANSFORM _asm PREPEND "${_dir}/simd/${_arch}/")
        list(TRANSFORM _asm APPEND ".asm")
        add_library(pdfinate_bundled_jpeg_asm OBJECT ${_asm})
        target_compile_definitions(pdfinate_bundled_jpeg_asm PRIVATE ${_asm_defines})
        # As options rather than include directories: older nasm wants the trailing slash, which
        # CMake drops from an include directory.
        target_compile_options(pdfinate_bundled_jpeg_asm PRIVATE
            "-I${_dir}/simd/nasm/" "-I${_dir}/simd/${_arch}/")
        set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_jpeg_asm)
        set(_simd_defines WITH_SIMD)
        set(_simd_sources "${_dir}/simd/${_arch}/jsimd.c")
        unset(_arch)
        unset(_asm)
        unset(_asm_defines)
    else()
        message(WARNING "PDFinate: no nasm assembler found, so the bundled libjpeg-turbo is built "
                        "without its x86 SIMD code, and decodes JPEG images several times slower. "
                        "Install nasm, or set PDFINATE_JPEG_SIMD=OFF to build without it on purpose.")
    endif()
endif()

add_library(pdfinate_bundled_jpeg OBJECT ${_jpeg8} ${_simd_sources})
target_compile_definitions(pdfinate_bundled_jpeg PRIVATE NO_GETENV NO_PUTENV ${_simd_defines})
if(PDFINATE_CPU STREQUAL "x86" OR PDFINATE_CPU STREQUAL "x64")
    target_compile_definitions(pdfinate_bundled_jpeg PRIVATE USE_CLZ_INTRINSIC)
endif()
target_include_directories(pdfinate_bundled_jpeg PRIVATE "${_dir}" "${_dir}/simd/arm")
target_link_libraries(pdfinate_bundled_jpeg PUBLIC pdfinate_bundled_jpeg_headers
                                            PRIVATE pdfinate_third_party_options)
set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_jpeg)

foreach(_bits 12 16)
    add_library(pdfinate_bundled_jpeg${_bits} OBJECT ${_jpeg${_bits}})
    target_compile_definitions(pdfinate_bundled_jpeg${_bits} PRIVATE NO_GETENV NO_PUTENV BITS_IN_JSAMPLE=${_bits})
    target_link_libraries(pdfinate_bundled_jpeg${_bits} PUBLIC pdfinate_bundled_jpeg_headers
                                                       PRIVATE pdfinate_third_party_options)
    set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_jpeg${_bits})
endforeach()

unset(_dir)
unset(_jpeg8)
unset(_jpeg12)
unset(_jpeg16)
unset(_simd_defines)
unset(_simd_sources)
