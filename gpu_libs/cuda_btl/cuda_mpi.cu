#include "cuda_mpi.cuh"

#ifdef ENABLE_GPU_MPI_LOG
#define LOG(fmt, ...) printf("Thread %d " __FILE__ ":%d " fmt "\n", cg::this_grid().thread_rank(), __LINE__,## __VA_ARGS__)
#else
#define LOG(fmt, ...)
#endif

#define ALIVE LOG("STILL ALIVE!");

__device__ void memcpy_volatile(volatile void *dst, volatile void *src, size_t n)
{
    volatile char *d = (volatile char*) dst;
    volatile char *s = (volatile char*) src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

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
    if (cg::this_grid().thread_rank() == 0) {
        VOLATILE(gSharedState) = sharedState;
    }
    cg::this_grid().sync();
}

__device__ PendingOperation* ThreadPrivateState::allocatePendingOperation() {
    for (int i = 0; i < pendingOperations.size(); i++) {
        PendingOperation& op = pendingOperations[i];
        if (op.unused) {
            op.unused = false;
            return &op;
        }
    }
    return nullptr;
}

__device__ ThreadPrivateState* gThreadLocalState = nullptr;

__device__ ThreadPrivateState& threadPrivateState() {
    assert(gThreadLocalState != nullptr);
    int gridIdx = cg::this_grid().thread_rank();
    return gThreadLocalState[gridIdx];
}

__device__ ThreadPrivateState::Holder::Holder(const Context& ctx) {
    LOG("initializeThreadPrivateState");
    if (0 == cg::this_grid().thread_rank()) {
        VOLATILE(gThreadLocalState) = (ThreadPrivateState*)malloc(cg::this_grid().size() * sizeof(ThreadPrivateState));
    }
    cg::this_grid().sync();
    new (&threadPrivateState()) ThreadPrivateState(ctx);
}

__device__ ThreadPrivateState::Holder::~Holder() {
    LOG("destroyThreadPrivateState");
    threadPrivateState().~ThreadPrivateState();
    cg::this_grid().sync();
    if (0 == cg::this_grid().thread_rank()) {
        free(gThreadLocalState);
    }
}

__device__ PendingOperation* isend(int dst, const void* data, int count, int comm, int tag) {
    LOG("isend");
    PendingOperation* po = threadPrivateState().allocatePendingOperation();
    while (!po) {
        po = threadPrivateState().allocatePendingOperation();
        LOG("WARNING: Pending operations limit is reached, isend can be blocked\n");
        progress();
    }

    po->type = PendingOperation::Type::SEND;
    po->state = PendingOperation::State::STARTED;
    po->fragment = nullptr;
    po->otherThread = dst;
    po->data = (void*) data;
    po->count = count;
    po->comm = comm;
    po->tag = tag;
    po->unused = false;

    progress();

    return po;
}

__device__ PendingOperation* irecv(int src, void* data, int count, int comm, int tag) {
    LOG("irecv");

    PendingOperation* po = threadPrivateState().allocatePendingOperation();
    while (!po) {
        po = threadPrivateState().allocatePendingOperation();
        LOG("WARNING: Pending operations limit is reached, irecv can be blocked\n");
        progress();
    }

    po->type = PendingOperation::Type::RECV;
    po->state = PendingOperation::State::STARTED;
    po->fragment = nullptr;
    po->otherThread = src;
    po->data = data;
    po->count = count;
    po->comm = comm;
    po->tag = tag;
    po->unused = false;

    progress();

    return po;
}

__device__ void progressCompletedRecv(PendingOperation& recv) {
    LOG("progressCompletedRecv");

    LOG("unlocking memory fragment");
    assert(recv.fragment);
    recv.fragment->memoryLock.unlock();
    if (recv.canBeFreed) {
        LOG("freeing local recv operation");
        recv.free();
    }
}

__device__ void progressCompletedSend(PendingOperation& send) {
    LOG("progressCompletedSend");

    if (send.canBeFreed) {
        LOG("freeing local send operation");
        send.free();
    }
}

__device__ void progressAllocatedSend(PendingOperation& send) {
    LOG("progressAllocatedSend()");

    volatile SharedThreadState* threadState = sharedState().sharedThreadState.get(send.otherThread);
    LOG("trying to lock incoming fragments of other thread %d", send.otherThread);
    if (!threadState->fragLock.tryLock()) {
        LOG("fragment lock failed");
        return;
    }
    LOG("fragment lock succeed");

    IncomingFragment fr;
    assert(send.fragment); // fragment should be allocated
    fr.fragment = send.fragment;
    fr.privatePointer = send.foreignPendingOperation;
    LOG("Pointer to foreign pending operation %p", send.foreignPendingOperation);
    assert(send.foreignPendingOperation);
    assert(fr.privatePointer);
    assert(fr.fragment);

    LOG("put fragment %p into list of incoming fragments", fr.fragment);
    threadState->incomingFragments.push(fr);

    LOG("unlocking list of incoming fragments");
    threadState->fragLock.unlock();

    if (send.count == 0) {
        LOG("All buffer data is already inside fragment, change state to COMPLETED");
        send.state = PendingOperation::State::COMPLETED;
        progressCompletedSend(send);
    } else {
        LOG("Change state to SYNCED (fragment now on the other thread)");
        send.state = PendingOperation::State::SYNCED;
        progressSyncedSend(send);
    }
}

__device__ void progressMatchedSend(PendingOperation& send) {
    LOG("progressMatchedSend()");

    LOG("Trying to allocate memory fragment");
    SharedFragmentBuffer& fb = sharedState().sharedFragmentBuffer;
    volatile MemoryFragment* memoryFragment = fb.tryLockFreeFragment();
    if (!memoryFragment) {
        LOG("Memory fragment allocation is failed");
        return;
    }
    LOG("Memory fragment allocation is succeed");

    int copySize = 0;
    void* srcPtr = nullptr;
    LOG("Compare fragment buffer size %d and data size %d", memoryFragment->data.size(), send.count);
    if (memoryFragment->data.size() >= send.count) {
        LOG("Fragment buffer size greater or equal to data size");
        copySize = send.count;
        srcPtr = send.data;
        send.data = nullptr;
        send.count = 0;
        // we can't mark it as completed because other thread didn't received pointer to fragment
    } else {
        LOG("Fragment buffer size less than data size");
        copySize = memoryFragment->data.size();
        srcPtr = send.data;
        send.data = (void*)(((char*)send.data) + copySize);
        send.count -= copySize;
        LOG("Change state to allocated");
        send.state = PendingOperation::State::ALLOCATED;
    }
    LOG("Copying data from local memory into memory fragment");
    memcpy_volatile(memoryFragment->data.get(0), srcPtr, copySize);

    LOG("Transfer ownership of memory fragment to thread %d", send.otherThread);
    memoryFragment->ownerProcess = send.otherThread;

    LOG("Memory fragment of local pending operation is set to %p", memoryFragment);
    send.fragment = memoryFragment;

    send.state = PendingOperation::State::ALLOCATED;
    progressAllocatedSend(send);
}

__device__ void progressStartedSend(PendingOperation& send) {
    LOG("progressStartedSend()");
    volatile SharedThreadState* otherThreadState = sharedState().sharedThreadState.get(send.otherThread);

    int src = cg::this_grid().thread_rank();

    LOG("Trying to lock state of other process");
    if (!otherThreadState->recvLock.tryLock()) {
        LOG("Failed to lock state of other process");
        return;
    }
    LOG("State of other process is locked");

    volatile CircularQueue<MessageDescriptor>& uq = otherThreadState->unexpectedRecv;
    volatile CircularQueue<MessageDescriptor>& rq = otherThreadState->expectedRecv;

    volatile MessageDescriptor* matchedRecv = nullptr;

    LOG("Trying to find matching send in the list of expected receives of other process");
    for (volatile MessageDescriptor* md = rq.head(); md != nullptr; md = rq.next(md)) {
        if (md->src != ANY_SRC && md->src != src) continue;
        if (md->comm != send.comm) continue;
        if (md->tag != ANY_TAG && md->tag != send.tag) continue;
        // if we are here then "md" matches "send"
        matchedRecv = md;
        LOG("Matching receive is found!");
        break;
    }

    if (matchedRecv) {
        LOG("Remove receive from the list of expected receives of other process");
        send.foreignPendingOperation = matchedRecv->privatePointer;
        assert(send.foreignPendingOperation);
        LOG("Pointer to foregin pending operation is %p", send.foreignPendingOperation);
        rq.pop(matchedRecv);
        LOG("Change state to MATCHED");
        send.state = PendingOperation::State::MATCHED;
    } else {
        LOG("Matching receive is not found, post send in unexpected receives of other process");

        MessageDescriptor md;
        md.comm = send.comm;
        md.src = src;
        md.tag = send.tag;
        md.privatePointer = &send;
        uq.push(md);
        LOG("Change state to POSTED");
        send.state = PendingOperation::State::POSTED;
    }

    LOG("Unlock state of other process");
    otherThreadState->recvLock.unlock();

    if (send.state == PendingOperation::State::MATCHED) {
        progressMatchedSend(send);
    } else if (send.state == PendingOperation::State::POSTED) {
        progressPostedSend(send);
    }
}

__device__ void progressPostedSend(PendingOperation& send) {
    LOG("progressPostedSend()");

    if (send.fragment != nullptr) {
        LOG("Fragment is allocated by other thread, change state to SYNCED");
        send.state = PendingOperation::State::SYNCED;
        progressSyncedSend(send);
    } else {
        LOG("Fragment is not allocated by other thread, skip it");
    }
}

__device__ void progressSyncedSend(PendingOperation& send) {
    LOG("progressSyncedSend()");

    LOG("check the owner of shared fragment buffer");
    if (send.fragment->ownerProcess == send.otherThread) {
        LOG("buffer is owned by other thread, skip it");
        return;
    }
    LOG("buffer is owned by me, continue operation");

    int copySize = 0;
    void* srcPtr = nullptr;
    if (send.fragment->data.size() < send.count) {
        LOG("copy next chunk, it is not the last one");
        // a lot of chunks left
        copySize = send.fragment->data.size();
        srcPtr = send.data;
        send.data = (void*)((char*)send.data + copySize);
        send.count -= copySize;
    } else {
        // last chunk
        copySize = send.count;
        srcPtr = send.data;
        send.data = nullptr;
        send.count = 0;
        LOG("copy last chunk, change state to COMPLETED");
        send.state = PendingOperation::State::COMPLETED;
    }
    LOG("copy chunk from local buffer to destionation buffer");
    memcpy_volatile(send.fragment->data.get(0), srcPtr, copySize);

    LOG("transfer ownership of shared fragment to other thread");
    send.fragment->ownerProcess = send.otherThread;

    if (send.state == PendingOperation::State::COMPLETED) {
        progressCompletedSend(send);
    }
}

__device__ void progressSend(PendingOperation& send) {
    LOG("progressSend()");

    switch (send.state) {
        case PendingOperation::State::STARTED:
            progressStartedSend(send);
            break;
        case PendingOperation::State::POSTED:
            progressPostedSend(send);
            break;
        case PendingOperation::State::MATCHED:
            progressMatchedSend(send);
            break;
        case PendingOperation::State::ALLOCATED:
            progressAllocatedSend(send);
            break;
        case PendingOperation::State::SYNCED:
            progressSyncedSend(send);
            break;
        case PendingOperation::State::COMPLETED:
            progressCompletedSend(send);
            break;
    }
}

__device__ void progressStartedRecv(PendingOperation& recv) {
    LOG("progressStartedRecv()");

    int dst = cg::this_grid().thread_rank();

    volatile SharedThreadState* currentThreadState = sharedState().sharedThreadState.get(dst);

    LOG("Trying to take lock for shared thread state of current thread");
    if (!currentThreadState->recvLock.tryLock()) {
        LOG("Failed to take lock");
        return;
    }
    LOG("Lock is taken successfully");

    volatile CircularQueue<MessageDescriptor>& uq = currentThreadState->unexpectedRecv;
    volatile CircularQueue<MessageDescriptor>& rq = currentThreadState->expectedRecv;

    volatile MessageDescriptor* matchedSend = nullptr;

    LOG("Trying to find message in the list of unexpected messages");
    for (volatile MessageDescriptor* md = uq.head(); md != nullptr; md = uq.next(md)) {
        if (md->comm != recv.comm) continue;
        if (md->tag != recv.tag) continue;
        // if we are here then "md" matches "recv"
        LOG("Message is found in unexpected list");
        matchedSend = md;
        break;
    }

    if (matchedSend) {
        LOG("Save pointer to `send` operation of other process");
        recv.foreignPendingOperation = matchedSend->privatePointer;
        LOG("Remove message from list of unexpected messages");
        uq.pop(matchedSend);

        LOG("Change state to MATCHED");
        recv.state = PendingOperation::State::MATCHED;
    } else {
        LOG("Add message to the list of expected receives of current threads");
        MessageDescriptor md;
        md.comm = recv.comm;
        md.src = recv.otherThread;
        md.tag = recv.tag;
        md.privatePointer = &recv;
        rq.push(md);

        LOG("Change state to POSTED");
        recv.state = PendingOperation::State::POSTED;
    }

    LOG("Unlock shared state of current thread");
    currentThreadState->recvLock.unlock();

    if (recv.state == PendingOperation::State::MATCHED) {
        progressMatchedRecv(recv);
    } else if (recv.state == PendingOperation::State::POSTED) {
        progressPostedRecv(recv);
    }
}


__device__ void progressPostedRecv(PendingOperation& recv) {
    LOG("progressPostedRecv()");

    if (recv.fragment != nullptr) {
        LOG("Fragment is allocated by other thread, change state to SYNCED");
        recv.state = PendingOperation::State::SYNCED;
        progressSyncedRecv(recv);
    } else {
        LOG("Fragment is not allocated by other thread, skip it");
    }
}

__device__ void progressMatchedRecv(PendingOperation& recv) {
    LOG("progressMatchedRecv()");

    LOG("Trying lock free memory fragment");
    SharedFragmentBuffer& fb = sharedState().sharedFragmentBuffer;
    volatile MemoryFragment* memoryFragment = fb.tryLockFreeFragment();
    if (!memoryFragment) {
        LOG("Failed to lock memory fragment");
        return;
    }
    LOG("Memory fragment is locked");

    LOG("Transfer ownership of fragment to other thread");
    memoryFragment->ownerProcess = recv.otherThread;

    recv.fragment = memoryFragment;

    LOG("Change state to ALLOCATED");
    recv.state = PendingOperation::State::ALLOCATED;

    progressAllocatedRecv(recv);
}

__device__ void progressAllocatedRecv(PendingOperation& recv) {
    LOG("progressAllocatedRecv()");

    LOG("Trying to lock list of incoming fragments of thread %d", recv.otherThread);
    volatile SharedThreadState* threadState = sharedState().sharedThreadState.get(recv.otherThread);
    if (!threadState->fragLock.tryLock()) {
        LOG("Failed to lock");
        return;
    }
    LOG("Locked successfully");


    IncomingFragment fr;
    fr.fragment = recv.fragment;
    fr.privatePointer = recv.foreignPendingOperation;

    assert(fr.fragment);
    assert(fr.privatePointer);

    LOG("Put new fragment into list of incoming fragments");
    threadState->incomingFragments.push(fr);

    LOG("Unlock list of incoming fragments of other thread %d", recv.otherThread);
    threadState->fragLock.unlock();

    LOG("Change state to SYNCED");
    recv.state = PendingOperation::State::SYNCED;

    progressSyncedRecv(recv);
}

__device__ void progressSyncedRecv(PendingOperation& recv) {
    LOG("progressSyncedRecv()");

    LOG("Check that current thread owns fragment");
    if (recv.fragment->ownerProcess == recv.otherThread) {
        LOG("Fragment is used by other process, skip it");
        return;
    }
    LOG("Fragment is owned by current thread");

    int copySize = 0;
    void* dstPtr = nullptr;
    if (recv.fragment->data.size() < recv.count) {
        LOG("Prepare copy of next chunk");
        // a lot of chunks left
        copySize = recv.fragment->data.size();
        dstPtr = recv.data;
        recv.data = (void*)((char*)recv.data + copySize);
        recv.count -= copySize;
    } else {
        LOG("Prepare copy of last chunk");
        // last chunk
        copySize = recv.count;
        dstPtr = recv.data;
        recv.data = nullptr;
        recv.count = 0;
        LOG("Change state to COMPLETED");
        recv.state = PendingOperation::State::COMPLETED;
    }
    LOG("Copy data from fragment buffer into local memory");
    memcpy_volatile(dstPtr, recv.fragment->data.get(0), copySize);

    LOG("Transfer fragment ownership to other thread");
    recv.fragment->ownerProcess = recv.otherThread;

    if (recv.state == PendingOperation::State::COMPLETED) {
        progressCompletedRecv(recv);
    }
}

__device__ void progressRecv(PendingOperation& recv) {
    LOG("progressRecv()");

    switch (recv.state) {
        case PendingOperation::State::STARTED:
            progressStartedRecv(recv);
            break;
        case PendingOperation::State::POSTED:
            progressPostedRecv(recv);
            break;
        case PendingOperation::State::MATCHED:
            progressMatchedRecv(recv);
            break;
        case PendingOperation::State::ALLOCATED:
            progressAllocatedRecv(recv);
            break;
        case PendingOperation::State::SYNCED:
            progressSyncedRecv(recv);
            break;
        case PendingOperation::State::COMPLETED:
            progressCompletedRecv(recv);
            break;
    }
}

__device__ void receiveFragmentPointers() {
    LOG("receiveFragmentPointers()");

    int curThread = cg::this_grid().thread_rank();
    SharedState& ss = sharedState();
    volatile SharedThreadState* sts = ss.sharedThreadState.get(curThread);

    LOG("Trying to lock list of incoming fragment of current thread");
    if (!sts->fragLock.tryLock()) {
        LOG("Failed to lock");
        return;
    }
    LOG("Locked successfully");

    LOG("Looping over incoming fragments");
    while (!sts->incomingFragments.empty()) {
        volatile IncomingFragment* inFrag = sts->incomingFragments.head();
        assert(inFrag);

        volatile MemoryFragment* frag = inFrag->fragment;
        assert(frag);


        PendingOperation* pop = inFrag->privatePointer;
        LOG("Extract pointer to private pending operation %p", pop);
        assert(pop);

        assert(!pop->fragment);

        LOG("Assign incoming fragment %p to the private pending operation %p", frag, pop);
        pop->fragment = frag;

        LOG("Remove fragment from the list of incoming fragments");
        sts->incomingFragments.pop(inFrag);
    }

    LOG("Unlock list of incoming fragments of current thread");
    sts->fragLock.unlock();
}

__device__ void progress() {
    LOG("progress()");

    receiveFragmentPointers();

    Vector<PendingOperation>& pops = threadPrivateState().getPendingOperations();
    for (int i = 0; i < pops.size(); i++) {
        PendingOperation& pop = pops[i];
        if (!pop.unused) {
            switch (pop.type) {
                case PendingOperation::Type::SEND:
                    progressSend(pop);
                    break;
                case PendingOperation::Type::RECV:
                    progressRecv(pop);
                    break;
            }
        }
    }
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

} // namespace
