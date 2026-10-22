// FrameStore: the latest frame from the Vitrine agent, read from \\.\pipe\vitrine-camera on a
// thread of its own and shared by the source's streams.
#pragma once

#include "common.h"

#include <cstdint>

namespace vc {

class FrameStore {
public:
    // Starts the reader thread; nullptr when out of memory.
    static FrameStore* create();

    void AddRef() { InterlockedIncrement(&refs_); }
    void Release() {
        if (InterlockedDecrement(&refs_) == 0) delete this;
    }

    // Ends the reader thread (it disconnects from the pipe); further frames are dropped.
    void stop();

    // Calls fn(yuyv, width, height) on the latest frame, holding it against replacement, and
    // returns true; returns false without calling fn when there is none (not connected, or the
    // agent went away). *seq gets the frame's sequence number either way.
    template <class Fn>
    bool withFrame(uint64_t* seq, Fn fn) {
        AcquireSRWLockShared(&lock_);
        *seq = seq_;
        bool have = width_ != 0;
        if (have) fn(frame_, width_, height_);
        ReleaseSRWLockShared(&lock_);
        return have;
    }

    // Waits up to ms for the sequence number to move past seen (a new frame, or the agent going
    // away), returning early when *cancel becomes nonzero and wake() is called.
    void waitForFrame(uint64_t seen, DWORD ms, const volatile LONG* cancel);
    void wake();

private:
    FrameStore() = default;
    ~FrameStore();
    static DWORD WINAPI readerMain(void* self);
    void readLoop();
    bool readExact(HANDLE pipe, OVERLAPPED& ov, uint8_t* p, size_t n);
    void publish(uint32_t width, uint32_t height);
    void clear();

    ModuleObject counted_;
    volatile LONG refs_ = 1;
    SRWLOCK lock_ = SRWLOCK_INIT;
    CONDITION_VARIABLE changed_ = CONDITION_VARIABLE_INIT;
    // Published frame (read by streams under lock_) and the reader's staging buffer; swapped on
    // each complete frame.
    uint8_t* frame_ = nullptr;
    size_t frameCap_ = 0;
    uint32_t width_ = 0, height_ = 0;
    uint64_t seq_ = 0;
    uint8_t* staging_ = nullptr;
    size_t stagingCap_ = 0;
    HANDLE stopEvent_ = nullptr;
};

}  // namespace vc
