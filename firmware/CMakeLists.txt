# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Build only main and the components it needs, not all of ESP-IDF.
idf_build_set_property(MINIMAL_BUILD ON)
project(vroo_box)
