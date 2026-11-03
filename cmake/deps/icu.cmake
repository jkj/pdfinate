# ICU — Chromium's copy, at the revision pdfium/DEPS pins: the common library only (icuuc), with
# Chromium's defines (icu_config and icu_code in its BUILD.gn).
#
# PDFium calls a handful of character-property functions (u_isalpha, u_tolower and the like) and the
# bidi algorithm (ubidi_*). The data both need is compiled into the library itself, so no ICU data
# file is shipped: stubdata.cpp stands in for it, and anything that would load data finds none.
#
# ICU's own symbol renaming stays on, so every entry point carries the version (u_isalpha_78), and
# this copy cannot collide with a system ICU loaded into the same program.
#
# The source list is read from the sources.gni Chromium's BUILD.gn takes it from.
set(_dir "${PDFINATE_DEPS_DIR}/third_party/icu")
file(READ "${_dir}/sources.gni" _gni)
string(REGEX MATCH "icuuc_sources = \\[[^]]*\\]" _block "${_gni}")
string(REGEX MATCHALL "\"source/common/[^\"]+\\.cpp\"" _sources "${_block}")
list(TRANSFORM _sources REPLACE "\"" "")
list(TRANSFORM _sources PREPEND "${_dir}/")
if(NOT _sources)
    message(FATAL_ERROR "PDFinate: no icuuc_sources in ${_dir}/sources.gni; its layout has changed.")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_dir}/sources.gni")

add_library(pdfinate_bundled_icu_public INTERFACE)
target_include_directories(pdfinate_bundled_icu_public INTERFACE "${_dir}/source/common")
target_compile_definitions(pdfinate_bundled_icu_public INTERFACE
    U_USING_ICU_NAMESPACE=0 U_ENABLE_DYLOAD=0 USE_CHROMIUM_ICU=1 U_ENABLE_TRACING=1
    U_ENABLE_RESOURCE_TRACING=0 U_STATIC_IMPLEMENTATION)

add_library(pdfinate_bundled_icu OBJECT ${_sources} "${_dir}/source/stubdata/stubdata.cpp")
target_compile_definitions(pdfinate_bundled_icu PRIVATE
    U_COMMON_IMPLEMENTATION U_ICUDATAENTRY_IN_COMMON HAVE_DLOPEN=0 UCONFIG_ONLY_HTML_CONVERSION=1
    UCONFIG_USE_ML_PHRASE_BREAKING=1 UCONFIG_USE_WINDOWS_LCID_MAPPING_API=0 U_CHARSET_IS_UTF8=1)
target_link_libraries(pdfinate_bundled_icu PUBLIC pdfinate_bundled_icu_public
                                           PRIVATE pdfinate_third_party_options)
set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_icu)
unset(_dir)
unset(_gni)
unset(_block)
unset(_sources)
