/* =====================================================================
 * Daydream Checkpoints — dinput8.dll proxy
 *
 * Drop-in replacement for dinput8.dll placed next to the game exe.
 * Windows loads it instead of the system DLL (application-directory
 * DLL search order). It does exactly two things:
 *
 *   1. Forwards all DirectInput work to the real system dinput8.dll,
 *      so the game behaves identically.
 *   2. On game start, launches the Daydream watcher (hidden PowerShell)
 *      so checkpoints work without the player running anything.
 *
 * Watcher script path: defaults to the standard install location,
 * "<dll dir>\mods\DaydreamCheckpoints\watcher\DaydreamWatcher.ps1".
 * Override by putting a full path on the first line of
 * "daydream_watcher.cfg" next to this DLL.
 * Activity is logged to "<dll dir>\daydream_hook.log".
 *
 * Build (zig): zig cc -O2 -shared -o dinput8.dll dinput8.c
 * ===================================================================== */

#include <windows.h>
#include <stdio.h>

static HMODULE g_real = NULL;
static FARPROC g_fnDirectInput8Create = NULL;
static FARPROC g_fnDllCanUnloadNow = NULL;
static FARPROC g_fnDllGetClassObject = NULL;
static FARPROC g_fnDllRegisterServer = NULL;
static FARPROC g_fnDllUnregisterServer = NULL;
static FARPROC g_fnGetdfDIJoystick = NULL;

static WCHAR g_dllDir[MAX_PATH] = L"";

/* ---- tiny append-only log ------------------------------------------ */

static void logline(const WCHAR *msg)
{
    WCHAR path[MAX_PATH + 32];
    swprintf(path, MAX_PATH + 32, L"%s\\daydream_hook.log", g_dllDir);
    FILE *f = _wfopen(path, L"a, ccs=UTF-8");
    if (!f) return;
    fwprintf(f, L"%s\r\n", msg);
    fclose(f);
}

/* ---- real DLL loading & forwarding --------------------------------- */

static void load_real(void)
{
    if (g_real) return;
    WCHAR path[MAX_PATH];
    GetSystemDirectoryW(path, MAX_PATH);
    wcscat(path, L"\\dinput8.dll");
    g_real = LoadLibraryW(path);
    if (!g_real) {
        logline(L"ERROR: could not load system dinput8.dll");
        return;
    }
    g_fnDirectInput8Create  = GetProcAddress(g_real, "DirectInput8Create");
    g_fnDllCanUnloadNow     = GetProcAddress(g_real, "DllCanUnloadNow");
    g_fnDllGetClassObject   = GetProcAddress(g_real, "DllGetClassObject");
    g_fnDllRegisterServer   = GetProcAddress(g_real, "DllRegisterServer");
    g_fnDllUnregisterServer = GetProcAddress(g_real, "DllUnregisterServer");
    g_fnGetdfDIJoystick     = GetProcAddress(g_real, "GetdfDIJoystick");
}

typedef HRESULT (WINAPI *PFN_DirectInput8Create)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
typedef HRESULT (WINAPI *PFN_DllCanUnloadNow)(void);
typedef HRESULT (WINAPI *PFN_DllGetClassObject)(REFCLSID, REFIID, LPVOID *);
typedef HRESULT (WINAPI *PFN_NoArgs)(void);
typedef LPVOID  (WINAPI *PFN_GetdfDIJoystick)(void);

__declspec(dllexport) HRESULT WINAPI DirectInput8Create(
    HINSTANCE hinst, DWORD dwVersion, REFIID riidltf, LPVOID *ppvOut, LPUNKNOWN punkOuter)
{
    load_real();
    if (!g_fnDirectInput8Create) return E_FAIL;
    return ((PFN_DirectInput8Create)g_fnDirectInput8Create)(hinst, dwVersion, riidltf, ppvOut, punkOuter);
}

__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void)
{
    load_real();
    if (!g_fnDllCanUnloadNow) return S_FALSE;
    return ((PFN_DllCanUnloadNow)g_fnDllCanUnloadNow)();
}

__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID *ppv)
{
    load_real();
    if (!g_fnDllGetClassObject) return E_FAIL;
    return ((PFN_DllGetClassObject)g_fnDllGetClassObject)(rclsid, riid, ppv);
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void)
{
    load_real();
    if (!g_fnDllRegisterServer) return E_FAIL;
    return ((PFN_NoArgs)g_fnDllRegisterServer)();
}

__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void)
{
    load_real();
    if (!g_fnDllUnregisterServer) return E_FAIL;
    return ((PFN_NoArgs)g_fnDllUnregisterServer)();
}

__declspec(dllexport) LPVOID WINAPI GetdfDIJoystick(void)
{
    load_real();
    if (!g_fnGetdfDIJoystick) return NULL;
    return ((PFN_GetdfDIJoystick)g_fnGetdfDIJoystick)();
}

/* ---- watcher launch -------------------------------------------------- */

/* Resolve the watcher script path: cfg override, else default. */
static BOOL resolve_script_path(WCHAR *out, size_t outLen)
{
    WCHAR cfgPath[MAX_PATH + 32];
    swprintf(cfgPath, MAX_PATH + 32, L"%s\\daydream_watcher.cfg", g_dllDir);

    HANDLE h = CreateFileW(cfgPath, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        char buf[2048];
        DWORD read = 0;
        BOOL ok = ReadFile(h, buf, sizeof(buf) - 1, &read, NULL);
        CloseHandle(h);
        if (ok && read > 0) {
            buf[read] = '\0';
            /* keep only the first line */
            for (DWORD i = 0; i < read; i++) {
                if (buf[i] == '\r' || buf[i] == '\n') { buf[i] = '\0'; break; }
            }
            if (buf[0] != '\0') {
                MultiByteToWideChar(CP_UTF8, 0, buf, -1, out, (int)outLen);
                return TRUE;
            }
        }
    }

    swprintf(out, outLen,
        L"%s\\mods\\DaydreamCheckpoints\\watcher\\DaydreamWatcher.ps1", g_dllDir);
    return TRUE;
}

static DWORD WINAPI watcher_thread(LPVOID param)
{
    (void)param;
    Sleep(2000); /* let the game get on with booting first */

    WCHAR script[2048];
    resolve_script_path(script, 2048);

    if (GetFileAttributesW(script) == INVALID_FILE_ATTRIBUTES) {
        WCHAR msg[2200];
        swprintf(msg, 2200, L"watcher script not found: %s", script);
        logline(msg);
        return 0;
    }

    WCHAR cmd[4096];
    swprintf(cmd, 4096,
        L"\"%s\\WindowsPowerShell\\v1.0\\powershell.exe\" "
        L"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" -FollowGame",
        L"C:\\Windows\\System32", script);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                       NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        WCHAR msg[2200];
        swprintf(msg, 2200, L"watcher launched: %s", script);
        logline(msg);
    } else {
        WCHAR msg[128];
        swprintf(msg, 128, L"CreateProcessW failed: %lu", GetLastError());
        logline(msg);
    }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        GetModuleFileNameW(inst, g_dllDir, MAX_PATH);
        WCHAR *slash = wcsrchr(g_dllDir, L'\\');
        if (slash) *slash = L'\0';
        /* Spawning a process directly in DllMain risks loader deadlock;
         * a short-lived thread does it safely once the loader settles. */
        HANDLE t = CreateThread(NULL, 0, watcher_thread, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
