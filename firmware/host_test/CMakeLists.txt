# SPDX-License-Identifier: GPL-3.0-or-later
#
# Host tests for components/vroo_wire, built as plain C99 with the computer's compiler. From the repository root:
#   cmake -S firmware/host_test -B firmware/host_test/build && cmake --build firmware/host_test/build
#   firmware/host_test/build/test_vroo_wire
cmake_minimum_required(VERSION 3.16)
project(vroo_wire_host_test C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_executable(test_vroo_wire test_vroo_wire.c ../components/vroo_wire/vroo_wire.c)
target_include_directories(test_vroo_wire PRIVATE ../components/vroo_wire/include)
target_compile_options(test_vroo_wire PRIVATE -Wall -Wextra -Wpedantic -Werror)
