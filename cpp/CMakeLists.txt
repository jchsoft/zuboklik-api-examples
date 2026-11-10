cmake_minimum_required(VERSION 3.16)
project(zuboklik_api_examples CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(nlohmann_json REQUIRED)

add_executable(booking booking.cpp)
target_link_libraries(booking PRIVATE CURL::libcurl nlohmann_json::nlohmann_json)

add_executable(verify_webhook verify_webhook.cpp)
target_link_libraries(verify_webhook PRIVATE OpenSSL::Crypto nlohmann_json::nlohmann_json)
