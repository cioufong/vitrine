#include "mediasource.h"

#include "convert.h"

#include <initializer_list>

namespace vc {

namespace {

const UINT32 kFPS = 30;
struct Size {
    UINT32 width, height;
};
const Size kSizes[] = {{1280, 720}, {640, 480}};

bool isNV12(const GUID& subtype) { return IsEqualGUID(subtype, MFVideoFormat_NV12) != 0; }

HRESULT makeType(const GUID& subtype, UINT32 w, UINT32 h, IMFMediaType** out) {
    ComPtr<IMFMediaType> t;
    VC_RETURN_IF_FAILED(MFCreateMediaType(t.put()));
    UINT32 bits = isNV12(subtype) ? 12 : 16;
    VC_RETURN_IF_FAILED(t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    VC_RETURN_IF_FAILED(t->SetGUID(MF_MT_SUBTYPE, subtype));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE));
    VC_RETURN_IF_FAILED(MFSetAttributeSize(t.get(), MF_MT_FRAME_SIZE, w, h));
    VC_RETURN_IF_FAILED(MFSetAttributeRatio(t.get(), MF_MT_FRAME_RATE, kFPS, 1));
    VC_RETURN_IF_FAILED(MFSetAttributeRatio(t.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_AVG_BITRATE, w * h * bits * kFPS));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_DEFAULT_STRIDE, isNV12(subtype) ? w : w * 2));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE));
    VC_RETURN_IF_FAILED(t->SetUINT32(MF_MT_SAMPLE_SIZE, w * h * bits / 8));
    return t.copyTo(out);
}

// The format a stream produces for a media type the client picked from our list.
HRESULT formatFromType(IMFMediaType* type, StreamFormat* f) {
    VC_RETURN_IF_FAILED(type->GetGUID(MF_MT_SUBTYPE, &f->subtype));
    if (!IsEqualGUID(f->subtype, MFVideoFormat_NV12) && !IsEqualGUID(f->subtype, MFVideoFormat_YUY2))
        return MF_E_INVALIDMEDIATYPE;
    VC_RETURN_IF_FAILED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &f->width, &f->height));
    if (f->width < 2 || f->height < 2 || f->width > kMaxDimension || f->height > kMaxDimension ||
        f->width % 2 || f->height % 2)
        return MF_E_INVALIDMEDIATYPE;
    UINT32 num = 0, den = 0;
    f->period = 10000000 / kFPS;
    if (SUCCEEDED(MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &num, &den)) && num > 0 && den > 0)
        f->period = LONGLONG(den) * 10000000 / num;
    return S_OK;
}

// The attributes the Frame Server reads off both the stream and its descriptor (Windows-Camera
// SimpleMediaStream::_SetStreamAttributes; "Frame Server Custom Media Source", Stream Attributes).
HRESULT setStreamAttributes(IMFAttributes* a, DWORD id) {
    VC_RETURN_IF_FAILED(a->SetGUID(VC_MF_DEVICESTREAM_STREAM_CATEGORY, VC_PINNAME_VIDEO_CAPTURE));
    VC_RETURN_IF_FAILED(a->SetUINT32(VC_MF_DEVICESTREAM_STREAM_ID, id));
    VC_RETURN_IF_FAILED(a->SetUINT32(VC_MF_DEVICESTREAM_FRAMESERVER_SHARED, 1));
    VC_RETURN_IF_FAILED(a->SetUINT32(VC_MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, VC_MFFrameSourceTypes_Color));
    return S_OK;
}

// Publishes the Legacy camera profile ("mandatory" when publishing profiles, per the Frame Server
// docs) for stream 0. mfsensorgroup.dll is loaded at run time, and a failure only costs the
// profile: profile-unaware apps don't need it.
void addSensorProfiles(IMFAttributes* a) {
    using CreateCollection = HRESULT(WINAPI*)(VcSensorProfileCollection**);
    using CreateProfile = HRESULT(WINAPI*)(const GUID&, UINT32, LPCWSTR, VcSensorProfile**);
    HMODULE m = LoadLibraryExW(L"mfsensorgroup.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!m) return;  // kept loaded: the collection lives in our attribute store
    auto createCollection = reinterpret_cast<CreateCollection>(reinterpret_cast<void*>(GetProcAddress(m, "MFCreateSensorProfileCollection")));
    auto createProfile = reinterpret_cast<CreateProfile>(reinterpret_cast<void*>(GetProcAddress(m, "MFCreateSensorProfile")));
    if (!createCollection || !createProfile) return;
    ComPtr<VcSensorProfileCollection> collection;
    ComPtr<VcSensorProfile> profile;
    if (FAILED(createCollection(collection.put())) ||
        FAILED(createProfile(VC_KSCAMERAPROFILE_Legacy, 0, nullptr, profile.put())) ||
        FAILED(profile->AddProfileFilter(0, L"((RES==;FRT<=30,1;SUT==))")) ||
        FAILED(collection->AddProfile(profile.get())) ||
        FAILED(a->SetUnknown(VC_MF_DEVICEMFT_SENSORPROFILE_COLLECTION, collection.get())))
        trace(L"no sensor profile collection");
}

void releaseAll(IUnknown** tokens, int n) {
    for (int i = 0; i < n; i++)
        if (tokens[i]) tokens[i]->Release();
}

PROPVARIANT systemTime() {
    PROPVARIANT v;
    PropVariantInit(&v);
    v.vt = VT_I8;
    v.hVal.QuadPart = MFGetSystemTime();
    return v;
}

}  // namespace

// ---------------------------------------------------------------------------------------------
// Stream

HRESULT Stream::create(Source* source, DWORD id, FrameStore* store, Stream** out) {
    *out = nullptr;
    Stream* s = new (std::nothrow) Stream();
    if (!s) return E_OUTOFMEMORY;
    HRESULT hr = s->init(source, id, store);
    if (FAILED(hr)) {
        s->shutdown();
        s->Release();
        return hr;
    }
    *out = s;
    return S_OK;
}

HRESULT Stream::init(Source* source, DWORD id, FrameStore* store) {
    id_ = id;
    source_ = ComPtr<IMFMediaSource>(static_cast<IMFMediaSourceEx*>(source));
    store_ = store;
    store_->AddRef();
    VC_RETURN_IF_FAILED(MFCreateAttributes(attributes_.put(), 4));
    VC_RETURN_IF_FAILED(setStreamAttributes(attributes_.get(), id));
    VC_RETURN_IF_FAILED(MFCreateEventQueue(queue_.put()));

    // NV12 first (the default), then YUY2, which is what the agent sends.
    ComPtr<IMFMediaType> types[4];
    IMFMediaType* list[4];
    int n = 0;
    for (const Size& s : kSizes) {
        for (const GUID* sub : {&MFVideoFormat_NV12, &MFVideoFormat_YUY2}) {
            VC_RETURN_IF_FAILED(makeType(*sub, s.width, s.height, types[n].put()));
            list[n] = types[n].get();
            n++;
        }
    }
    VC_RETURN_IF_FAILED(MFCreateStreamDescriptor(id, n, list, descriptor_.put()));
    ComPtr<IMFMediaTypeHandler> handler;
    VC_RETURN_IF_FAILED(descriptor_->GetMediaTypeHandler(handler.put()));
    VC_RETURN_IF_FAILED(handler->SetCurrentMediaType(list[0]));
    VC_RETURN_IF_FAILED(setStreamAttributes(descriptor_.get(), id));
    VC_RETURN_IF_FAILED(formatFromType(list[0], &format_));

    AddRef();  // the worker's reference, dropped when it exits after shutdown()
    HANDLE t = startModuleThread(workerMain, this);
    if (!t) {
        Release();
        return HRESULT_FROM_WIN32(GetLastError());
    }
    CloseHandle(t);
    return S_OK;
}

Stream::~Stream() {
    releaseAll(requests_, kMaxRequests);
    if (store_) store_->Release();
}

STDMETHODIMP Stream::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, __uuidof(IUnknown)) || IsEqualIID(riid, __uuidof(IMFMediaEventGenerator)) ||
        IsEqualIID(riid, __uuidof(IMFMediaStream)) || IsEqualIID(riid, VC_IID_IMFMediaStream2)) {
        *ppv = static_cast<VcMediaStream2*>(this);
    } else if (IsEqualIID(riid, VC_IID_IKsControl)) {
        *ppv = static_cast<VcKsControl*>(this);
    } else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) Stream::AddRef() { return InterlockedIncrement(&refs_); }

STDMETHODIMP_(ULONG) Stream::Release() {
    LONG n = InterlockedDecrement(&refs_);
    if (n == 0) delete this;
    return n;
}

HRESULT Stream::checkShutdown() const { return shutdown_ ? MF_E_SHUTDOWN : S_OK; }

STDMETHODIMP Stream::GetEvent(DWORD flags, IMFMediaEvent** event) {
    ComPtr<IMFMediaEventQueue> q;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        q = queue_;
    }
    return q->GetEvent(flags, event);  // may block, so not under the lock
}

STDMETHODIMP Stream::BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->BeginGetEvent(callback, state);
}

STDMETHODIMP Stream::EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->EndGetEvent(result, event);
}

STDMETHODIMP Stream::QueueEvent(MediaEventType type, REFGUID ext, HRESULT status, const PROPVARIANT* value) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->QueueEventParamVar(type, ext, status, value);
}

STDMETHODIMP Stream::GetMediaSource(IMFMediaSource** source) {
    if (!source) return E_POINTER;
    *source = nullptr;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return source_.copyTo(source);
}

STDMETHODIMP Stream::GetStreamDescriptor(IMFStreamDescriptor** descriptor) {
    if (!descriptor) return E_POINTER;
    *descriptor = nullptr;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return descriptor_.copyTo(descriptor);
}

// Requests are queued and answered by the worker thread at the frame rate (or as soon as the
// agent's next frame arrives), never here: RequestSample must not block.
STDMETHODIMP Stream::RequestSample(IUnknown* token) {
    IUnknown* dropped = nullptr;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        // The pipeline may call this after a stop; it doesn't treat this code as an error.
        if (state_ != MF_STREAM_STATE_RUNNING) return MF_E_MEDIA_SOURCE_WRONGSTATE;
        if (requestCount_ == kMaxRequests) {
            // Too far behind: drop the oldest request (releasing its token unanswered, which the
            // RequestSample contract allows) rather than fail this one.
            dropped = requests_[requestHead_];
            requests_[requestHead_] = nullptr;
            requestHead_ = (requestHead_ + 1) % kMaxRequests;
            requestCount_--;
        }
        if (token) token->AddRef();
        requests_[(requestHead_ + requestCount_) % kMaxRequests] = token;
        requestCount_++;
        WakeAllConditionVariable(&wake_);
    }
    if (dropped) dropped->Release();
    return S_OK;
}

// As in Windows-Camera SimpleMediaStream::SetStreamState: no events, no Pause beyond the state.
STDMETHODIMP Stream::SetStreamState(MF_STREAM_STATE state) {
    IUnknown* drained[kMaxRequests];
    int n = 0;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        if (state == state_) return S_OK;
        switch (state) {
        case MF_STREAM_STATE_PAUSED:
            if (state_ != MF_STREAM_STATE_RUNNING) return MF_E_INVALID_STATE_TRANSITION;
            state_ = state;
            break;
        case MF_STREAM_STATE_RUNNING:
            state_ = state;
            WakeAllConditionVariable(&wake_);
            break;
        case MF_STREAM_STATE_STOPPED:
            state_ = state;
            drainRequests(drained, &n);
            break;
        default:
            return MF_E_INVALID_STATE_TRANSITION;
        }
    }
    releaseAll(drained, n);
    return S_OK;
}

STDMETHODIMP Stream::GetStreamState(MF_STREAM_STATE* state) {
    if (!state) return E_POINTER;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    *state = state_;
    return S_OK;
}

// No camera controls: the code the AVStream framework returns for an unhandled property set
// ("Frame Server Custom Media Source", IKsControl).
STDMETHODIMP Stream::KsProperty(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
STDMETHODIMP Stream::KsMethod(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
STDMETHODIMP Stream::KsEvent(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }

HRESULT Stream::start(IMFMediaType* type, const PROPVARIANT* startTime) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    if (type) {
        StreamFormat f;
        VC_RETURN_IF_FAILED(formatFromType(type, &f));
        format_ = f;
    }
    VC_RETURN_IF_FAILED(queue_->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, startTime));
    state_ = MF_STREAM_STATE_RUNNING;
    WakeAllConditionVariable(&wake_);
    return S_OK;
}

HRESULT Stream::stop() {
    IUnknown* drained[kMaxRequests];
    int n = 0;
    HRESULT hr;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        state_ = MF_STREAM_STATE_STOPPED;
        drainRequests(drained, &n);
        hr = queue_->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
    }
    // Releasing a token unanswered tells the pipeline its request was dropped.
    releaseAll(drained, n);
    return hr;
}

void Stream::shutdown() {
    IUnknown* drained[kMaxRequests];
    int n = 0;
    ComPtr<IMFMediaEventQueue> q;
    ComPtr<IMFMediaSource> source;
    {
        Lock l(lock_);
        if (shutdown_) return;
        shutdown_ = true;
        state_ = MF_STREAM_STATE_STOPPED;
        drainRequests(drained, &n);
        q = static_cast<ComPtr<IMFMediaEventQueue>&&>(queue_);
        source = static_cast<ComPtr<IMFMediaSource>&&>(source_);
        attributes_.reset();
        descriptor_.reset();
        InterlockedExchange(&stopWorker_, 1);
        WakeAllConditionVariable(&wake_);
    }
    if (store_) store_->wake();
    if (q) q->Shutdown();
    releaseAll(drained, n);
    // source is released last, on return.
}

HRESULT Stream::attributes(IMFAttributes** out) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return attributes_.copyTo(out);
}

HRESULT Stream::descriptor(IMFStreamDescriptor** out) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return descriptor_.copyTo(out);
}

// Moves the pending tokens out (lock held); the caller releases them after unlocking.
void Stream::drainRequests(IUnknown** out, int* count) {
    for (int i = 0; i < requestCount_; i++) {
        int k = (requestHead_ + i) % kMaxRequests;
        out[i] = requests_[k];
        requests_[k] = nullptr;
    }
    *count = requestCount_;
    requestHead_ = requestCount_ = 0;
}

DWORD WINAPI Stream::workerMain(void* p) {
    auto* self = static_cast<Stream*>(p);
    self->work();
    self->Release();
    exitModuleThread(0);
    return 0;
}

// Answers queued requests: with the agent's next frame as soon as it arrives, or after one frame
// period with the current one (black when there is none), so apps never stall waiting.
void Stream::work() {
    uint64_t seen = ~uint64_t(0);
    LONGLONG last = 0;
    for (;;) {
        StreamFormat fmt;
        {
            Lock l(lock_);
            while (!stopWorker_ && (requestCount_ == 0 || state_ != MF_STREAM_STATE_RUNNING))
                SleepConditionVariableSRW(&wake_, &lock_, INFINITE, 0);
            if (stopWorker_) return;
            fmt = format_;
        }
        LONGLONG now = MFGetSystemTime(), due = last + fmt.period;
        if (now < due) store_->waitForFrame(seen, DWORD((due - now) / 10000) + 1, &stopWorker_);
        if (stopWorker_) return;

        ComPtr<IMFSample> sample;
        uint64_t seq = 0;
        HRESULT hr = makeSample(fmt, sample.put(), &seq);

        IUnknown* token = nullptr;
        {
            // A stop, shutdown or new media type may have come in while the frame was built.
            Lock l(lock_);
            if (shutdown_ || state_ != MF_STREAM_STATE_RUNNING || requestCount_ == 0 || fmt != format_) continue;
            token = requests_[requestHead_];
            requests_[requestHead_] = nullptr;
            requestHead_ = (requestHead_ + 1) % kMaxRequests;
            requestCount_--;
            // Queued under the lock, as start() and stop() queue MEStreamStarted and
            // MEStreamStopped: a sample checked against the old state can't follow either.
            if (SUCCEEDED(hr) && token) hr = sample->SetUnknown(MFSampleExtension_Token, token);
            if (SUCCEEDED(hr)) hr = queue_->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.get());
        }
        // A repeated frame stays on the frame clock (the deadline, not the slightly later
        // delivery time, so requests at a fixed rate don't pile up); a new frame or a stall
        // restarts it from now.
        LONGLONG delivered = MFGetSystemTime();
        last = (seq == seen && delivered - due < fmt.period) ? due : delivered;
        seen = seq;
        if (FAILED(hr)) trace(L"sample dropped: 0x%08lx", hr);
        if (token) token->Release();
    }
}

// A system-memory 2D buffer (MFCreate2DMediaBuffer, as the Frame Server docs recommend for
// uncompressed types) holding the latest frame converted to fmt, or black.
HRESULT Stream::makeSample(const StreamFormat& fmt, IMFSample** out, uint64_t* seq) {
    *out = nullptr;
    const bool nv12 = isNV12(fmt.subtype);
    ComPtr<IMFMediaBuffer> buffer;
    // A video subtype GUID's Data1 is its FOURCC ('NV12', 'YUY2').
    VC_RETURN_IF_FAILED(MFCreate2DMediaBuffer(fmt.width, fmt.height, fmt.subtype.Data1, FALSE, buffer.put()));
    ComPtr<IMF2DBuffer2> b2;
    VC_RETURN_IF_FAILED(buffer->QueryInterface(__uuidof(IMF2DBuffer2), b2.putVoid()));
    BYTE* scan0 = nullptr;
    BYTE* start = nullptr;
    LONG pitch = 0;
    DWORD length = 0;
    VC_RETURN_IF_FAILED(b2->Lock2DSize(MF2DBuffer_LockFlags_Write, &scan0, &pitch, &start, &length));
    const size_t rowBytes = nv12 ? fmt.width : size_t(fmt.width) * 2;
    const size_t need = nv12 ? size_t(pitch) * fmt.height * 3 / 2 : size_t(pitch) * fmt.height;
    const bool fits = pitch > 0 && size_t(pitch) >= rowBytes && scan0 + need <= start + length;
    if (fits) {
        bool have = store_->withFrame(seq, [&](const uint8_t* src, uint32_t sw, uint32_t sh) {
            if (nv12)
                yuyvToNV12(src, sw, sh, scan0, size_t(pitch), fmt.width, fmt.height);
            else
                yuyvToYUY2(src, sw, sh, scan0, size_t(pitch), fmt.width, fmt.height);
        });
        if (!have) {
            if (nv12)
                blackNV12(scan0, size_t(pitch), fmt.width, fmt.height);
            else
                blackYUY2(scan0, size_t(pitch), fmt.width, fmt.height);
        }
    }
    b2->Unlock2D();
    if (!fits) return MF_E_BUFFERTOOSMALL;
    DWORD contiguous = 0;
    if (SUCCEEDED(b2->GetContiguousLength(&contiguous))) buffer->SetCurrentLength(contiguous);

    ComPtr<IMFSample> sample;
    VC_RETURN_IF_FAILED(MFCreateSample(sample.put()));
    VC_RETURN_IF_FAILED(sample->AddBuffer(buffer.get()));
    // QPC-based time in 100 ns units, as the Frame Server requires.
    VC_RETURN_IF_FAILED(sample->SetSampleTime(MFGetSystemTime()));
    VC_RETURN_IF_FAILED(sample->SetSampleDuration(fmt.period));
    return sample.copyTo(out);
}

// ---------------------------------------------------------------------------------------------
// Source

HRESULT Source::create(IMFAttributes* activateAttributes, Source** out) {
    *out = nullptr;
    Source* s = new (std::nothrow) Source();
    if (!s) return E_OUTOFMEMORY;
    HRESULT hr = s->init(activateAttributes);
    if (FAILED(hr)) {
        s->Shutdown();
        s->Release();
        return hr;
    }
    *out = s;
    return S_OK;
}

HRESULT Source::init(IMFAttributes* activateAttributes) {
    VC_RETURN_IF_FAILED(MFCreateAttributes(attributes_.put(), 4));
    // The Frame Server docs require copying the IMFActivate's attributes into the source's store.
    if (activateAttributes) VC_RETURN_IF_FAILED(activateAttributes->CopyAllItems(attributes_.get()));
    addSensorProfiles(attributes_.get());
    VC_RETURN_IF_FAILED(MFCreateEventQueue(queue_.put()));
    store_ = FrameStore::create();
    if (!store_) return E_OUTOFMEMORY;
    VC_RETURN_IF_FAILED(Stream::create(this, 0, store_, &stream_));
    ComPtr<IMFStreamDescriptor> sd;
    VC_RETURN_IF_FAILED(stream_->descriptor(sd.put()));
    IMFStreamDescriptor* list[1] = {sd.get()};
    VC_RETURN_IF_FAILED(MFCreatePresentationDescriptor(1, list, pd_.put()));
    VC_RETURN_IF_FAILED(pd_->SelectStream(0));  // the default presentation has the stream on
    return S_OK;
}

Source::~Source() {
    if (stream_) {
        stream_->shutdown();
        stream_->Release();
    }
    if (store_) {
        store_->stop();
        store_->Release();
    }
}

STDMETHODIMP Source::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (IsEqualIID(riid, __uuidof(IUnknown)) || IsEqualIID(riid, __uuidof(IMFMediaEventGenerator)) ||
        IsEqualIID(riid, __uuidof(IMFMediaSource)) || IsEqualIID(riid, IID_IMFMediaSourceEx)) {
        *ppv = static_cast<IMFMediaSourceEx*>(this);
    } else if (IsEqualIID(riid, __uuidof(IMFGetService))) {
        *ppv = static_cast<IMFGetService*>(this);
    } else if (IsEqualIID(riid, VC_IID_IKsControl)) {
        *ppv = static_cast<VcKsControl*>(this);
    } else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) Source::AddRef() { return InterlockedIncrement(&refs_); }

STDMETHODIMP_(ULONG) Source::Release() {
    LONG n = InterlockedDecrement(&refs_);
    if (n == 0) delete this;
    return n;
}

HRESULT Source::checkShutdown() const { return state_ == State::Shutdown ? MF_E_SHUTDOWN : S_OK; }

STDMETHODIMP Source::GetEvent(DWORD flags, IMFMediaEvent** event) {
    ComPtr<IMFMediaEventQueue> q;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        q = queue_;
    }
    return q->GetEvent(flags, event);  // may block, so not under the lock
}

STDMETHODIMP Source::BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->BeginGetEvent(callback, state);
}

STDMETHODIMP Source::EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->EndGetEvent(result, event);
}

STDMETHODIMP Source::QueueEvent(MediaEventType type, REFGUID ext, HRESULT status, const PROPVARIANT* value) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return queue_->QueueEventParamVar(type, ext, status, value);
}

STDMETHODIMP Source::GetCharacteristics(DWORD* characteristics) {
    if (!characteristics) return E_POINTER;
    *characteristics = 0;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    *characteristics = MFMEDIASOURCE_IS_LIVE;
    return S_OK;
}

STDMETHODIMP Source::CreatePresentationDescriptor(IMFPresentationDescriptor** pd) {
    if (!pd) return E_POINTER;
    *pd = nullptr;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return pd_->Clone(pd);
}

// Event order as in Windows-Camera SimpleMediaSource::Start: MENewStream (or MEUpdatedStream when
// the stream was already selected) on the source queue, MEStreamStarted on the stream's queue,
// then MESourceStarted.
STDMETHODIMP Source::Start(IMFPresentationDescriptor* pd, const GUID* timeFormat, const PROPVARIANT* startPosition) {
    if (!pd || !startPosition) return E_INVALIDARG;
    if (timeFormat && !IsEqualGUID(*timeFormat, GUID_NULL)) return MF_E_UNSUPPORTED_TIME_FORMAT;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    DWORD count = 0;
    VC_RETURN_IF_FAILED(pd->GetStreamDescriptorCount(&count));
    if (count != 1) return E_INVALIDARG;
    BOOL selected = FALSE;
    ComPtr<IMFStreamDescriptor> sd;
    VC_RETURN_IF_FAILED(pd->GetStreamDescriptorByIndex(0, &selected, sd.put()));
    DWORD id = 0;
    VC_RETURN_IF_FAILED(sd->GetStreamIdentifier(&id));
    if (id != 0) return MF_E_INVALIDSTREAMNUMBER;

    PROPVARIANT time = systemTime();
    if (selected) {
        ComPtr<IMFMediaTypeHandler> handler;
        ComPtr<IMFMediaType> type;
        VC_RETURN_IF_FAILED(sd->GetMediaTypeHandler(handler.put()));
        if (FAILED(handler->GetCurrentMediaType(type.put()))) type.reset();  // keep the current format
        VC_RETURN_IF_FAILED(pd_->SelectStream(0));
        IUnknown* unk = static_cast<VcMediaStream2*>(stream_);
        VC_RETURN_IF_FAILED(queue_->QueueEventParamUnk(streamSelected_ ? MEUpdatedStream : MENewStream, GUID_NULL, S_OK, unk));
        VC_RETURN_IF_FAILED(stream_->start(type.get(), &time));
        streamSelected_ = true;
    } else if (streamSelected_) {
        pd_->DeselectStream(0);
        stream_->stop();
        streamSelected_ = false;
    }
    state_ = State::Started;
    return queue_->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &time);
}

STDMETHODIMP Source::Stop() {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    if (state_ != State::Started) return MF_E_INVALID_STATE_TRANSITION;
    state_ = State::Stopped;
    if (streamSelected_) {
        stream_->stop();
        pd_->DeselectStream(0);
        streamSelected_ = false;
    }
    PROPVARIANT time = systemTime();
    return queue_->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, &time);
}

// Frame Server sources don't pause ("Frame Server Custom Media Source", Seeking and Pausing).
STDMETHODIMP Source::Pause() {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return MF_E_INVALID_STATE_TRANSITION;
}

STDMETHODIMP Source::Shutdown() {
    Stream* stream;
    FrameStore* store;
    ComPtr<IMFMediaEventQueue> q;
    {
        Lock l(lock_);
        VC_RETURN_IF_FAILED(checkShutdown());
        state_ = State::Shutdown;
        stream = stream_;
        stream_ = nullptr;
        store = store_;
        store_ = nullptr;
        q = static_cast<ComPtr<IMFMediaEventQueue>&&>(queue_);
        attributes_.reset();
        pd_.reset();
    }
    if (q) q->Shutdown();
    if (stream) {
        stream->shutdown();  // drops the stream's reference to us
        stream->Release();
    }
    if (store) {
        store->stop();
        store->Release();
    }
    return S_OK;
}

STDMETHODIMP Source::GetSourceAttributes(IMFAttributes** attributes) {
    if (!attributes) return E_POINTER;
    *attributes = nullptr;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    return attributes_.copyTo(attributes);
}

STDMETHODIMP Source::GetStreamAttributes(DWORD streamId, IMFAttributes** attributes) {
    if (!attributes) return E_POINTER;
    *attributes = nullptr;
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    if (streamId != 0) return MF_E_NOT_FOUND;
    return stream_->attributes(attributes);
}

// Samples are system memory; the pipeline ignores the result (Windows-Camera SimpleMediaSource).
STDMETHODIMP Source::SetD3DManager(IUnknown*) { return E_NOTIMPL; }

STDMETHODIMP Source::GetService(REFGUID, REFIID, void** ppv) {
    Lock l(lock_);
    VC_RETURN_IF_FAILED(checkShutdown());
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    return MF_E_UNSUPPORTED_SERVICE;
}

STDMETHODIMP Source::KsProperty(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
STDMETHODIMP Source::KsMethod(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }
STDMETHODIMP Source::KsEvent(void*, ULONG, void*, ULONG, ULONG*) { return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND); }

}  // namespace vc
