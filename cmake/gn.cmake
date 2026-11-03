# ===========================================================================
# Turning the data in generated/pdfium_gn.cmake into CMake targets.
#
# The generated file calls pdfinate_gn_target(), pdfinate_gn_defined() and pdfinate_gn_list() to
# record each GN target and config. Its if() blocks are evaluated as it is included, so by the time
# pdfinate_gn_build() runs, every list holds what GN would have computed for this platform and these
# options.
#
# pdfinate_gn_build() then walks the graph from one root label and makes, for each label it reaches:
#
#   config                          an INTERFACE library carrying its defines, include directories,
#                                   libraries and nested configs
#   source_set / static_library /   an OBJECT library, compiled with its defines, include
#   component                       directories and configs, and linked to its deps (PRIVATE) and
#                                   public_deps and public_configs (PUBLIC); an INTERFACE library
#                                   instead when it compiles nothing
#   group                           an INTERFACE library linked to its deps
#
# Linking one OBJECT library to another only passes on usage requirements, not object files, so the
# root collects the objects of every library reached itself (pdfinate_gn_objects()).
#
# A label outside the PDFium tree has no generated definition. Something must supply a target for it
# with pdfinate_gn_provide() before the walk, or name it as ignored with pdfinate_gn_ignore().
# ===========================================================================

function(_pdfinate_gn_id label out)
    string(MAKE_C_IDENTIFIER "${label}" id)
    set(${out} "pdfinate_gn${id}" PARENT_SCOPE)
endfunction()

# --- Recording (called by generated/pdfium_gn.cmake) ------------------------------------------

function(pdfinate_gn_target label kind)
    _pdfinate_gn_id("${label}" id)
    set_property(GLOBAL PROPERTY ${id}_KIND ${kind})
    if(NOT "CONDITIONAL" IN_LIST ARGN)
        set_property(GLOBAL PROPERTY ${id}_DEFINED TRUE)
    endif()
endfunction()

function(pdfinate_gn_defined label)
    _pdfinate_gn_id("${label}" id)
    set_property(GLOBAL PROPERTY ${id}_DEFINED TRUE)
endfunction()

function(pdfinate_gn_list label field verb)
    _pdfinate_gn_id("${label}" id)
    if(verb STREQUAL "SET")
        set_property(GLOBAL PROPERTY ${id}_${field} "${ARGN}")
    elseif(verb STREQUAL "APPEND")
        set_property(GLOBAL APPEND PROPERTY ${id}_${field} "${ARGN}")
    else()
        get_property(items GLOBAL PROPERTY ${id}_${field})
        if(items AND ARGN)
            list(REMOVE_ITEM items ${ARGN})
        endif()
        set_property(GLOBAL PROPERTY ${id}_${field} "${items}")
    endif()
endfunction()

# --- Supplying what the PDFium tree does not define -------------------------------------------

# Use an existing target wherever <label> is named. It replaces the generated definition, if any.
function(pdfinate_gn_provide label target)
    _pdfinate_gn_id("${label}" id)
    set_property(GLOBAL PROPERTY ${id}_PROVIDED "${target}")
endfunction()

# Keep a generated config, but link <target> in place of the libraries it names. For the configs
# that switch PDFium to a system copy of a dependency: their defines are right, but their library
# names ("z", "jpeg") or pkg-config packages are not how PDFinate finds that copy.
function(pdfinate_gn_replace_libs label target)
    _pdfinate_gn_id("${label}" id)
    set_property(GLOBAL PROPERTY ${id}_LIBS_REPLACED "${target}")
endfunction()

# Labels to drop wherever they are named: the //build configs that carry Chromium's compiler flags.
function(pdfinate_gn_ignore prefix)
    set_property(GLOBAL APPEND PROPERTY PDFINATE_GN_IGNORED "${prefix}")
endfunction()

# --- Building ---------------------------------------------------------------------------------

function(_pdfinate_gn_ignored label out)
    get_property(prefixes GLOBAL PROPERTY PDFINATE_GN_IGNORED)
    foreach(prefix IN LISTS prefixes)
        string(FIND "${label}" "${prefix}" pos)
        if(pos EQUAL 0)
            set(${out} TRUE PARENT_SCOPE)
            return()
        endif()
    endforeach()
    set(${out} FALSE PARENT_SCOPE)
endfunction()

# The CMake target standing for <label>, or empty for an ignored one.
function(_pdfinate_gn_cmake_target label out)
    _pdfinate_gn_ignored("${label}" ignored)
    if(ignored)
        set(${out} "" PARENT_SCOPE)
        return()
    endif()
    _pdfinate_gn_id("${label}" id)
    get_property(provided GLOBAL PROPERTY ${id}_PROVIDED)
    if(provided)
        set(${out} "${provided}" PARENT_SCOPE)
    else()
        set(${out} "${id}" PARENT_SCOPE)
    endif()
endfunction()

function(_pdfinate_gn_visit label)
    get_property(visited GLOBAL PROPERTY PDFINATE_GN_VISITED)
    if(label IN_LIST visited)
        return()
    endif()
    set_property(GLOBAL APPEND PROPERTY PDFINATE_GN_VISITED "${label}")

    _pdfinate_gn_ignored("${label}" ignored)
    _pdfinate_gn_id("${label}" id)
    get_property(provided GLOBAL PROPERTY ${id}_PROVIDED)
    if(ignored OR provided)
        return()
    endif()
    get_property(kind GLOBAL PROPERTY ${id}_KIND)
    get_property(defined GLOBAL PROPERTY ${id}_DEFINED)
    if(NOT kind)
        message(FATAL_ERROR "PDFinate: nothing supplies ${label}, which PDFium needs here. "
                            "It is outside the PDFium tree; cmake/deps.cmake must provide it.")
    endif()
    if(NOT defined)
        message(FATAL_ERROR "PDFinate: PDFium needs ${label}, which its BUILD.gn defines only under "
                            "conditions this configuration does not meet.")
    endif()
    set_property(GLOBAL APPEND PROPERTY PDFINATE_GN_REACHED "${label}")
    foreach(field deps public_deps configs public_configs all_dependent_configs)
        get_property(labels GLOBAL PROPERTY ${id}_${field})
        foreach(dep IN LISTS labels)
            _pdfinate_gn_visit("${dep}")
        endforeach()
    endforeach()
endfunction()

function(_pdfinate_gn_targets labels out)
    set(result "")
    foreach(label IN LISTS labels)
        _pdfinate_gn_cmake_target("${label}" target)
        if(target)
            list(APPEND result "${target}")
        endif()
    endforeach()
    set(${out} "${result}" PARENT_SCOPE)
endfunction()

# CMake wants a framework as "-framework Name", and a Windows library without ".lib".
function(_pdfinate_gn_libs id out)
    get_property(libs GLOBAL PROPERTY ${id}_libs)
    get_property(frameworks GLOBAL PROPERTY ${id}_frameworks)
    set(result "")
    foreach(lib IN LISTS libs)
        string(REGEX REPLACE "\\.lib$" "" lib "${lib}")
        list(APPEND result "${lib}")
    endforeach()
    foreach(framework IN LISTS frameworks)
        string(REGEX REPLACE "\\.framework$" "" framework "${framework}")
        list(APPEND result "-framework ${framework}")
    endforeach()
    set(${out} "${result}" PARENT_SCOPE)
endfunction()

function(_pdfinate_gn_make label)
    _pdfinate_gn_id("${label}" id)
    get_property(kind GLOBAL PROPERTY ${id}_KIND)
    get_property(sources GLOBAL PROPERTY ${id}_sources)
    get_property(defines GLOBAL PROPERTY ${id}_defines)
    get_property(include_dirs GLOBAL PROPERTY ${id}_include_dirs)
    foreach(field deps public_deps configs public_configs all_dependent_configs)
        get_property(labels GLOBAL PROPERTY ${id}_${field})
        _pdfinate_gn_targets("${labels}" ${field})
    endforeach()
    get_property(replaced GLOBAL PROPERTY ${id}_LIBS_REPLACED)
    if(replaced)
        set(libs "${replaced}")
    else()
        _pdfinate_gn_libs(${id} libs)
    endif()

    set(compiled "")
    foreach(source IN LISTS sources)
        if(source MATCHES "\\.(c|cc|cpp)$")
            list(APPEND compiled "${source}")
        endif()
    endforeach()

    if(kind STREQUAL "config" OR kind STREQUAL "group" OR NOT compiled)
        add_library(${id} INTERFACE)
        target_compile_definitions(${id} INTERFACE ${defines})
        target_include_directories(${id} SYSTEM INTERFACE ${include_dirs})
        target_link_libraries(${id} INTERFACE ${configs} ${public_configs} ${all_dependent_configs}
                                              ${deps} ${public_deps} ${libs})
        return()
    endif()

    add_library(${id} OBJECT ${sources})
    target_compile_definitions(${id} PRIVATE ${defines})
    target_include_directories(${id} PRIVATE ${include_dirs})
    target_link_libraries(${id}
        PRIVATE ${configs} ${deps} pdfinate_compile_options
        PUBLIC  ${public_configs} ${all_dependent_configs} ${public_deps} ${libs})
    set_property(GLOBAL APPEND PROPERTY PDFINATE_GN_OBJECT_TARGETS ${id})
endfunction()

# Walks from <root> and makes a target for every label reached. Afterwards, the CMake target for
# any label is _pdfinate_gn_cmake_target(), and pdfinate_gn_objects() lists the OBJECT libraries.
function(pdfinate_gn_build root)
    # The inputs must be the files the data was generated from.
    list(LENGTH PDFINATE_GN_INPUTS n)
    math(EXPR last "${n} - 1")
    foreach(i RANGE 0 ${last} 2)
        math(EXPR j "${i} + 1")
        list(GET PDFINATE_GN_INPUTS ${i} file)
        list(GET PDFINATE_GN_INPUTS ${j} expected)
        file(SHA256 "${PDFINATE_PDFIUM_DIR}/${file}" actual)
        if(NOT actual STREQUAL expected)
            message(FATAL_ERROR
                "PDFinate: pdfium/${file} has changed since cmake/generated/pdfium_gn.cmake was "
                "generated from it. Run tools/gn2cmake.py and review the result.")
        endif()
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PDFINATE_PDFIUM_DIR}/${file}")
    endforeach()

    _pdfinate_gn_visit("${root}")
    get_property(reached GLOBAL PROPERTY PDFINATE_GN_REACHED)
    foreach(label IN LISTS reached)
        _pdfinate_gn_make("${label}")
    endforeach()
endfunction()

function(pdfinate_gn_target_for label out)
    _pdfinate_gn_cmake_target("${label}" target)
    set(${out} "${target}" PARENT_SCOPE)
endfunction()

function(pdfinate_gn_objects out)
    get_property(targets GLOBAL PROPERTY PDFINATE_GN_OBJECT_TARGETS)
    set(${out} "${targets}" PARENT_SCOPE)
endfunction()

# What a program linking the finished library must link as well: the system libraries and frameworks
# the reached targets name, and every target supplied from outside (pdfinate_gn_provide() and
# pdfinate_gn_replace_libs()). The bundled dependencies are not in it: their objects are in the
# library itself.
function(pdfinate_gn_link_interface out)
    get_property(visited GLOBAL PROPERTY PDFINATE_GN_VISITED)
    set(result "")
    foreach(label IN LISTS visited)
        _pdfinate_gn_ignored("${label}" ignored)
        if(ignored)
            continue()
        endif()
        _pdfinate_gn_id("${label}" id)
        get_property(provided GLOBAL PROPERTY ${id}_PROVIDED)
        if(provided)
            if(NOT provided MATCHES "^pdfinate_bundled_")
                list(APPEND result "${provided}")
            endif()
            continue()
        endif()
        get_property(replaced GLOBAL PROPERTY ${id}_LIBS_REPLACED)
        if(replaced)
            list(APPEND result "${replaced}")
        else()
            _pdfinate_gn_libs(${id} libs)
            list(APPEND result ${libs})
        endif()
    endforeach()
    list(REMOVE_DUPLICATES result)
    set(${out} "${result}" PARENT_SCOPE)
endfunction()
