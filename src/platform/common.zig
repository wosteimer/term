// zig fmt: off
pub const Key = enum(u32) {
    unknown = 0,
    
    a, b, c, d, e, f,
    g, h, i, j, k, l,
    m, n, o, p, q, r,
    s, t, u, v, w, x,
    y, z,

    @"1", @"2", @"3", @"4", @"5", 
    @"6", @"7", @"8", @"9", @"0", 

    num_lock, 
    numpad_1, numpad_2, numpad_3, numpad_4, numpad_5, 
    numpad_6, numpad_7, numpad_8, numpad_9, numpad_0, 
    numpad_enter, numpad_plus, numpad_minus, 
    numpad_asterisk, numpad_slash, numpad_dot,

    enter, escape, backspace, tab, space, 

    left_shift, right_shift, left_control, right_control,
    left_alt, right_alt, left_meta, right_meta, menu,
    
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,

    back_quote, minus, equal, backslash, left_brace, right_brace,
    caps_lock, semicolon, apostrophe, comma, dot, slash, 

    insert, home, page_up,
    delete, end, page_down,
    
    print, scroll_lock, pause,

    up, down, left, right,

    @"102nd", ro, compose,
};
// zig fmt: on

pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u26 = 0,
};

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

    pub const KeyboardKey = struct {
        key: Key,
        raw: u32, // NOTE: system dependent scancode
        modifiers: Modifiers,
    };

    pub const PointerButton = struct {
        button: Button,
        raw: u32, // NOTE: system dependent scancode
    };

    pub const PointerMotion = struct { x: u32, y: u32 };

    pub const PointerWheel = struct { x: f32, y: f32 };

    window_close_requested: void,
    window_resized: WindowResized,
    key_down: KeyboardKey,
    key_up: KeyboardKey,
    text_input_preedit_changed: []const u8,
    text_input_changed: []const u8,
    pointer_button_down: PointerButton,
    pointer_button_up: PointerButton,
    pointer_motion: PointerMotion,
    pointer_wheel: PointerWheel,
};
