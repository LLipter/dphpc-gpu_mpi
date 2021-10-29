#include "io.cuh"

namespace gpu_mpi {

    __device__ int MPI_FILE_OPEN(MPI_Comm comm, const char *filename, int amode, MPI_Info info, MPI_File *fh){
        // check amode
        int cnt = 0;
        if(amode & MPI_MODE_RDONLY){
            cnt++;
        }
        if(amode & MPI_MODE_RDWR){
            cnt++;
        }
        if(amode & MPI_MODE_WRONLY){
            cnt++;
        }
        if(cnt != 1){
            // see documentation p495 line 7
            return MPI_ERR_AMODE;
        }

        if(((amode & MPI_MODE_CREATE) || (amode & MPI_MODE_EXCL)) && (amode & MPI_MODE_RDONLY)){
            // see documentation p495 line 8
            return MPI_ERR_AMODE;
        }

        if((amode & MPI_MODE_RDWR) && (amode & MPI_MODE_SEQUENTIAL)){
            // see documentation p495 line 9
            return MPI_ERR_AMODE;
        }
        
        // todo
        return 0;
    }

}