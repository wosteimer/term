#ifdef LINUX_PLATFORM_WAYLAND
#include <cursor-shape-v1.h>
#include <linux/input-event-codes.h>
#include <tearing-control-v1.h>
#include <wayland-client.h>
#include <xdg-decoration-unstable-v1.h>
#include <xdg-shell.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon.h>
#endif // LINUX_PLATFORM_WAYLAND

#ifdef LINUX_PLATFORM_X11
// TODO: implement x11 backend
#endif // LINUX_PLATFORM_X11

#include <fontconfig/fontconfig.h>
#include <harfbuzz/hb-ft.h>
#include <harfbuzz/hb.h>
#include <pixman-1/pixman.h>
#include <stb_rect_pack.h>
#include <stdbool.h>
#include <utf8proc.h>

#include <pty.h>
#include <utmp.h>
