cmake_minimum_required(VERSION 3.18)

find_package(JPEG)

# Specify the script to be executed
set(MY_SCRIPT "run.sh")

# Add a custom command to execute the script
add_custom_command(
    TARGET my_target
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E cmake_execute_process
    ARGS ${MY_SCRIPT}
)
