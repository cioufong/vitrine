// The COM server: DllMain, the class factory for CLSID_VitrineCamera, its IMFActivate (what
// MFCreateVirtualCamera's Frame Server activates), registration, and module helpers.
#define INITGUID
#include "common.h"
#include "mediasource.h"

#include <cstdarg>
#include <cwchar>

namespace vc {

volatile LONG g_objects = 0;
volatile LONG g_locks = 0;
HMODULE g_module = nullptr;

void trace(const wchar_t* fmt, ...) {
    wchar_t buf[256] = L"[vitrine-camera] ";
    size_t n = wcslen(buf);
    va_list args;
    va_start(args, fmt);
    _vsnwprintf(buf + n, sizeof buf / sizeof buf[0] - n - 2, fmt, args);
    va_end(args);
    buf[sizeof buf / sizeof buf[0] - 2] = 0;
    wcscat(buf, L"\n");
    OutputDebugStringW(buf);
}

HANDLE startModuleThread(LPTHREAD_START_ROUTINE fn, void* arg) {
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, reinterpret_cast<LPCWSTR>(g_module), &self))
        return nullptr;
    HANDLE t = CreateThread(nullptr, 0, fn, arg, 0, nullptr);
    if (!t) FreeLibrary(self);
    return t;
}

void exitModuleThread(DWORD code) { FreeLibraryAndExitThread(g_module, code); }

namespace {

// IMFActivate for the source, as in Windows-Camera's VirtualCameraMediaSourceActivate: the
// pipeline may set attributes on it, which the source copies into its own store.
class Activate final : public IMFActivate {
public:
    static HRESULT create(REFIID riid, void** ppv) {
        Activate* a = new (std::nothrow) Activate();
        if (!a) return E_OUTOFMEMORY;
        HRESULT hr = MFCreateAttributes(a->attrs_.put(), 4);
        if (SUCCEEDED(hr)) hr = a->QueryInterface(riid, ppv);
        a->Release();
        return hr;
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, __uuidof(IUnknown)) || IsEqualIID(riid, __uuidof(IMFAttributes)) ||
            IsEqualIID(riid, __uuidof(IMFActivate))) {
            *ppv = static_cast<IMFActivate*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return n;
    }

    // A new source per activation; the caller owns it and shuts it down.
    STDMETHODIMP ActivateObject(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        Source* s = nullptr;
        VC_RETURN_IF_FAILED(Source::create(attrs_.get(), &s));
        HRESULT hr = s->QueryInterface(riid, ppv);
        if (FAILED(hr)) s->Shutdown();  // nobody else can break the source↔stream cycle
        s->Release();
        return hr;
    }
    // Nothing to do: no reference to the source is kept here. (The Frame Server custom media
    // source docs say E_NOTIMPL; Windows-Camera's virtual camera sample returns S_OK, the
    // behaviour proven with MFCreateVirtualCamera.)
    STDMETHODIMP ShutdownObject() override { return S_OK; }
    STDMETHODIMP DetachObject() override { return S_OK; }

    // IMFAttributes, delegated.
    STDMETHODIMP GetItem(REFGUID k, PROPVARIANT* v) override { return attrs_->GetItem(k, v); }
    STDMETHODIMP GetItemType(REFGUID k, MF_ATTRIBUTE_TYPE* t) override { return attrs_->GetItemType(k, t); }
    STDMETHODIMP CompareItem(REFGUID k, REFPROPVARIANT v, WINBOOL* r) override { return attrs_->CompareItem(k, v, r); }
    STDMETHODIMP Compare(IMFAttributes* o, MF_ATTRIBUTES_MATCH_TYPE m, WINBOOL* r) override { return attrs_->Compare(o, m, r); }
    STDMETHODIMP GetUINT32(REFGUID k, UINT32* v) override { return attrs_->GetUINT32(k, v); }
    STDMETHODIMP GetUINT64(REFGUID k, UINT64* v) override { return attrs_->GetUINT64(k, v); }
    STDMETHODIMP GetDouble(REFGUID k, double* v) override { return attrs_->GetDouble(k, v); }
    STDMETHODIMP GetGUID(REFGUID k, GUID* v) override { return attrs_->GetGUID(k, v); }
    STDMETHODIMP GetStringLength(REFGUID k, UINT32* n) override { return attrs_->GetStringLength(k, n); }
    STDMETHODIMP GetString(REFGUID k, LPWSTR v, UINT32 size, UINT32* n) override { return attrs_->GetString(k, v, size, n); }
    STDMETHODIMP GetAllocatedString(REFGUID k, LPWSTR* v, UINT32* n) override { return attrs_->GetAllocatedString(k, v, n); }
    STDMETHODIMP GetBlobSize(REFGUID k, UINT32* n) override { return attrs_->GetBlobSize(k, n); }
    STDMETHODIMP GetBlob(REFGUID k, UINT8* b, UINT32 size, UINT32* n) override { return attrs_->GetBlob(k, b, size, n); }
    STDMETHODIMP GetAllocatedBlob(REFGUID k, UINT8** b, UINT32* n) override { return attrs_->GetAllocatedBlob(k, b, n); }
    STDMETHODIMP GetUnknown(REFGUID k, REFIID riid, LPVOID* ppv) override { return attrs_->GetUnknown(k, riid, ppv); }
    STDMETHODIMP SetItem(REFGUID k, REFPROPVARIANT v) override { return attrs_->SetItem(k, v); }
    STDMETHODIMP DeleteItem(REFGUID k) override { return attrs_->DeleteItem(k); }
    STDMETHODIMP DeleteAllItems() override { return attrs_->DeleteAllItems(); }
    STDMETHODIMP SetUINT32(REFGUID k, UINT32 v) override { return attrs_->SetUINT32(k, v); }
    STDMETHODIMP SetUINT64(REFGUID k, UINT64 v) override { return attrs_->SetUINT64(k, v); }
    STDMETHODIMP SetDouble(REFGUID k, double v) override { return attrs_->SetDouble(k, v); }
    STDMETHODIMP SetGUID(REFGUID k, REFGUID v) override { return attrs_->SetGUID(k, v); }
    STDMETHODIMP SetString(REFGUID k, LPCWSTR v) override { return attrs_->SetString(k, v); }
    STDMETHODIMP SetBlob(REFGUID k, const UINT8* b, UINT32 n) override { return attrs_->SetBlob(k, b, n); }
    STDMETHODIMP SetUnknown(REFGUID k, IUnknown* u) override { return attrs_->SetUnknown(k, u); }
    STDMETHODIMP LockStore() override { return attrs_->LockStore(); }
    STDMETHODIMP UnlockStore() override { return attrs_->UnlockStore(); }
    STDMETHODIMP GetCount(UINT32* n) override { return attrs_->GetCount(n); }
    STDMETHODIMP GetItemByIndex(UINT32 i, GUID* k, PROPVARIANT* v) override { return attrs_->GetItemByIndex(i, k, v); }
    STDMETHODIMP CopyAllItems(IMFAttributes* dest) override { return attrs_->CopyAllItems(dest); }

private:
    Activate() = default;
    ~Activate() = default;
    ModuleObject counted_;
    volatile LONG refs_ = 1;
    ComPtr<IMFAttributes> attrs_;
};

class ClassFactory final : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, __uuidof(IUnknown)) || IsEqualIID(riid, __uuidof(IClassFactory))) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return n;
    }
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        return Activate::create(riid, ppv);
    }
    STDMETHODIMP LockServer(BOOL lock) override {
        if (lock)
            InterlockedIncrement(&g_locks);
        else
            InterlockedDecrement(&g_locks);
        return S_OK;
    }

private:
    ModuleObject counted_;
    volatile LONG refs_ = 1;
};

const wchar_t kClassKey[] = L"SOFTWARE\\Classes\\CLSID\\" VITRINE_CAMERA_CLSID;

LONG setString(HKEY key, const wchar_t* name, const wchar_t* value) {
    return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value),
                          DWORD((wcslen(value) + 1) * sizeof(wchar_t)));
}

}  // namespace
}  // namespace vc

using namespace vc;

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    // No DisableThreadLibraryCalls: the statically linked C++ runtime wants thread notifications.
    if (reason == DLL_PROCESS_ATTACH) g_module = instance;
    return TRUE;
}

extern "C" HRESULT STDAPICALLTYPE DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* ppv) {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (!IsEqualCLSID(clsid, CLSID_VitrineCamera)) return CLASS_E_CLASSNOTAVAILABLE;
    ClassFactory* f = new (std::nothrow) ClassFactory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

extern "C" HRESULT STDAPICALLTYPE DllCanUnloadNow() {
    return g_objects == 0 && g_locks == 0 ? S_OK : S_FALSE;
}

// HKLM, not HKCU: the Frame Server loads the source as LocalService, which only sees machine-wide
// classes. install.ps1 writes the same keys itself; this is for `regsvr32 vitrine-camera.dll`.
extern "C" HRESULT STDAPICALLTYPE DllRegisterServer() {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(g_module, path, MAX_PATH);
    if (n == 0 || n == MAX_PATH) return HRESULT_FROM_WIN32(GetLastError());
    HKEY cls = nullptr, inproc = nullptr;
    LONG e = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kClassKey, 0, nullptr, 0, KEY_WRITE, nullptr, &cls, nullptr);
    if (e == ERROR_SUCCESS) e = setString(cls, nullptr, L"Vitrine Camera");
    if (e == ERROR_SUCCESS) e = RegCreateKeyExW(cls, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &inproc, nullptr);
    if (e == ERROR_SUCCESS) e = setString(inproc, nullptr, path);
    if (e == ERROR_SUCCESS) e = setString(inproc, L"ThreadingModel", L"Both");
    if (inproc) RegCloseKey(inproc);
    if (cls) RegCloseKey(cls);
    return HRESULT_FROM_WIN32(e);
}

extern "C" HRESULT STDAPICALLTYPE DllUnregisterServer() {
    LONG e = RegDeleteTreeW(HKEY_LOCAL_MACHINE, kClassKey);
    return e == ERROR_SUCCESS || e == ERROR_FILE_NOT_FOUND ? S_OK : HRESULT_FROM_WIN32(e);
}
