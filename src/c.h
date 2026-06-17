#ifdef LINUX_PLATFORM_WAYLAND
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <wp-cursor-shape-v1-client.h>
#include <xdg-shell-client.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon.h>
#include <zxdg-decoration-v1-client.h>
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
