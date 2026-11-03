# pdfinate_info: the example from README.md, extended to render the first page, which exercises the
# whole library: the parser, fonts through FreeType, images through the codecs, and AGG.
add_executable(pdfinate_info pdfinate_info.c)
target_link_libraries(pdfinate_info PRIVATE pdfinate::pdfium)
