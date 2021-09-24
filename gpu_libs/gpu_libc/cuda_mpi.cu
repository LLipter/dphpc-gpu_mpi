#include "cuda_mpi.cuh"

#ifdef ENABLE_GPU_MPI_LOG
#define LOG(fmt, ...) printf("Thread %d " __FILE__ ":%d " fmt "\n", threadIdx.x + blockDim.x * blockIdx.x, __LINE__,## __VA_ARGS__)
#else
#define LOG(fmt, ...)
#endif

#include "common.h"

namespace CudaMPI {

// this pointer should be initialized before executing any other functions
// size of this array should be equal to the number of launched threads
// on this device
__device__ SharedState* gSharedState = nullptr;

__device__ SharedState& sharedState() {
    assert(gSharedState != nullptr);
    return *gSharedState;
};

__device__ void setSharedState(SharedState* sharedState) {
    if (sharedState->gridRank() == 0) {
        VOLATILE(gSharedState) = sharedState;
    }
    sharedState->gridBarrier();
}

__device__ PendingOperation* ThreadPrivateState::allocatePendingOperation() {
    if (pendingOperations.full()) return nullptr;
    int insertedIndex = pendingOperations.push(PendingOperation());
    return &pendingOperations.get(insertedIndex);
}

__device__ ThreadPrivateState* gThreadLocalState = nullptr;

__device__ ThreadPrivateState& threadPrivateState() {
    __gpu_assert(gThreadLocalState);
    int gridIdx = sharedState().gridRank();
    return gThreadLocalState[gridIdx];
}

__device__ ThreadPrivateState::Holder::Holder(const Context& ctx) {
    assert(ctx.valid());
    LOG("initializeThreadPrivateState");
    if (0 == sharedState().gridRank()) {
        gThreadLocalState = (ThreadPrivateState*)malloc(sharedState().activeGridSize() * sizeof(ThreadPrivateState));
        assert(gThreadLocalState);
        //__threadfence_system(); // not required anymore, barrier makes sure this change is visible before
    }
    sharedState().gridBarrier();
    new (&threadPrivateState()) ThreadPrivateState(ctx);
}

__device__ ThreadPrivateState::Holder::~Holder() {
    LOG("destroyThreadPrivateState");
    threadPrivateState().~ThreadPrivateState();
    sharedState().gridBarrier();
    if (0 == sharedState().gridRank()) {
        free(gThreadLocalState);
    }
}

__device__ PendingOperation* isend(int dst, const void* data, int count, int ctx, int tag, bool synchronous, bool buffered) {
    LOG("isend");
    PendingOperation* po = threadPrivateState().allocatePendingOperation();
    while (!po) {
        po = threadPrivateState().allocatePendingOperation();
        printf("WARNING: Pending operations limit is reached in isend, this can cause a deadlock\n");
        progress();
    }

    po->type = PendingOperation::Type::SEND;
    po->state = PendingOperation::State::STARTED;
    po->otherThread = dst;
    po->count = count;
    po->ctx = ctx;
    po->tag = tag;
    po->isSynchronous = synchronous;
    po->isBuffered = buffered;
    po->canBeFreed = false;
    po->data = (void*)data;
    po->buffer = nullptr;
    po->done = false;

    progress();

    return po;
}

__device__ PendingOperation* irecv(int src, void* data, int count, int ctx, int tag) {
    LOG("irecv");

    PendingOperation* po = threadPrivateState().allocatePendingOperation();
    while (!po) {
        po = threadPrivateState().allocatePendingOperation();
        LOG("WARNING: Pending operations limit is reached in irecv, this can cause a deadlock\n");
        progress();
    }

    po->type = PendingOperation::Type::RECV;
    po->state = PendingOperation::State::STARTED;
    po->otherThread = src;
    po->count = count;
    po->ctx = ctx;
    po->tag = tag;
    po->isSynchronous = false; // this flag is not used for receive operation
    po->isBuffered = false;
    po->canBeFreed = false;
    po->data = data;
    po->buffer = nullptr;
    po->done = false;

    progress();

    return po;
}

__device__ void progressStartedSend(PendingOperation& send, ProgressState& state) {
    LOG("progressStartedSend() %p", &send);
    SharedThreadState& otherThreadState = sharedState().sharedThreadState[send.otherThread];
    
    if (state.isStartedSendSkip(send.otherThread)) {
        LOG("Skip send, because some earlier started send is not processed");
        return;
    }
    
    auto startedSkipGuard = makeScopeGuard([&state,&send](){ 
        state.markStartedSendSkip(send.otherThread); 
    });

    int src = sharedState().gridRank();

    LOG("Trying to lock state of other process");
    if (!otherThreadState.recvLock.tryLock()) {
        LOG("Failed to lock state of other process");
        return;
    }
    LOG("State of other process is locked");

    auto& uq = otherThreadState.unexpectedRecv;
    auto& rq = otherThreadState.expectedRecv;

    MessageDescriptor* matchedRecv = nullptr;

    LOG("Trying to find matching send in the list of expected receives of other process");
    for (MessageDescriptor* md = rq.head(); md != nullptr; md = rq.next(md)) {
        if (md->src != ANY_SRC && md->src != src) continue;
        if (md->ctx != send.ctx) continue;
        if (md->tag != ANY_TAG && md->tag != send.tag) continue;
        // if we are here then "md" matches "send"
        matchedRecv = md;
        LOG("Matching receive is found, src: %d (this thread), dst: %d, count: %d", md->src, send.otherThread, send.count);
        break;
    }

    if (matchedRecv) {
        // extract important fields
        void* otherData = matchedRecv->data;
        assert(matchedRecv->done);
        volatile bool& done = *(matchedRecv->done);
           
        LOG("Remove receive from the list of expected receives of other process");
        rq.pop(matchedRecv);

        LOG("Sender performs data transfer from %p to %p", send.data, otherData);
        memcpy(otherData, send.data, send.count);

        LOG("Notify receiver that data is copied");
        done = true;
        cudaGlobalFence();

        LOG("Change state to COMPLETED");
        send.state = PendingOperation::State::COMPLETED;
    } else {
        LOG("Matching receive is not found, post send in unexpected receives of other process");

        if (uq.full()) {
            LOG("List of unexpected receives is full, retry later");
        } else {

            if (!__isGlobal(send.data)) {
                LOG("Sender fallbacks to buffered send because data is not in global memory");
                send.isBuffered = true;
            }
            if (send.isBuffered) {
                void* buffer = malloc(send.count);
                assert(buffer);
                LOG("Sender allocated buffer %p that receiver will have to deallocate", buffer);
                LOG("Sender performs data transfer from %p to temp buffer %p", send.data, buffer);
                memcpy(buffer, send.data, send.count); 
                send.data = buffer;
            } else {
            }

            MessageDescriptor md;
            md.ctx = send.ctx;
            md.src = sharedState().gridRank();
            md.tag = send.tag;
            md.buffered = send.isBuffered;
            md.data = send.data;
            md.done = send.isSynchronous ? &send.done : nullptr;
            uq.push(md);

            if (send.isSynchronous) {
                LOG("Change state to POSTED");
                send.state = PendingOperation::State::POSTED;
            } else {
                LOG("Change state to COMPLETED");
                send.state = PendingOperation::State::COMPLETED;
            }
        }
    }
    
    LOG("Unlock state of other process");
    otherThreadState.recvLock.unlock();

    if (send.state != PendingOperation::State::STARTED) {
        startedSkipGuard.commit();
    }
    
    if (send.state == PendingOperation::State::POSTED) {
        progressPostedSend(send);
    } else if (send.state == PendingOperation::State::COMPLETED) {
        progressCompletedSend(send);
    }
}

__device__ void progressPostedSend(PendingOperation& send) {
    LOG("progressPostedSend() %p", &send);

    if (send.done) {
        send.state = PendingOperation::State::COMPLETED;
        LOG("Receiver matched our message");
    } else {
        LOG("Receiver is not matched this send yet, skip it");
    }
    
    if (send.state == PendingOperation::State::COMPLETED) {
        progressCompletedSend(send);
    }
}

__device__ void progressCompletedSend(PendingOperation& send) {
    LOG("progressCompletedSend %p", &send);

    if (send.canBeFreed) {
        LOG("freeing local send operation");
        threadPrivateState().getPendingOperations().pop(&send);
    }
}


__device__ void progressSend(PendingOperation& send, ProgressState& state) {
    LOG("progressSend() %p", &send);

    switch (send.state) {
        case PendingOperation::State::STARTED:
            progressStartedSend(send, state);
            break;
        case PendingOperation::State::POSTED:
            progressPostedSend(send);
            break;
        case PendingOperation::State::COMPLETED:
            progressCompletedSend(send);
            break;
    }
}

__device__ void progressStartedRecv(PendingOperation& recv, ProgressState& state) {
    LOG("progressStartedRecv() %p", &recv);

    int dst = sharedState().gridRank();
    
    if (state.isStartedRecvSkip(recv.otherThread)) {
        LOG("Skip recv, because some earlier started recv is not processed");
        return;
    }
    
    auto startedSkipGuard = makeScopeGuard([&state,&recv](){ 
        state.markStartedRecvSkip(recv.otherThread); 
    });

    SharedThreadState& currentThreadState = sharedState().sharedThreadState[dst];

    LOG("Trying to take lock for shared thread state of current thread");
    if (!currentThreadState.recvLock.tryLock()) {
        LOG("Failed to take lock");
        return;
    }
    LOG("Lock is taken successfully");

    auto& uq = currentThreadState.unexpectedRecv;
    auto& rq = currentThreadState.expectedRecv;

    MessageDescriptor* matchedSend = nullptr;

    LOG("Trying to find message in the list of unexpected messages");
    for (MessageDescriptor* md = uq.head(); md != nullptr; md = uq.next(md)) {
        if (md->src != recv.otherThread) continue;
        if (md->ctx != recv.ctx) continue;
        if (md->tag != recv.tag) continue;
        // if we are here then "md" matches "recv"
        LOG("Message is found in unexpected list");
        matchedSend = md;
        break;
    }

    if (matchedSend) {
        if (matchedSend->done) {
            *matchedSend->done = true;
            cudaGlobalFence();
        }

        void* otherData = matchedSend->data;
        bool buffered = matchedSend->buffered;
        
        LOG("Remove message from list of unexpected messages");
        uq.pop(matchedSend);

        LOG("Receiver copies data from %p to %p", otherData, recv.data);
        memcpy(recv.data, otherData, recv.count);

        LOG("Receiver releases buffer allocated by sender");
        if (buffered) {
            free(otherData);
        }

        LOG("Change state to COMPLETED");
        recv.state = PendingOperation::State::COMPLETED;
    } else {
        LOG("Add message to the list of expected receives of current thread");
        
        if (rq.full()) {
            LOG("List of expected receives is full, retry later");
        } else {
            if (!__isGlobal(recv.data)) {
                LOG("Receiver array is not in global memory, buffer is required");
                recv.isBuffered = true;
            } else {
                LOG("Receiver array in global memory, buffer is not required");
            }

            if (recv.isBuffered) {
                LOG("Receiver allocates buffer");
                recv.buffer = malloc(recv.count);
                assert(recv.buffer);
            }

            MessageDescriptor md;
            md.ctx = recv.ctx;
            md.src = recv.otherThread;
            md.tag = recv.tag;
            md.buffered = false; // it doesn't matter for receiver
            md.data = recv.isBuffered ? recv.buffer : recv.data;
            md.done = &recv.done;
            rq.push(md);

            LOG("Change state to POSTED");
            recv.state = PendingOperation::State::POSTED;
        }
    }

    LOG("Unlock shared state of current thread");
    currentThreadState.recvLock.unlock();

    if (recv.state != PendingOperation::State::STARTED) {
        startedSkipGuard.commit();
    }
    
    if (recv.state == PendingOperation::State::POSTED) {
        progressPostedRecv(recv);
    }
}


__device__ void progressPostedRecv(PendingOperation& recv) {
    LOG("progressPostedRecv() %p", &recv);

    if (recv.done) {

        if (recv.isBuffered) {
            LOG("Receiver copies data from buffer into local array and frees the buffer");
            memcpy(recv.data, recv.buffer, recv.count);
            free(recv.buffer);
        } else {
            LOG("Receiver got signal from sender that copy completed");
        }

        LOG("Receiver changes state to COMPLETED");
        recv.state = PendingOperation::State::COMPLETED;
    }

    if (recv.state == PendingOperation::State::COMPLETED) {
        progressCompletedRecv(recv);
    }
}

__device__ void progressCompletedRecv(PendingOperation& recv) {
    LOG("progressCompletedRecv %p", &recv);
    
    if (recv.canBeFreed) {
        LOG("freeing local recv operation");
        threadPrivateState().getPendingOperations().pop(&recv);
    }
}


__device__ void progressRecv(PendingOperation& recv, ProgressState& state) {
    LOG("progressRecv() %p", &recv);

    switch (recv.state) {
        case PendingOperation::State::STARTED:
            progressStartedRecv(recv, state);
            break;
        case PendingOperation::State::POSTED:
            progressPostedRecv(recv);
            break;
        case PendingOperation::State::COMPLETED:
            progressCompletedRecv(recv);
            break;
    }
}

__host__ __device__ void progress() {
    // this function is no op on host
#if defined(__CUDA_ARCH__)
    LOG("progress()");

    ProgressState progressState;
    
    auto& pops = threadPrivateState().getPendingOperations();
    for (PendingOperation* ptr = pops.head(); ptr != nullptr; ptr = pops.next(ptr)) {
        PendingOperation& pop = *ptr;
        switch (pop.type) {
            case PendingOperation::Type::SEND:
                progressSend(pop, progressState);
                break;
            case PendingOperation::Type::RECV:
                progressRecv(pop, progressState);
                break;
        }
    }
#endif
}

__device__ bool test(PendingOperation* op) {
    LOG("test()");
    assert(op->canBeFreed == false);
    progress();
    if (op->state == PendingOperation::State::COMPLETED) {
        op->canBeFreed = true;
        switch (op->type) {
            case PendingOperation::Type::SEND:
                progressCompletedSend(*op);
                break;
            case PendingOperation::Type::RECV:
                progressCompletedRecv(*op);
                break;
        }
        return true;
    }
    return false;
}

__device__ void wait(PendingOperation* op) {
    LOG("wait()");
    assert(op->canBeFreed == false);
    while (!test(op)) {}
}


DeviceToHostCommunicator::DeviceToHostCommunicator(size_t queueSize, size_t numThreads)
    : queue(queueSize)
    , hostFinished(numThreads, false)
{
}

__device__ void DeviceToHostCommunicator::delegateToHost(void* ptr, size_t size) {
    int threadRank = sharedState().gridRank();
    assert(hostFinished[threadRank] == false);

    while (true) {

        while (!lock.tryLock()) {
            progress();
        }

        auto unlockGuard = makeScopeGuard([&](){ lock.unlock(); });

        if (queue.full()) {
            lock.unlock();
            unlockGuard.commit();

            progress();
        } else {
            queue.push(Message(ptr, size, threadRank));

            break;
        }
    }

    // waiting for host
    while (!hostFinished[threadRank]) {
        progress();
    }

    hostFinished[threadRank] = false;
}


FreeManagedMemory::FreeManagedMemory(size_t size)
    : buffer(size)
{
    assert(buffer.size() > sizeof(BlockDescriptor));
    BlockDescriptor* memBlock = (BlockDescriptor*)(&buffer[0]);
    memBlock->status = FREE;
    memBlock->end = buffer.size();
}

__host__ __device__ void* FreeManagedMemory::allocate(size_t size) {
    while (!lock.tryLock()) {
        progress();
    }

    auto unlockGuard = makeScopeGuard([&](){ lock.unlock(); });

    size_t blockStart = 0;
    while (true) {
        BlockDescriptor* memBlock = (BlockDescriptor*)(&buffer[blockStart]);
        size_t blockDataStart = blockStart + sizeof(BlockDescriptor);
        assert(memBlock->end > blockStart);
        size_t blockUsefulSize = memBlock->end - blockStart;

        compactionWithNextBlocks(blockStart);

        if (memBlock->status == FREE && blockUsefulSize >= size) {
            // allocate block
            size_t blockSizeLeft = blockUsefulSize - size;
            if (blockSizeLeft <= sizeof(BlockDescriptor)) {
                // utilize all memory since it will not be possibe to use it anyway
                memBlock->status = USED;
                return (void*) &buffer[blockDataStart];
            } else {
                // normal allocation, split buffer into two parts: first is allocated, the second is free
                size_t newBlockEnd = blockDataStart + size;

                // second free block
                BlockDescriptor* newFreeBlock = (BlockDescriptor*)(&buffer[newBlockEnd]);
                newFreeBlock->status = FREE;
                newFreeBlock->end = memBlock->end;

                // first used block
                memBlock->status = USED;
                memBlock->end = newBlockEnd;
            }
        }

        blockStart = memBlock->end;

        assert(blockStart <= buffer.size());

        if (blockStart == buffer.size()) {
            return nullptr;
        }
    }
}

__host__ __device__ void FreeManagedMemory::free(void* ptr) {
    while (!lock.tryLock()) {
        progress();
    }

    auto unlockGuard = makeScopeGuard([&](){ lock.unlock(); });

    assert(&buffer[0] <= ptr);
    size_t pos = ((char*)ptr) - &buffer[0];
    assert(pos < buffer.size());

    BlockDescriptor* memBlock = (BlockDescriptor*)(&ptr);
    assert(memBlock->status == USED);

    memBlock->status = FREE;
}

__host__ __device__ void FreeManagedMemory::compactionWithNextBlocks(size_t currentBlock) {
    BlockDescriptor* current = (BlockDescriptor*)(&buffer[currentBlock]);

    while (true) {
        size_t nextBlock = current->end;
        assert(nextBlock <= buffer.size());

        if (nextBlock == buffer.size()) break;

        BlockDescriptor* next = (BlockDescriptor*)(&buffer[nextBlock]);
        if (next->status == USED) break;

        assert(next->status == FREE);

        current->end = next->end;
    }
}

} // namespace
