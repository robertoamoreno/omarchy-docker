/* omarchy-egl-probe — does this host let Hyprland build a renderer?
 *
 * This replicates, exactly, the check that decides whether Hyprland 0.56.2 can
 * paint anything. aquamarine 0.14.0's DRM backend only ever calls
 *     CDRMRenderer::attempt(backend, drmFD)          (DRM.cpp:669, :1237)
 * which requires EGL_EXT_platform_device and then calls eglDeviceFromDRMFD()
 * (Renderer.cpp:236). That walks eglQueryDevicesEXT() and matches each device's
 * EGL_DRM_DEVICE_FILE_EXT against the DRM node. If nothing matches it logs
 *     "CDRMRenderer(drm): Can't create renderer, no matching devices found"
 * and Hyprland runs but never renders -- a live Wayland socket and a black VNC
 * screen, which is far worse to debug than an outright failure.
 *
 * A DRM node existing is NOT sufficient. On a vkms-only host (Colima/Lima with
 * modprobe vkms, or any VM without a real GPU) /dev/dri/card0 is present and
 * readable, yet mesa enumerates exactly one EGL device:
 *     device[0]: DRM_DEVICE_FILE=(none) RENDER_NODE=(none)
 *                exts: EGL_MESA_device_software
 * because vkms exposes no render node. Hence this probe.
 *
 * exit 0 -> at least one EGL device reports a DRM device file: run Hyprland.
 * exit 1 -> none does: use the wlroots fallback (wlroots uses the GBM platform
 *           and tolerates a missing render node, so it renders fine here).
 * Pass -v to print what was found.
 */
#include <stdio.h>
#include <string.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

int main(int argc, char **argv) {
    int verbose = (argc > 1 && strcmp(argv[1], "-v") == 0);
    PFNEGLQUERYDEVICESEXTPROC qDevices =
        (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC qString =
        (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");

    if (!qDevices || !qString) {
        if (verbose) printf("no EGL_EXT_device_enumeration / device_query\n");
        return 1;
    }

    EGLint n = 0;
    if (!qDevices(0, NULL, &n) || n <= 0) {
        if (verbose) printf("eglQueryDevicesEXT enumerated no devices\n");
        return 1;
    }

    EGLDeviceEXT devices[32];
    if (n > 32) n = 32;
    if (!qDevices(n, devices, &n)) {
        if (verbose) printf("eglQueryDevicesEXT failed on second call\n");
        return 1;
    }

    int found = 0;
    for (EGLint i = 0; i < n; i++) {
        /* eglQueryDeviceStringEXT sets EGL_BAD_PARAMETER and returns NULL for a
         * software device; clear the error so a later query is not confused. */
        const char *file = qString(devices[i], EGL_DRM_DEVICE_FILE_EXT);
        eglGetError();
        if (verbose)
            printf("  EGL device[%d]: DRM_DEVICE_FILE=%s\n", i, file ? file : "(none)");
        if (file) found = 1;
    }

    if (verbose)
        printf("%d EGL device(s); DRM-backed: %s -> %s\n", n, found ? "yes" : "no",
               found ? "Hyprland can build a renderer" : "Hyprland would render nothing");
    return found ? 0 : 1;
}
