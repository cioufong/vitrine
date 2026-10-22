// Shared declarations for the Vitrine Camera media source: the COM plumbing, and the interfaces and
// GUIDs from the Windows 11 SDK that the mingw-w64 headers don't have. module.cpp defines INITGUID,
// so the GUIDs below are defined there and only declared everywhere else.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <new>

// {E0945567-3221-4186-B6DE-EAE89A9A73E4}; the agent passes this string to MFCreateVirtualCamera
// and checks HKLM\SOFTWARE\Classes\CLSID\{…} for it (guest/linux-agent/agent/camera_windows.go).
DEFINE_GUID(CLSID_VitrineCamera, 0xe0945567, 0x3221, 0x4186, 0xb6, 0xde, 0xea, 0xe8, 0x9a, 0x9a, 0x73, 0xe4);
#define VITRINE_CAMERA_CLSID L"{E0945567-3221-4186-B6DE-EAE89A9A73E4}"
#define VITRINE_CAMERA_PIPE L"\\\\.\\pipe\\vitrine-camera"

// mfidl.h / ksmedia.h / mfapi.h values (Windows SDK 10.0.22000), prefixed so a newer mingw that
// adds them doesn't collide.
DEFINE_GUID(VC_MF_DEVICESTREAM_STREAM_CATEGORY, 0x2939e7b8, 0xa62e, 0x4579, 0xb6, 0x74, 0xd4, 0x07, 0x3d, 0xfa, 0xbb, 0xba);
DEFINE_GUID(VC_MF_DEVICESTREAM_STREAM_ID, 0x11bd5120, 0xd124, 0x446b, 0x88, 0xe6, 0x17, 0x06, 0x02, 0x57, 0xff, 0xf9);
DEFINE_GUID(VC_MF_DEVICESTREAM_FRAMESERVER_SHARED, 0x1cb378e9, 0xb279, 0x41d4, 0xaf, 0x97, 0x34, 0xa2, 0x43, 0xe6, 0x83, 0x20);
DEFINE_GUID(VC_MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, 0x17145fd1, 0x1b2b, 0x423c, 0x80, 0x01, 0x2b, 0x68, 0x33, 0xed, 0x35, 0x88);
DEFINE_GUID(VC_MF_DEVICEMFT_SENSORPROFILE_COLLECTION, 0x36ebdc44, 0xb12c, 0x441b, 0x89, 0xf4, 0x08, 0xb2, 0xf4, 0x1a, 0x9c, 0xfc);
DEFINE_GUID(VC_KSCAMERAPROFILE_Legacy, 0xb4894d81, 0x62b7, 0x4eec, 0x87, 0x40, 0x80, 0x65, 0x8c, 0x4a, 0x9d, 0x3e);
DEFINE_GUID(VC_PINNAME_VIDEO_CAPTURE, 0xfb6c4281, 0x0353, 0x11d1, 0x90, 0x5f, 0x00, 0x00, 0xc0, 0xcc, 0x16, 0xba);
DEFINE_GUID(VC_IID_IMFMediaStream2, 0xc5bc37d6, 0x75c7, 0x46a1, 0xa1, 0x32, 0x81, 0xb5, 0xf7, 0x23, 0xc2, 0x0f);
DEFINE_GUID(VC_IID_IKsControl, 0x28f54685, 0x06fd, 0x11d2, 0xb2, 0x7a, 0x00, 0xa0, 0xc9, 0x22, 0x31, 0x96);
constexpr UINT32 VC_MFFrameSourceTypes_Color = 0x0001;

// IMFMediaStream2 (mfidl.h): the stream interface the Frame Server requires.
struct VcMediaStream2 : public IMFMediaStream {
    virtual HRESULT STDMETHODCALLTYPE SetStreamState(MF_STREAM_STATE value) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetStreamState(MF_STREAM_STATE* value) = 0;
};

// IKsControl (ks.h). The KSPROPERTY/KSMETHOD/KSEVENT pointers are opaque here: no controls are
// supported, so they are never read.
struct VcKsControl : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE KsProperty(void* property, ULONG propertyLength, void* data, ULONG dataLength, ULONG* bytesReturned) = 0;
    virtual HRESULT STDMETHODCALLTYPE KsMethod(void* method, ULONG methodLength, void* data, ULONG dataLength, ULONG* bytesReturned) = 0;
    virtual HRESULT STDMETHODCALLTYPE KsEvent(void* event, ULONG eventLength, void* data, ULONG dataLength, ULONG* bytesReturned) = 0;
};

// IMFSensorProfile / IMFSensorProfileCollection (mfidl.h), from mfsensorgroup.dll.
struct VcSensorProfile : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE GetProfileId(void* id) = 0;
    virtual HRESULT STDMETHODCALLTYPE AddProfileFilter(UINT32 streamId, LPCWSTR filterSet) = 0;
    virtual HRESULT STDMETHODCALLTYPE IsMediaTypeSupported(UINT32 streamId, IMFMediaType* type, BOOL* supported) = 0;
    virtual HRESULT STDMETHODCALLTYPE AddBlockedControl(LPCWSTR control) = 0;
};
struct VcSensorProfileCollection : public IUnknown {
    virtual DWORD STDMETHODCALLTYPE GetProfileCount() = 0;
    virtual HRESULT STDMETHODCALLTYPE GetProfile(DWORD index, VcSensorProfile** profile) = 0;
    virtual HRESULT STDMETHODCALLTYPE AddProfile(VcSensorProfile* profile) = 0;
    // FindProfile, RemoveProfileByIndex and RemoveProfile follow; unused.
};

namespace vc {

// Live COM objects and LockServer locks, for DllCanUnloadNow.
extern volatile LONG g_objects;
extern volatile LONG g_locks;
extern HMODULE g_module;

// Counts an object for DllCanUnloadNow for as long as it lives.
struct ModuleObject {
    ModuleObject() { InterlockedIncrement(&g_objects); }
    ~ModuleObject() { InterlockedDecrement(&g_objects); }
    ModuleObject(const ModuleObject&) = delete;
    ModuleObject& operator=(const ModuleObject&) = delete;
};

// A minimal owning COM pointer.
template <class T>
class ComPtr {
public:
    ComPtr() = default;
    explicit ComPtr(T* p) : p_(p) { if (p_) p_->AddRef(); }
    ComPtr(const ComPtr& o) : p_(o.p_) { if (p_) p_->AddRef(); }
    ComPtr(ComPtr&& o) noexcept : p_(o.p_) { o.p_ = nullptr; }
    ~ComPtr() { reset(); }
    ComPtr& operator=(const ComPtr& o) {
        if (o.p_) o.p_->AddRef();
        reset();
        p_ = o.p_;
        return *this;
    }
    ComPtr& operator=(ComPtr&& o) noexcept {
        if (this != &o) {
            reset();
            p_ = o.p_;
            o.p_ = nullptr;
        }
        return *this;
    }
    void reset() {
        if (p_) {
            T* p = p_;
            p_ = nullptr;
            p->Release();
        }
    }
    T** put() {
        reset();
        return &p_;
    }
    void** putVoid() { return reinterpret_cast<void**>(put()); }
    T* get() const { return p_; }
    T* operator->() const { return p_; }
    explicit operator bool() const { return p_ != nullptr; }
    // AddRef'd copy into an out-parameter; S_OK even when empty (the out-parameter is then null).
    HRESULT copyTo(T** out) const {
        if (!out) return E_POINTER;
        *out = p_;
        if (p_) p_->AddRef();
        return S_OK;
    }

private:
    T* p_ = nullptr;
};

// Holds an SRW lock exclusively for a scope.
class Lock {
public:
    explicit Lock(SRWLOCK& l) : l_(l) { AcquireSRWLockExclusive(&l_); }
    ~Lock() { ReleaseSRWLockExclusive(&l_); }
    Lock(const Lock&) = delete;
    Lock& operator=(const Lock&) = delete;

private:
    SRWLOCK& l_;
};

#define VC_RETURN_IF_FAILED(expr)          \
    do {                                   \
        HRESULT hr_ = (expr);              \
        if (FAILED(hr_)) return hr_;       \
    } while (0)

// Starts a thread that keeps this DLL loaded until it exits (FreeLibraryAndExitThread), so COM
// can't unload the module while a worker is still returning from its last call.
HANDLE startModuleThread(LPTHREAD_START_ROUTINE fn, void* arg);
void exitModuleThread(DWORD code);

void trace(const wchar_t* fmt, ...);

}  // namespace vc
