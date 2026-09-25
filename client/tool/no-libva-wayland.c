/* Preloaded into the application by ui-test.sh, and nowhere else.
 *
 * mpv probes its vaapi interop through the Wayland display it is given, and
 * libva 2.20's Wayland backend (Ubuntu 24.04, and so the CI runner) reads a
 * DRM state it never set up when the compositor has no `wl_drm` — which no
 * headless compositor on a machine without a GPU has — and crashes inside
 * `vaInitialize`. With no display to initialise, mpv notes that vaapi is
 * unavailable and goes on; there is nothing to accelerate on llvmpipe anyway.
 */
#include <stddef.h>

void* vaGetDisplayWl(void* wl_display) {
  (void)wl_display;
  return NULL;
}
