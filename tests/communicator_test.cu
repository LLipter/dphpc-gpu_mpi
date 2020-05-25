#include "test_runner.cuh"

#include "mpi.h.cuh"

struct CommunicatorTest {
    static __device__ void run(bool& ok) {
        ok = true;
        
        MPI_CHECK_DEVICE(MPI_Init(nullptr, nullptr));
        
        int rank = 0;
        
        MPI_CHECK_DEVICE(MPI_Comm_rank(MPI_COMM_WORLD, &rank));
        
        ok = (rank == cg::this_grid().thread_rank());
        
        MPI_CHECK_DEVICE(MPI_Finalize());
        
    }
};

TEST_CASE("Communicator test", "[comm test]") {
    TestRunner testRunner(5);
    testRunner.run<CommunicatorTest>();
}

struct CommunicatorSendRecvTest {
    static __device__ void run(bool& ok) {
        ok = true;
        
        MPI_CHECK_DEVICE(MPI_Init(nullptr, nullptr));
        
        int rank = 0;
        
        MPI_CHECK_DEVICE(MPI_Comm_rank(MPI_COMM_WORLD, &rank));

        MPI_Comm comm1, comm2, comm3;
        MPI_Comm_dup(MPI_COMM_WORLD, &comm1);
        MPI_Comm_dup(MPI_COMM_WORLD, &comm2);
        MPI_Comm_dup(comm2, &comm3);

        MPI_Request request[3];

        int16_t data[30] = {};

        if (rank == 0) {
            for (int i = 0; i < 30; i++) {
                data[i] = i + 1;
            }
            MPI_Isend(data +  0, 10, MPI_INT16_T, 1, 17, comm1, &request[0]);
            MPI_Irecv(data + 10, 10, MPI_INT16_T, 1, 17, comm2, &request[1]);
            MPI_Isend(data + 20, 10, MPI_INT16_T, 1, 17, comm3, &request[2]);
        } else if (rank == 1) {
            for (int i = 0; i < 30; i++) {
                data[i] = - (i + 1);
            }
            MPI_Irecv(data + 20, 10, MPI_INT16_T, 0, 17, comm3, &request[2]);
            MPI_Irecv(data +  0, 10, MPI_INT16_T, 0, 17, comm1, &request[0]);
            MPI_Isend(data + 10, 10, MPI_INT16_T, 0, 17, comm2, &request[1]);
        }

        MPI_Status status[3];
        MPI_Waitall(3, request, status);
        
        if (rank == 0) {
            for (int i = 10; i < 20; i++) {
                ok = ok && (data[i] == - (i + 1));
            }
        } else if (rank == 1) {
            for (int i = 0; i < 10; i++) {
                ok = ok && (data[i] == i + 1);
            }
            for (int i = 20; i < 30; i++) {
                ok = ok && (data[i] == i + 1);
            }
        }

        MPI_Comm_free(&comm1);
        MPI_Comm_free(&comm2);
        MPI_Comm_free(&comm3);

        MPI_CHECK_DEVICE(MPI_Finalize());
        
    }
};

TEST_CASE("CommunicatorSendRecvTest", "[comm send recv test]") {
    TestRunner testRunner(2);
    testRunner.run<CommunicatorSendRecvTest>();
}
