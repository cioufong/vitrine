#include "frames.h"

#include "convert.h"

#include <cstdlib>

namespace vc {

FrameStore* FrameStore::create() {
    FrameStore* s = new (std::nothrow) FrameStore();
    if (!s) return nullptr;
    s->stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!s->stopEvent_) {
        s->Release();
        return nullptr;
    }
    s->AddRef();  // the reader thread's reference
    HANDLE t = startModuleThread(readerMain, s);
    if (!t) {
        s->Release();
        s->Release();
        return nullptr;
    }
    CloseHandle(t);
    return s;
}

FrameStore::~FrameStore() {
    if (stopEvent_) CloseHandle(stopEvent_);
    free(frame_);
    free(staging_);
}

void FrameStore::stop() {
    SetEvent(stopEvent_);
    clear();
}

DWORD WINAPI FrameStore::readerMain(void* p) {
    auto* self = static_cast<FrameStore*>(p);
    self->readLoop();
    self->Release();
    exitModuleThread(0);
    return 0;
}

// Connects to the agent's pipe, reads frames until it breaks, and reconnects. The agent creates
// the pipe only while the host is sharing its camera, so most of the time this just retries.
void FrameStore::readLoop() {
    OVERLAPPED ov = {};
    ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!ov.hEvent) return;
    while (WaitForSingleObject(stopEvent_, 0) == WAIT_TIMEOUT) {
        HANDLE pipe = CreateFileW(VITRINE_CAMERA_PIPE, GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                                  FILE_FLAG_OVERLAPPED, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            WaitForSingleObject(stopEvent_, 250);
            continue;
        }
        trace(L"connected to the agent");
        uint8_t header[kFrameHeaderSize];
        for (;;) {
            uint32_t w, h;
            if (!readExact(pipe, ov, header, sizeof header)) break;
            if (!parseFrameHeader(header, w, h)) {
                trace(L"bad frame header; reconnecting");
                break;
            }
            size_t n = yuyvFrameSize(w, h);
            if (stagingCap_ < n) {
                free(staging_);
                staging_ = static_cast<uint8_t*>(malloc(n));
                stagingCap_ = staging_ ? n : 0;
                if (!staging_) break;
            }
            if (!readExact(pipe, ov, staging_, n)) break;
            publish(w, h);
        }
        CloseHandle(pipe);
        // The agent stopped sharing (or restarted): show black rather than a frozen image.
        clear();
    }
    CloseHandle(ov.hEvent);
}

bool FrameStore::readExact(HANDLE pipe, OVERLAPPED& ov, uint8_t* p, size_t n) {
    while (n > 0) {
        DWORD chunk = n > 0x100000 ? 0x100000 : DWORD(n), got = 0;
        ResetEvent(ov.hEvent);
        if (!ReadFile(pipe, p, chunk, nullptr, &ov)) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            HANDLE wait[2] = {ov.hEvent, stopEvent_};
            if (WaitForMultipleObjects(2, wait, FALSE, INFINITE) != WAIT_OBJECT_0) {
                CancelIoEx(pipe, &ov);
                GetOverlappedResult(pipe, &ov, &got, TRUE);
                return false;
            }
        }
        if (!GetOverlappedResult(pipe, &ov, &got, TRUE) || got == 0) return false;
        p += got;
        n -= got;
    }
    return true;
}

void FrameStore::publish(uint32_t width, uint32_t height) {
    {
        Lock l(lock_);
        uint8_t* old = frame_;
        size_t oldCap = frameCap_;
        frame_ = staging_;
        frameCap_ = stagingCap_;
        staging_ = old;
        stagingCap_ = oldCap;
        width_ = width;
        height_ = height;
        seq_++;
    }
    WakeAllConditionVariable(&changed_);
}

void FrameStore::clear() {
    {
        Lock l(lock_);
        if (width_ == 0) return;
        width_ = height_ = 0;
        seq_++;
    }
    WakeAllConditionVariable(&changed_);
}

void FrameStore::waitForFrame(uint64_t seen, DWORD ms, const volatile LONG* cancel) {
    ULONGLONG deadline = GetTickCount64() + ms;
    Lock l(lock_);
    while (seq_ == seen && !*cancel) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;
        SleepConditionVariableSRW(&changed_, &lock_, DWORD(deadline - now), 0);
    }
}

void FrameStore::wake() {
    // Taking the lock orders this after a waiter's check of *cancel, so the wake isn't lost.
    { Lock l(lock_); }
    WakeAllConditionVariable(&changed_);
}

}  // namespace vc
