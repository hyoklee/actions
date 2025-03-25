cmake_minimum_required(VERSION 3.18)
project(action LANGUAGES C)
find_package(libaec CONFIG)
get_cmake_property(_variableNames VARIABLES)

if (DEFINED SZIP_LIBRARY)
  message(${SZIP_LIBRARY})
  message(${SZIP_INCLUDE_DIR})
endif()
