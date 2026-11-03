// Deliberately empty. The pdfium library is assembled from the objects of other targets, and CMake
// cannot tell what language an object file is. This one C++ source makes it record the library as
// C++, so that a program written in C still links it with the C++ linker and runtime.
