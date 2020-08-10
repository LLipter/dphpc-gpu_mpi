#include "datatypes.cuh"
#include "mpi.cuh"

// cuda_mpi.cuh should be included before device specific standard library functions
// because it relies on standard ones
#include "cuda_mpi.cuh"

#include "stdlib.cuh"
#include "string.cuh"

#include <cooperative_groups.h>
using namespace cooperative_groups;

#include "mpi_common.cuh"

#include "device_vector.cuh"

#include "operators.cuh"

#define MPI_COLLECTIVE_TAG (-2)

// internal opaque object
struct MPI_Request_impl {
    __device__ MPI_Request_impl(CudaMPI::PendingOperation* pendingOperation) 
        : ref_count(1) 
        , pendingOperation(pendingOperation)
    {}
    
    CudaMPI::PendingOperation* pendingOperation;
    
    int ref_count;
};



namespace gpu_mpi {
    
__device__ void incRequestRefCount(MPI_Request request) {
    assert(request->ref_count > 0);
    request->ref_count++;
}

#undef MPI_TYPES_LIST

} // namespace

__device__ int MPI_Init(int *argc, char ***argv) {
    gpu_mpi::initializeGlobalGroups();
    gpu_mpi::initializeGlobalCommunicators();
    gpu_mpi::initializeOps();
    return MPI_SUCCESS;
}

__device__ int MPI_Init_thread(int *argc, char ***argv, int required, int *provided) {
    (void) required;
    *provided = MPI_THREAD_SINGLE;
    return MPI_Init(argc, argv);
}

__device__ int MPI_Finalize(void) {
    // TODO: due to exit() you need to perform
    // all MPI related memory deallocation here

    // notify host that there will be no messages from this thread anymore
    CudaMPI::sharedState().deviceToHostCommunicator.delegateToHost(0, 0);

    gpu_mpi::destroyGlobalGroups();
    gpu_mpi::destroyGlobalCommunicators();
    
    gpu_mpi::destroyOps();
    
    return MPI_SUCCESS;
}

__device__ int MPI_Get_processor_name(char *name, int *resultlen) {
    const char hardcoded_name[] = "GPU thread";
    __gpu_strcpy(name, hardcoded_name);
    *resultlen = sizeof(hardcoded_name);
    return MPI_SUCCESS;
}

__device__ int MPI_Bcast(void *buffer, int count, MPI_Datatype datatype,
                         int root, MPI_Comm comm)
{
    int dataSize = gpu_mpi::plainTypeSize(datatype) * count;
    assert(dataSize > 0);
    
    int commSize = -1;
    int commRank = -1;
    
    MPI_Comm_size(comm, &commSize);
    MPI_Comm_rank(comm, &commRank);
    
    int tag = MPI_COLLECTIVE_TAG;
    int ctx = gpu_mpi::getCommContext(comm);
    
    if (commRank == root) {
        CudaMPI::PendingOperation** ops = (CudaMPI::PendingOperation**) malloc(sizeof(CudaMPI::PendingOperation*) * commSize);
        assert(ops);
        for (int dst = 0; dst < commSize; dst++) {
            if (dst != commRank) {
                ops[dst] = CudaMPI::isend(dst, buffer, dataSize, ctx, tag);
            }
        }
        for (int dst = 0; dst < commSize; dst++) {
            if (dst != commRank) {
                CudaMPI::wait(ops[dst]);
            }
        }
        free(ops);
    } else {
        CudaMPI::PendingOperation* op = CudaMPI::irecv(root, buffer, dataSize, ctx, tag);
        CudaMPI::wait(op);
    }
    
    return MPI_SUCCESS;
}

__device__ double MPI_Wtime(void) {
    auto clock = clock64();
    double seconds = clock * MPI_Wtick();
    return seconds;
}

__device__ int MPI_Reduce(const void *sendbuf, void *recvbuf, int count,
                          MPI_Datatype datatype, MPI_Op op, int root, MPI_Comm comm)
{
    int commSize = -1;
    int commRank = -1;
    MPI_Comm_size(comm, &commSize);
    MPI_Comm_rank(comm, &commRank);

    int elemSize = gpu_mpi::plainTypeSize(datatype);
    int dataSize = elemSize * count;
    assert(dataSize > 0);
    
    int tag = MPI_COLLECTIVE_TAG;
    int ctx = gpu_mpi::getCommContext(comm);
    
    if (commRank == root) {
        auto ops = (CudaMPI::PendingOperation**) malloc(sizeof(CudaMPI::PendingOperation*) * commSize);
        void* buffers = malloc(dataSize * commSize);
        assert(ops);
        for (int src = 0; src < commSize; src++) {
            if (src != commRank) {
                ops[src] = CudaMPI::irecv(src, ((char*)buffers) + src * dataSize, dataSize, ctx, tag);
            }
        }
        for (int src = 0; src < commSize; src++) {
            const void* tempbuf = nullptr;
            if (src != commRank) {
                CudaMPI::wait(ops[src]);
                tempbuf = ((char*)buffers) + src * dataSize;
            } else {
                tempbuf = sendbuf;
            }
            
            if (src == 0) {
                for (int i = 0; i < dataSize; i++) {
                    ((char*)recvbuf)[i] = ((char*)tempbuf)[i];
                }
            } else {
                gpu_mpi::invokeOperator(op, tempbuf, recvbuf, &count, &datatype);
            }
        }
        
        free(buffers);
        free(ops);
    } else {
        CudaMPI::PendingOperation* op = CudaMPI::isend(root, sendbuf, dataSize, ctx, tag);
        CudaMPI::wait(op);
    }
    
    return MPI_SUCCESS;
}

__device__ int MPI_Type_contiguous(int count, MPI_Datatype oldtype, MPI_Datatype *newtype) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Type_commit(MPI_Datatype *datatype) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Recv(void *buf, int count, MPI_Datatype datatype,
                        int source, int tag, MPI_Comm comm, MPI_Status *status) {
    MPI_Request request;
    MPI_Irecv(buf, count, datatype, source, tag, comm, &request);
    MPI_Wait(&request, MPI_STATUS_IGNORE);
    return MPI_SUCCESS;
}

__device__ int MPI_Sendrecv(const void *sendbuf, int sendcount, MPI_Datatype sendtype,
            int dest, int sendtag, void *recvbuf, int recvcount,
            MPI_Datatype recvtype, int source, int recvtag,
                 MPI_Comm comm, MPI_Status *status) {
    return MPI_SUCCESS;
}

__device__ int MPI_Send(const void *buf, int count, MPI_Datatype datatype, int dest,
            int tag, MPI_Comm comm)
{
    MPI_Request request;
    MPI_Isend(buf, count, datatype, dest, tag, comm, &request);
    MPI_Wait(&request, MPI_STATUS_IGNORE);
    return MPI_SUCCESS;
}

__device__ double MPI_Wtick() {
    int peakClockKHz = CudaMPI::threadPrivateState().peakClockKHz;
    return 0.001 / peakClockKHz;
}

__device__ int MPI_Allreduce(const void *sendbuf, void *recvbuf, int count,
                         MPI_Datatype datatype, MPI_Op op, MPI_Comm comm)
{
    int err = MPI_Reduce(sendbuf, recvbuf, count, datatype, op, 0, comm);
    if (err != MPI_SUCCESS) return err;
    return MPI_Bcast(recvbuf, count, datatype, 0, comm);
}
__device__ int MPI_Abort(MPI_Comm comm, int errorcode) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Type_size(MPI_Datatype datatype, int *size) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Gather(const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                          void *recvbuf, int recvcount, MPI_Datatype recvtype, int root,
                          MPI_Comm comm)
{
    int comm_size = -1;
    int comm_rank = -1;
    MPI_Comm_size(comm, &comm_size);
    MPI_Comm_rank(comm, &comm_rank);

    int sendElemSize = gpu_mpi::plainTypeSize(sendtype);
    int recvElemSize = gpu_mpi::plainTypeSize(recvtype);
    assert(sendElemSize > 0);
    assert(recvElemSize > 0);

    assert(sendElemSize * sendcount == recvElemSize * recvcount);
    int dataSize = sendElemSize * sendcount;

    if (comm_rank != root) {
        MPI_Send(sendbuf, sendcount, sendtype, root, MPI_COLLECTIVE_TAG, comm);
    } else {
        for (int r = 0; r < comm_size; r++) {
            if (r == root) {
                memcpy(((char*)recvbuf) + r * dataSize, sendbuf, dataSize);
            } else {
                MPI_Recv(((char*)recvbuf) + r * dataSize, recvcount, recvtype, r, MPI_COLLECTIVE_TAG, comm, MPI_STATUS_IGNORE);
            }
        }
    }
    
    return MPI_SUCCESS;
}

__device__ int MPI_Barrier(MPI_Comm comm) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Alltoall(const void *sendbuf, int sendcount,
            MPI_Datatype sendtype, void *recvbuf, int recvcount,
            MPI_Datatype recvtype, MPI_Comm comm) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Alltoallv(const void *sendbuf, const int sendcounts[],
            const int sdispls[], MPI_Datatype sendtype,
            void *recvbuf, const int recvcounts[],
            const int rdispls[], MPI_Datatype recvtype, MPI_Comm comm) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Allgather(const void *sendbuf, int  sendcount,
             MPI_Datatype sendtype, void *recvbuf, int recvcount,
             MPI_Datatype recvtype, MPI_Comm comm)
{
    MPI_Gather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, 0, comm);
    int comm_size = -1;
    MPI_Comm_size(comm, &comm_size);
    MPI_Bcast(recvbuf, recvcount * comm_size, recvtype, 0, comm);
    return MPI_SUCCESS;
}

__device__ int MPI_Allgatherv(const void *sendbuf, int sendcount,
                              MPI_Datatype sendtype, void *recvbuf, const int recvcounts[],
                              const int displs[], MPI_Datatype recvtype, MPI_Comm comm)
{
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Gatherv(const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                           void *recvbuf, const int recvcounts[], const int displs[], MPI_Datatype recvtype,
                           int root, MPI_Comm comm) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Scatter(const void *sendbuf, int sendcount, MPI_Datatype sendtype,
                           void *recvbuf, int recvcount, MPI_Datatype recvtype, int root,
                           MPI_Comm comm)
{
    int comm_size = -1;
    int comm_rank = -1;
    MPI_Comm_size(comm, &comm_size);
    MPI_Comm_rank(comm, &comm_rank);

    int sendElemSize = gpu_mpi::plainTypeSize(sendtype);
    int recvElemSize = gpu_mpi::plainTypeSize(recvtype);
    assert(sendElemSize > 0);
    assert(recvElemSize > 0);

    assert(sendElemSize * sendcount == recvElemSize * recvcount);
    int dataSize = sendElemSize * sendcount;

    if (comm_rank != root) {
        MPI_Recv(recvbuf, recvcount, recvtype, root, MPI_COLLECTIVE_TAG, comm, MPI_STATUS_IGNORE);
    } else {
        for (int r = 0; r < comm_size; r++) {
            if (r == root) {
                memcpy(recvbuf, ((char*)sendbuf) + r * dataSize, dataSize);
            } else {
                MPI_Send(((char*)sendbuf) + r * dataSize, sendcount, sendtype, r, MPI_COLLECTIVE_TAG, comm);
            }
        }
    }
    
    return MPI_SUCCESS;
}

__device__ int MPI_NULL_COPY_FN(MPI_Comm oldcomm, int keyval,
                     void *extra_state, void *attribute_val_in,
                     void *attribute_val_out, int *flag) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_NULL_DELETE_FN(MPI_Comm comm, int keyval,
                       void *attribute_val, void *extra_state) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Keyval_create(MPI_Copy_function *copy_fn,
                                 MPI_Delete_function *delete_fn, int *keyval, void *extra_state) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Dims_create(int nnodes, int ndims, int dims[]) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Irecv(void *buf, int count, MPI_Datatype datatype,
               int source, int tag, MPI_Comm comm, MPI_Request *request)
{
    int ctx = gpu_mpi::getCommContext(comm);
    
    int dataSize = gpu_mpi::plainTypeSize(datatype) * count;
    assert(dataSize > 0);
    
    CudaMPI::PendingOperation* op = CudaMPI::irecv(source, buf, dataSize, ctx, tag);
    
    if (request) {
        *request = new MPI_Request_impl(op);
    }
    
    return MPI_SUCCESS;
}
__device__ int MPI_Isend(const void *buf, int count, MPI_Datatype datatype, int dest,
                         int tag, MPI_Comm comm, MPI_Request *request) 
{
    int ctx = gpu_mpi::getCommContext(comm);
    
    int dataSize = gpu_mpi::plainTypeSize(datatype) * count;
    assert(dataSize > 0);
    
    CudaMPI::PendingOperation* op = CudaMPI::isend(dest, buf, dataSize, ctx, tag);
    
    *request = new MPI_Request_impl(op);
    return MPI_SUCCESS;
}

__device__ int MPI_Testall(int count, MPI_Request array_of_requests[],
            int *flag, MPI_Status array_of_statuses[]) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Waitall(int count, MPI_Request array_of_requests[],
            MPI_Status *array_of_statuses) {
    for (int i = 0; i < count; i++) {
        MPI_Wait(&array_of_requests[i], &array_of_statuses[i]);
    }
    return MPI_SUCCESS;
}

__device__ int MPI_Initialized(int *flag) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}

__device__ int MPI_Waitsome(int incount, MPI_Request array_of_requests[],
            int *outcount, int array_of_indices[],
            MPI_Status array_of_statuses[]) {
    NOT_IMPLEMENTED;
    return MPI_SUCCESS;
}
__device__ int MPI_Wait(MPI_Request *request, MPI_Status *status) {
    if (request == MPI_REQUEST_NULL) {
        if (status) *status = MPI_Status();
    }
    
    CudaMPI::wait((*request)->pendingOperation);
    MPI_Request_free(request);
    if (status) *status = MPI_Status();
    return MPI_SUCCESS;
}



__device__ int MPI_Request_free(MPI_Request *request) {
    assert((*request)->ref_count > 0);
    (*request)->ref_count--;
    if ((*request)->ref_count == 0) delete *request;
    *request = MPI_REQUEST_NULL;
    return MPI_SUCCESS;
}





