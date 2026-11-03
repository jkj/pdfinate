# abseil — Chromium's copy, at the revision pdfium/DEPS pins.
#
# PDFium uses three things from it: absl::Cleanup and absl::InlinedVector, which are header-only, and
# absl::flat_hash_set, whose hash table code reaches into the sampling profiler, and through it
# synchronization, time and stack traces. Rather than restate abseil's dependency graph here, this
# compiles the library directories that graph spans, minus tests, benchmarks and test helpers; the
# linker keeps only what PDFium reaches.
#
# Left out entirely: flags, log, random and status, none of which the parts above reach.
set(_dir "${PDFINATE_DEPS_DIR}/third_party/abseil-cpp")
set(_sources "")
foreach(_sub base container crc debugging hash numeric profiling strings synchronization time types)
    file(GLOB_RECURSE _found CONFIGURE_DEPENDS "${_dir}/absl/${_sub}/*.cc")
    list(APPEND _sources ${_found})
endforeach()
list(FILTER _sources EXCLUDE REGEX
     "(_test|_benchmark|benchmarks|test_util|test_helper|_testing|mock|/testing/|fuzz|gentables|print_hash_of|test_instance_tracker|_test_common|test_time_zone_names)[^/]*\\.cc$")

if(NOT WIN32)
    # The few files that are Windows-only by name rather than by #ifdef.
    list(FILTER _sources EXCLUDE REGEX "_win\\.cc$")
endif()

add_library(pdfinate_bundled_abseil OBJECT ${_sources})
target_include_directories(pdfinate_bundled_abseil PUBLIC "${_dir}")
# As Chromium's BUILD.gn has it (absl_define_config).
target_compile_definitions(pdfinate_bundled_abseil PUBLIC ABSL_ALLOCATOR_NOTHROW=1)
if(WIN32)
    target_compile_definitions(pdfinate_bundled_abseil PUBLIC _ENABLE_EXTENDED_ALIGNED_STORAGE NOMINMAX)
endif()
target_link_libraries(pdfinate_bundled_abseil PRIVATE pdfinate_third_party_options)
set_property(GLOBAL APPEND PROPERTY PDFINATE_BUNDLED_OBJECTS pdfinate_bundled_abseil)
unset(_dir)
unset(_sources)
unset(_found)
