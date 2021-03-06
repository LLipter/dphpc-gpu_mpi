
#include <cuda.h>
#include <cooperative_groups.h>

#include <iostream>
#include <vector>
#include <cassert>

using namespace cooperative_groups;
using namespace std;

#define CUDA_CHECK(expr) do {\
    cudaError_t err = (expr);\
    if (err != cudaSuccess) {\
        std::cerr << "CUDA ERROR: " << __FILE__ << ":" << __LINE__ << ": " << #expr << " <" << cudaGetErrorName(err) << "> " << cudaGetErrorString(err) << "\n"; \
        abort(); \
    }\
} while(0)


__device__ void* volatile globalBufferData;
__device__ volatile int globalBufferOwner;


__device__ void p2pSendDevice(void* data, size_t dataSize, int srcThread, int dstThread) {
    int rank = this_grid().thread_rank();
    
    if (rank != srcThread && rank != dstThread) return;
    
    bool done = false;
    
    while (!done) {
        if (rank == srcThread && globalBufferOwner == srcThread) {
            memcpy((void*)globalBufferData, data, dataSize);
            __threadfence();
            globalBufferOwner = dstThread;
            //__threadfence();
            done = true;
        } else if (rank == dstThread && globalBufferOwner == dstThread) {
            memcpy(data, (void*)globalBufferData, dataSize);
            __threadfence();
            globalBufferOwner = srcThread;
            //__threadfence();
            done = true;
        }
    }
}

__global__ void kernelBenchmarkDevice(size_t dataSize, char* deviceSrcData, char* deviceDstData, int peakClkKHz) {
    int rank = this_grid().thread_rank();
    
    if (rank == 0) {
        globalBufferOwner = 0;
        globalBufferData = malloc(dataSize);
        assert(globalBufferData);
    }
    this_grid().sync();
    
    assert(globalBufferData);
    
    void* data = nullptr;
    if (rank == 0) {
        data = deviceSrcData;
    } else {
        data = deviceDstData;
    }
    
    int repetitions = 100;

    double E_T = 0;
    double E_T2 = 0;

    double E_BW = 0;
    double E_BW2 = 0;

    int dataPerSendRecv = 2 * dataSize;

    for (int r = 0; r < repetitions; r++) {
        auto t1 = clock64();
        p2pSendDevice(data, dataSize, /*srcThread*/ 0, /*dstThread*/ 1);
        p2pSendDevice(data, dataSize, /*srcThread*/ 1, /*dstThread*/ 0);
        auto t2 = clock64();

        double dt = (t2 - t1) * 0.001 / peakClkKHz;
        double bw = dataPerSendRecv / dt;

        E_T += dt;
        E_T2 += dt * dt;

        E_BW += bw;
        E_BW2 += bw * bw;
    }

    
    E_T /= repetitions;
    E_T2 /= repetitions;

    E_BW /= repetitions;
    E_BW2 /= repetitions;

    double timePerSendRecv = E_T;
    double timePerSendRecvErr = sqrt(E_T2 - E_T * E_T);
    double bandwidth = E_BW;
    double bandwidthErr = sqrt(E_BW2 - E_BW * E_BW);

    if (this_grid().thread_rank() == 0) {
	     
        printf("dataSize = %d B, time = %lg ( +- %lg ) us, bandwidth = %lg ( +- %lg ) MB/s \n",
               int(dataSize), timePerSendRecv * 1e6, timePerSendRecvErr * 1e6, bandwidth / 1e6, bandwidthErr / 1e6);
    }
    
    assert(globalBufferData);
    this_grid().sync();
    if (rank == 0) {
        free(globalBufferData);
    }
}

int main() {
    int deviceCount = -1;
    CUDA_CHECK(cudaGetDeviceCount(&deviceCount));
    assert(deviceCount >= 1);
    
    int peakClkKHz = -1;
    CUDA_CHECK(cudaDeviceGetAttribute(&peakClkKHz, cudaDevAttrClockRate, /*device = */0));
    assert(peakClkKHz > 0);
    
    // set maximum malloc allocatable memory on device to 8 Mb
    size_t maxDeviceSize = 1u << 23;
    CUDA_CHECK(cudaDeviceSetLimit(cudaLimitMallocHeapSize, maxDeviceSize));
    
    for (size_t dataSize = 1; dataSize < maxDeviceSize / 4; dataSize *= 2) {
        
        char* deviceSrcData = nullptr;
        CUDA_CHECK(cudaMalloc(&deviceSrcData, dataSize));
        
        char* deviceDstData = nullptr;
        CUDA_CHECK(cudaMalloc(&deviceDstData, dataSize));
        
        char* hostSrcData = (char*) calloc(dataSize, 1);
        assert(hostSrcData);
        char* hostDstData = (char*) calloc(dataSize, 1);
        assert(hostDstData);
        
        for (int i = 0; i < dataSize; i++) hostSrcData[i] = 17;
        
        CUDA_CHECK(cudaMemcpy(deviceSrcData, hostSrcData, dataSize, cudaMemcpyHostToDevice));
        
        dim3 blocksPerGrid = 2;
        dim3 threadsPerBlock = 1;
        
        void* params[] = {
            (void*)&dataSize, 
            (void*)&deviceSrcData, 
            (void*)&deviceDstData, 
            (void*)&peakClkKHz
        };
        
        CUDA_CHECK(cudaLaunchCooperativeKernel(
            /*const T *func*/(void*) kernelBenchmarkDevice,
            /*dim3 gridDim*/blocksPerGrid,
            /*dim3 blockDim*/threadsPerBlock,
            /*void **args*/params
            /*size_t sharedMem = 0,
            cudaStream_t stream = 0*/
            ));
        
        CUDA_CHECK(cudaPeekAtLastError());
        
        CUDA_CHECK(cudaDeviceSynchronize());
        
        CUDA_CHECK(cudaMemcpy(hostDstData, deviceDstData, dataSize, cudaMemcpyDeviceToHost));
        
        for (int i = 0; i < dataSize; i++) {
            if (hostDstData[i] != 17) {
                printf("Incorrect data!");
                abort();
            }
        }
        
        free(hostDstData);
        free(hostSrcData);
        
        CUDA_CHECK(cudaFree(deviceDstData));
        CUDA_CHECK(cudaFree(deviceSrcData));
    }
    
    printf("Exit\n");
    
    return 0;
}
