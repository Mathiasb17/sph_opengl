include_directories(./sph/)

set(CUDA_SPH_FILES 
	./sph/sph_cuda.cu
	)

set(SPH_FILES
	./sph/sph.cpp
	./sph/iisph/iisph.cpp
	./sph/pcisph/pcisph.cpp
	)
