# libyuv — at the revision pdfium/DEPS pins, with the source lists and flags of its BUILD.gn.
# PDFium uses it for SIMD pixel-format conversions (PDF_USE_LIBYUV).
#
# Each CPU's SIMD code is chosen at run time by libyuv's own CPU detection (cpu_id.cc):
#   x86     SSE2/SSSE3/AVX2/AVX-512 in inline assembly inside the ordinary sources; no flags needed.
#   Arm     NEON, in its own files, compiled for Armv8 with the dot-product and int8 matrix
#           extensions that libyuv uses where the CPU has them. 64-bit Arm also gets SVE2, and on
#           Linux and Android SME, each in files compiled for those extensions, as Chromium has it.
#
# libyuv's MJPEG decoding is left out: PDFium does not use it, and it would need libjpeg.
set(_dir "${PDFINATE_DEPS_DIR}/third_party/libyuv")
set(_sources compare.cc compare_common.cc compare_gcc.cc compare_wasm.cc compare_win.cc convert.cc
             convert_argb.cc convert_from.cc convert_from_argb.cc convert_jpeg.cc convert_to_argb.cc
             convert_to_i420.cc cpu_id.cc mjpeg_decoder.cc mjpeg_validate.cc planar_functions.cc
             rotate.cc rotate_any.cc rotate_argb.cc rotate_common.cc rotate_gcc.cc rotate_wasm.cc
             rotate_win.cc row_any.cc row_common.cc row_gcc.cc row_wasm.cc row_win.cc scale.cc
             scale_any.cc scale_argb.cc scale_common.cc scale_gcc.cc scale_rgb.cc scale_uv.cc
             scale_wasm.cc scale_win.cc video_common.cc)
list(TRANSFORM _sources PREPEND "${_dir}/source/")

set(_neon FALSE)
set(_sve FALSE)
set(_sme FALSE)
if(PDFINATE_CPU STREQUAL "arm64" OR PDFINATE_CPU STREQUAL "arm")
    set(_neon TRUE)
endif()
if(PDFINATE_CPU STREQUAL "arm64")
    set(_sve TRUE)
    if(PDFINATE_IS_LINUX OR PDFINATE_IS_ANDROID)
        set(_sme TRUE)
    endif()
endif()

# The usage requirements, as libyuv_config: what anything including libyuv's headers needs too.
add_library(pdfinate_bundled_libyuv_config INTERFACE)
target_include_directories(pdfinate_bundled_libyuv_config INTERFACE "${_dir}/include")
target_compile_definitions(pdfinate_bundled_libyuv_config INTERFACE CHROMIUM LIBYUV_DISABLE_LSX
                                                                    LIBYUV_DISABLE_LASX)
if(NOT _neon)
    target_compile_definitions(pdfinate_bundled_libyuv_config INTERFACE LIBYUV_DISABLE_NEON)
endif()
if(NOT _sve)
    target_compile_definitions(pdfinate_bundled_libyuv_config INTERFACE LIBYUV_DISABLE_SVE)
endif()
if(NOT _sme)
    target_compile_definitions(pdfinate_bundled_libyuv_config INTERFACE LIBYUV_DISABLE_SME)
endif()

# clang-cl takes GCC-style -march only through /clang:.
function(_pdfinate_libyuv_march target march)
    if(MSVC)
        target_compile_options(${target} PRIVATE "/clang:-march=${march}")
    else()
        target_compile_options(${target} PRIVATE "-march=${march}")
    endif()
endfunction()

add_library(pdfinate_bundled_libyuv OBJECT ${_sources})
target_link_libraries(pdfinate_bundled_libyuv PUBLIC pdfinate_bundled_libyuv_config
                                              PRIVATE pdfinate_third_party_options)
if(NOT MSVC)
    # Lets the compiler fuse multiply-adds in the NEON code, as Chromium's build does.
    target_compile_options(pdfinate_bundled_libyuv PRIVATE -ffp-contract=fast)
endif()
set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_libyuv)

if(_neon)
    add_library(pdfinate_bundled_libyuv_neon OBJECT
        "${_dir}/source/compare_neon.cc" "${_dir}/source/compare_neon64.cc"
        "${_dir}/source/rotate_neon.cc" "${_dir}/source/rotate_neon64.cc"
        "${_dir}/source/row_neon.cc" "${_dir}/source/row_neon64.cc"
        "${_dir}/source/scale_neon.cc" "${_dir}/source/scale_neon64.cc")
    target_link_libraries(pdfinate_bundled_libyuv_neon PRIVATE pdfinate_bundled_libyuv_config
                                                               pdfinate_third_party_options)
    if(PDFINATE_CPU STREQUAL "arm64")
        _pdfinate_libyuv_march(pdfinate_bundled_libyuv_neon "armv8-a+dotprod+i8mm")
    endif()
    set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_libyuv_neon)
endif()

if(_sve)
    add_library(pdfinate_bundled_libyuv_sve OBJECT
        "${_dir}/source/rotate_sve.cc" "${_dir}/source/row_sve.cc")
    target_link_libraries(pdfinate_bundled_libyuv_sve PRIVATE pdfinate_bundled_libyuv_config
                                                              pdfinate_third_party_options)
    _pdfinate_libyuv_march(pdfinate_bundled_libyuv_sve "armv8.5-a+i8mm+sve2")
    set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_libyuv_sve)
endif()

if(_sme)
    add_library(pdfinate_bundled_libyuv_sme OBJECT
        "${_dir}/source/rotate_sme.cc" "${_dir}/source/row_sme.cc" "${_dir}/source/scale_sme.cc")
    target_link_libraries(pdfinate_bundled_libyuv_sme PRIVATE pdfinate_bundled_libyuv_config
                                                              pdfinate_third_party_options)
    _pdfinate_libyuv_march(pdfinate_bundled_libyuv_sme "armv8.5-a+i8mm+sme")
    set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_libyuv_sme)
endif()

unset(_dir)
unset(_sources)
unset(_neon)
unset(_sve)
unset(_sme)
