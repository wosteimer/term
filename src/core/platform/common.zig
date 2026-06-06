pub const Shape = enum(u32) {
    default = 1,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    e_resize,
    n_resize,
    ne_resize,
    nw_resize,
    s_resize,
    se_resize,
    sw_resize,
    w_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    col_resize,
    row_resize,
    all_scroll,
    zoom_in,
    zoom_out,
};

pub const Button = enum(u32) {
    left = 0,
    right,
    middle,
    side,
    extra,
    forward,
    back,
    task,
};

pub const Size = struct { width: u32, height: u32 };

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

pub const Event = union(enum) {
    pub const WindowResized = struct { width: u32, height: u32 };

    pub const PointerButton = struct {
        button: Button,
        raw: u32, // NOTE: system dependent scancode
    };

    pub const PointerMotion = struct { x: u32, y: u32 };

    pub const PointerWheel = struct { x: f32, y: f32 };

    window_close_requested: void,
    window_resized: WindowResized,
    text_input_preedit_changed: []const u8,
    text_input_changed: []const u8,
    pointer_button_down: PointerButton,
    pointer_button_up: PointerButton,
    pointer_motion: PointerMotion,
    pointer_wheel: PointerWheel,
};
