/* SPDX-License-Identifier: GPL-3.0-or-later */
/* blackbox: demonstrates Wine's "delayed unmapping" behaviour.
 *
 * READ THIS BEFORE TRUSTING IT AS A TEST. This program does NOT reproduce winehq
 * bug 59378, and a leftover window here is NOT a defect. It is kept because the
 * distinction cost real debugging time and is worth recording.
 *
 * What it does: shows two identical windows and hides them two ways:
 *   A: ShowWindow(SW_HIDE)               -> goes through SWP_HIDEWINDOW
 *   B: clear WS_VISIBLE + SetWindowPos() -> no SWP_HIDEWINDOW
 *
 * B stays on screen, and Wine logs "not yet hidden, delaying unmapping" on the
 * x11drv channel. That happens on Wine 11.0 AND on 11.14 - measured, not assumed -
 * because it is deliberate. dlls/winex11.drv/window.c, X11DRV_WindowPosChanged:
 *
 *     // visible windows are only hidden after SWP_HIDEWINDOW is used
 *     if (state.wm_state != WithdrawnState && !(new_style & WS_VISIBLE) &&
 *         !(swp_flags & SWP_HIDEWINDOW))
 *     { WARN("...delaying unmapping"); new_style |= WS_VISIBLE; }
 *
 * An app that clears the style bit without ever properly hiding the window gets a
 * window that stays mapped. That is by design.
 *
 * Bug 59378's fix (commit 2b05f63811f0, "winex11: Use the desired state for mapping
 * delays", in 11.13) changed only WHICH state field gates that condition -
 * `pending_state` -> `desired_state` - which matters when a state change is in
 * flight, i.e. in a race. A synthetic single-threaded case like this one cannot
 * tell the two versions apart, so it cannot confirm or refute 59378.
 *
 * To check whether a given Wine still has 59378, reproduce in the real application
 * and look for a leftover window that the app DID hide properly.
 *
 * Build: i686-w64-mingw32-gcc -O1 -o blackbox.exe blackbox.c -lgdi32 -luser32
 * Run:   WINEDEBUG=fixme-all,warn+x11drv wine blackbox.exe 2>&1 | tee bb.log
 */
#include <windows.h>
#include <stdio.h>

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        HBRUSH br = CreateSolidBrush(RGB(0, 160, 0));   /* green == genuinely painted */
        FillRect(dc, &ps.rcPaint, br);
        DeleteObject(br);
        EndPaint(h, &ps);
        return 0;
    }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

static void pump(int ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while (GetTickCount() < end) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

int main(void)
{
    WNDCLASSEXW wc;
    HWND a, b;

    ZeroMemory(&wc, sizeof wc);
    wc.cbSize        = sizeof wc;
    wc.lpfnWndProc   = wp;
    wc.hInstance     = GetModuleHandleW(NULL);
    wc.lpszClassName = L"blackbox";
    wc.hCursor       = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassExW(&wc);

    a = CreateWindowExW(0, L"blackbox", L"blackbox A - hidden via ShowWindow(SW_HIDE)",
                        WS_OVERLAPPEDWINDOW, 200, 200, 400, 300,
                        NULL, NULL, wc.hInstance, NULL);
    b = CreateWindowExW(0, L"blackbox", L"blackbox B - hidden WITHOUT SWP_HIDEWINDOW",
                        WS_OVERLAPPEDWINDOW, 650, 200, 400, 300,
                        NULL, NULL, wc.hInstance, NULL);
    if (!a || !b) { printf("CreateWindowExW failed (%lu)\n", GetLastError()); return 2; }

    ShowWindow(a, SW_SHOW); ShowWindow(b, SW_SHOW);
    UpdateWindow(a);        UpdateWindow(b);
    printf("[1] both windows shown, painted green. holding 4s...\n"); fflush(stdout);
    pump(4000);

    printf("[2] hiding A the ordinary way: ShowWindow(SW_HIDE)\n"); fflush(stdout);
    ShowWindow(a, SW_HIDE);
    pump(1500);

    printf("[3] hiding B the way that trips the defect:\n");
    printf("    SetWindowLong(GWL_STYLE, style & ~WS_VISIBLE), then SetWindowPos()\n");
    printf("    with NO SWP_HIDEWINDOW flag\n"); fflush(stdout);
    SetWindowLongW(b, GWL_STYLE, GetWindowLongW(b, GWL_STYLE) & ~WS_VISIBLE);
    SetWindowPos(b, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    pump(1500);

    printf("[4] IsWindowVisible: A=%d  B=%d   (both should be 0)\n",
           IsWindowVisible(a), IsWindowVisible(b)); fflush(stdout);
    printf("[5] VERDICT: if a rectangle is still on screen where B was, this Wine has\n");
    printf("    bug 59378. Holding 20s so it can be seen / listed by the window manager.\n");
    fflush(stdout);
    pump(20000);

    printf("[6] done\n");
    return 0;
}
