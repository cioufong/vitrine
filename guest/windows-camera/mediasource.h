// The Vitrine Camera media source: one video capture stream offering NV12 and YUY2 at 1280×720 and
// 640×480, 30 fps, fed from the agent's frames (FrameStore). Structure and event flow follow
// Microsoft's Frame Server custom media source guidance and its VirtualCamera sample
// (Windows-Camera/Samples/VirtualCamera: SimpleMediaSource, SimpleMediaStream).
#pragma once

#include "common.h"
#include "frames.h"

namespace vc {

class Source;

struct StreamFormat {
    GUID subtype = {};
    UINT32 width = 0, height = 0;
    LONGLONG period = 333333;  // 100 ns units
    bool operator==(const StreamFormat& o) const {
        return IsEqualGUID(subtype, o.subtype) && width == o.width && height == o.height && period == o.period;
    }
    bool operator!=(const StreamFormat& o) const { return !(*this == o); }
};

class Stream final : public VcMediaStream2, public VcKsControl {
public:
    static HRESULT create(Source* source, DWORD id, FrameStore* store, Stream** out);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    // IMFMediaEventGenerator
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override;
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override;
    STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override;
    STDMETHODIMP QueueEvent(MediaEventType type, REFGUID ext, HRESULT status, const PROPVARIANT* value) override;
    // IMFMediaStream
    STDMETHODIMP GetMediaSource(IMFMediaSource** source) override;
    STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** descriptor) override;
    STDMETHODIMP RequestSample(IUnknown* token) override;
    // IMFMediaStream2
    STDMETHODIMP SetStreamState(MF_STREAM_STATE state) override;
    STDMETHODIMP GetStreamState(MF_STREAM_STATE* state) override;
    // IKsControl
    STDMETHODIMP KsProperty(void*, ULONG, void*, ULONG, ULONG*) override;
    STDMETHODIMP KsMethod(void*, ULONG, void*, ULONG, ULONG*) override;
    STDMETHODIMP KsEvent(void*, ULONG, void*, ULONG, ULONG*) override;

    // Called by the source.
    HRESULT start(IMFMediaType* type, const PROPVARIANT* startTime);
    HRESULT stop();
    void shutdown();
    HRESULT attributes(IMFAttributes** out);
    HRESULT descriptor(IMFStreamDescriptor** out);

private:
    Stream() = default;
    ~Stream();
    HRESULT init(Source* source, DWORD id, FrameStore* store);
    HRESULT checkShutdown() const;
    void drainRequests(IUnknown** out, int* count);
    static DWORD WINAPI workerMain(void* self);
    void work();
    HRESULT makeSample(const StreamFormat& fmt, IMFSample** out, uint64_t* seq);

    static constexpr int kMaxRequests = 32;

    ModuleObject counted_;
    volatile LONG refs_ = 1;
    SRWLOCK lock_ = SRWLOCK_INIT;
    CONDITION_VARIABLE wake_ = CONDITION_VARIABLE_INIT;
    DWORD id_ = 0;
    ComPtr<IMFMediaSource> source_;  // released at shutdown, which breaks the source↔stream cycle
    FrameStore* store_ = nullptr;
    ComPtr<IMFMediaEventQueue> queue_;
    ComPtr<IMFAttributes> attributes_;
    ComPtr<IMFStreamDescriptor> descriptor_;
    MF_STREAM_STATE state_ = MF_STREAM_STATE_STOPPED;
    bool shutdown_ = false;
    StreamFormat format_;
    // RequestSample tokens (each AddRef'd, or null), first in first out.
    IUnknown* requests_[kMaxRequests] = {};
    int requestHead_ = 0, requestCount_ = 0;
    volatile LONG stopWorker_ = 0;
};

class Source final : public IMFMediaSourceEx, public IMFGetService, public VcKsControl {
public:
    static HRESULT create(IMFAttributes* activateAttributes, Source** out);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    // IMFMediaEventGenerator
    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override;
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override;
    STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override;
    STDMETHODIMP QueueEvent(MediaEventType type, REFGUID ext, HRESULT status, const PROPVARIANT* value) override;
    // IMFMediaSource
    STDMETHODIMP GetCharacteristics(DWORD* characteristics) override;
    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** pd) override;
    STDMETHODIMP Start(IMFPresentationDescriptor* pd, const GUID* timeFormat, const PROPVARIANT* startPosition) override;
    STDMETHODIMP Stop() override;
    STDMETHODIMP Pause() override;
    STDMETHODIMP Shutdown() override;
    // IMFMediaSourceEx
    STDMETHODIMP GetSourceAttributes(IMFAttributes** attributes) override;
    STDMETHODIMP GetStreamAttributes(DWORD streamId, IMFAttributes** attributes) override;
    STDMETHODIMP SetD3DManager(IUnknown* manager) override;
    // IMFGetService
    STDMETHODIMP GetService(REFGUID service, REFIID riid, void** ppv) override;
    // IKsControl
    STDMETHODIMP KsProperty(void*, ULONG, void*, ULONG, ULONG*) override;
    STDMETHODIMP KsMethod(void*, ULONG, void*, ULONG, ULONG*) override;
    STDMETHODIMP KsEvent(void*, ULONG, void*, ULONG, ULONG*) override;

private:
    enum class State { Stopped, Started, Shutdown };

    Source() = default;
    ~Source();
    HRESULT init(IMFAttributes* activateAttributes);
    HRESULT checkShutdown() const;

    ModuleObject counted_;
    volatile LONG refs_ = 1;
    SRWLOCK lock_ = SRWLOCK_INIT;
    State state_ = State::Stopped;
    ComPtr<IMFMediaEventQueue> queue_;
    ComPtr<IMFAttributes> attributes_;
    ComPtr<IMFPresentationDescriptor> pd_;
    Stream* stream_ = nullptr;  // owned; one stream, id 0
    bool streamSelected_ = false;
    FrameStore* store_ = nullptr;
};

}  // namespace vc
