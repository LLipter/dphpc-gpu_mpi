configure_file(convert_everything.py convert_everything.py COPYONLY)
configure_file(show_compile_options.py show_compile_options.py COPYONLY)
configure_file(convert_and_build.sh convert_and_build.sh COPYONLY)
configure_file(environment.sh environment.sh COPYONLY)

configure_file(build_on_gpu.py build_on_gpu.py) # it requires CMAKE_BUILD_TYPE to be set
configure_file(gpumpicc.py gpumpicc.py)

add_executable(gpu_info gpu_info.cu)