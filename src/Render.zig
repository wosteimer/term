const std = @import("std");
const Platform = @import("platform").Platform;
const c = @import("c");
const unicode = @import("unicode");

const Self = @This();

const log = std.log.scoped(.render);

pub const ARGB = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn eq(self: ARGB, other: ARGB) bool {
        return self.a == other.a and self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

const Font = struct {
    ft_face: c.FT_Face,
    hb_features: []c.hb_feature_t,
    hb_font: ?*c.hb_font_t,
    scale_factor: f64,
    fallbacks: [][]const u8,

    pub fn deinit(self: *Font) void {
        _ = c.FT_Done_Face(self.ft_face);
        c.hb_font_destroy(self.hb_font);
    }
};

pub const Weight = enum(u8) {
    thin,
    extralight,
    ultralight,
    light,
    demilight,
    semilight,
    book,
    regular,
    normal,
    medium,
    demibold,
    semibold,
    bold,
    extrabold,
    ultrabold,
    black,
    heavy,
    extrablack,
    ultrablack,
};

pub const FontKey = struct {
    name: []const u8,
    weight: Weight = .normal,
    italic: bool = false,
    features: []const []const u8 = &.{},
    size: u8,

    pub fn dupe(self: *const FontKey, allocator: std.mem.Allocator) !FontKey {
        const features = try allocator.alloc([]const u8, self.features.len);
        for (self.features, 0..) |feature, i| {
            features[i] = try allocator.dupe(u8, feature);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .weight = self.weight,
            .italic = self.italic,
            .features = features,
            .size = self.size,
        };
    }
};

const FontContext = struct {
    const Ctx = @This();

    pub fn hash(ctx: Ctx, key: FontKey) u64 {
        _ = ctx;
        var h = std.hash.Wyhash.init(0);
        h.update(key.name);
        h.update(&[_]u8{ @intFromEnum(key.weight), @intFromBool(key.italic), key.size });
        for (key.features) |feature| {
            h.update(feature);
        }
        return h.final();
    }

    pub fn eql(ctx: Ctx, a: FontKey, b: FontKey) bool {
        _ = ctx;
        if (!(std.mem.eql(u8, a.name, b.name) and
            a.weight == b.weight and
            a.italic == b.italic and
            a.size == b.size)) return false;
        if (a.features.len != b.features.len) return false;
        for (a.features, b.features) |a_feat, b_feat| {
            if (!std.mem.eql(u8, a_feat, b_feat)) return false;
        }
        return true;
    }
};

const RenderMode = enum { color, gray, mono, none };

const Glyph = struct {
    render_mode: RenderMode,
    rect: Rect,
    top: i32,
    left: i32,
};

const GlyphKey = struct {
    font_key: FontKey,
    condepoint: u32,
};

const GlyphContext = struct {
    const Ctx = @This();

    pub fn hash(ctx: Ctx, key: GlyphKey) u64 {
        _ = ctx;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&FontContext.hash(.{}, key.font_key)));
        h.update(std.mem.asBytes(&key.condepoint));
        return h.final();
    }

    pub fn eql(_: Ctx, a: GlyphKey, b: GlyphKey) bool {
        return a.condepoint == b.condepoint and FontContext.eql(.{}, a.font_key, b.font_key);
    }
};

const atlas_width = 4096;
const atlas_height = 4096;

arena: *std.heap.ArenaAllocator,
platform: *Platform,
ft: c.FT_Library,
fonts: std.HashMap(FontKey, *Font, FontContext, 70),

cache_atlas_buf: []u32,
cache_atlas: ?*c.pixman_image_t = null,
cache_ctx: ?*c.stbrp_context = null,
cache_nodes: []c.stbrp_node,
cache_map: std.HashMap(GlyphKey, Glyph, GlyphContext, 70),

pub fn init(allocator: std.mem.Allocator, platform: *Platform) !Self {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const arena_allocator = arena.allocator();
    var ft: c.FT_Library = undefined;
    _ = c.FT_Init_FreeType(&ft);
    _ = c.FcInit();
    var self = Self{
        .arena = arena,
        .platform = platform,
        .ft = ft,
        .cache_ctx = try arena_allocator.create(c.stbrp_context),
        .fonts = .init(arena_allocator),
        .cache_atlas_buf = try arena_allocator.alloc(u32, atlas_width * atlas_height),
        .cache_nodes = try arena_allocator.alloc(c.stbrp_node, atlas_width),
        .cache_map = .init(arena_allocator),
    };
    // @memset(self.cache_atlas_buf, 0xFF000000);
    self.cache_atlas = c.pixman_image_create_bits_no_clear(
        c.PIXMAN_a8r8g8b8,
        @intCast(atlas_width),
        @intCast(atlas_height),
        self.cache_atlas_buf.ptr,
        calcStride(atlas_width, 32),
    );
    c.stbrp_init_target(
        self.cache_ctx,
        @intCast(atlas_width),
        @intCast(atlas_height),
        self.cache_nodes.ptr,
        @intCast(self.cache_nodes.len),
    );
    return self;
}

pub fn deinit(self: *Self) void {
    var fonts = self.fonts.valueIterator();
    while (fonts.next()) |font| font.*.deinit();
    _ = c.pixman_image_unref(self.cache_atlas);

    self.arena.deinit();
    const allocator = self.arena.child_allocator;
    allocator.destroy(self.arena);

    _ = c.FT_Done_FreeType(self.ft);
    c.FcFini();
}

pub const RenderTextInfo = struct {
    font: FontKey,
    rect: Rect = .{},
    monospace: bool = false,
    color: ARGB = .{ .a = 255, .r = 255, .g = 255, .b = 255 },
    text: []const u8,
};

pub fn renderText(self: *Self, info: RenderTextInfo) !void {
    var cursor = Point{ .x = info.rect.x, .y = info.rect.y + info.font.size };
    const size = self.platform.getSize();
    const platform_buf = self.platform.getBuffer();
    const dst = c.pixman_image_create_bits_no_clear(
        c.PIXMAN_a8r8g8b8,
        @intCast(size.width),
        @intCast(size.height),
        @ptrCast(platform_buf),
        calcStride(@intCast(size.width), 32),
    );
    defer _ = c.pixman_image_unref(dst);

    const main_font = try self.getFont(info.font);
    const advance = main_font.ft_face.*.size.*.metrics.max_advance >> 6;
    var fixed_advance: ?i32 = null;
    if (info.monospace) {
        fixed_advance = @intFromFloat(@as(f64, @floatFromInt(advance)) * main_font.scale_factor);
    }
    const emoji = FontKey{
        .name = "emoji",
        .size = info.font.size,
        .italic = info.font.italic,
        .weight = info.font.weight,
        .features = info.font.features,
    };
    var run_font_key = info.font;
    var next_font_key = info.font;
    var finish_run = false;
    var font_kind: enum { main, fallback } = .main;
    var start: usize = 0;
    var end: usize = 0;
    var buf: [64]u21 = undefined;
    var iter = unicode.GraphemeIter.bufInit(&buf, info.text);

    while (try iter.next()) |current| {
        const grapheme, const rune = .{ current.grapheme, current.rune };
        const run_font = try self.getFont(run_font_key);
        switch (font_kind) {
            .main => {
                if (c.FT_Get_Char_Index(main_font.ft_face, grapheme[0]) == 0) {
                    finish_run = true;
                    font_kind = .fallback;
                    if (unicode.isEmoji(grapheme)) {
                        next_font_key = emoji;
                    } else {
                        next_font_key = try self.findFallback(info.font, grapheme[0]);
                    }
                }
            },
            .fallback => {
                if (c.FT_Get_Char_Index(main_font.ft_face, grapheme[0]) != 0) {
                    finish_run = true;
                    font_kind = .main;
                    next_font_key = info.font;
                } else if (c.FT_Get_Char_Index(run_font.ft_face, grapheme[0]) == 0) {
                    finish_run = true;
                    next_font_key = try self.findFallback(info.font, grapheme[0]);
                }
            },
        }

        if (finish_run and start != end) {
            try self.renderRun(run_font_key, info.text[start..end], fixed_advance, info.color, dst, &cursor);
            start = end;
            run_font_key = next_font_key;
            finish_run = false;
        }

        end += rune.len;
    }
    if (start != end) try self.renderRun(
        run_font_key,
        info.text[start..end],
        fixed_advance,
        info.color,
        dst,
        &cursor,
    );
}

fn findFallback(self: *Self, key: FontKey, codepoint: u21) !FontKey {
    const font = try self.getFont(key);
    for (font.fallbacks) |fallback_name| {
        const fallback_key = FontKey{
            .name = fallback_name,
            .size = key.size,
            .features = key.features,
            .italic = key.italic,
            .weight = key.weight,
        };
        const fallback = try self.getFont(fallback_key);
        if (c.FT_Get_Char_Index(@ptrCast(fallback.ft_face), codepoint) != 0) {
            return fallback_key;
        }
    }
    return key;
}

fn renderRun(
    self: *Self,
    key: FontKey,
    run: []const u8,
    fixed_advance: ?i32,
    color: ARGB,
    dst: ?*c.pixman_image_t,
    cursor: *Point,
) !void {
    const font = try self.getFont(key);
    const hb_buf = c.hb_buffer_create();
    defer c.hb_buffer_destroy(hb_buf);
    c.hb_buffer_add_utf8(hb_buf, run.ptr, @intCast(run.len), 0, -1);
    c.hb_buffer_guess_segment_properties(hb_buf);
    c.hb_shape(
        @ptrCast(font.hb_font),
        hb_buf,
        @ptrCast(font.hb_features.ptr),
        @intCast(font.hb_features.len),
    );
    var glyph_count: u32 = undefined;
    const c_glyph_info = c.hb_buffer_get_glyph_infos(hb_buf, &glyph_count);
    const glyph_info = @as([*]c.hb_glyph_info_t, @ptrCast(c_glyph_info))[0..@intCast(glyph_count)];
    const c_glyph_pos = c.hb_buffer_get_glyph_positions(hb_buf, &glyph_count);
    const glyph_pos = @as([*]c.hb_glyph_position_t, @ptrCast(c_glyph_pos))[0..@intCast(glyph_count)];
    for (glyph_info, glyph_pos) |info, pos| {
        const glyph = try self.getGlyph(key, info.codepoint);
        var x_advance: i32 = @intFromFloat(@as(f64, @floatFromInt(pos.x_advance >> 6)) * font.scale_factor);
        const y_advance: i32 = @intFromFloat(@as(f64, @floatFromInt(pos.y_advance >> 6)) * font.scale_factor);
        const x_offset: i32 = @intFromFloat(@as(f64, @floatFromInt(pos.x_offset >> 6)) * font.scale_factor);
        const y_offset: i32 = @intFromFloat(@as(f64, @floatFromInt(pos.y_offset >> 6)) * font.scale_factor);
        switch (glyph.render_mode) {
            .none => {},
            .color => {
                c.pixman_image_composite32(
                    c.PIXMAN_OP_OVER,
                    self.cache_atlas,
                    null,
                    dst,
                    glyph.rect.x,
                    glyph.rect.y,
                    0,
                    0,
                    cursor.x + glyph.left + x_offset,
                    cursor.y - glyph.top + y_offset,
                    @intCast(glyph.rect.width),
                    @intCast(glyph.rect.height),
                );
            },
            .gray, .mono => {
                const src = c.pixman_image_create_solid_fill(&argbToColor(color));
                defer _ = c.pixman_image_unref(src);
                c.pixman_image_composite32(
                    c.PIXMAN_OP_OVER,
                    src,
                    self.cache_atlas,
                    dst,
                    0,
                    0,
                    glyph.rect.x,
                    glyph.rect.y,
                    cursor.x + glyph.left + x_offset,
                    cursor.y - glyph.top + y_offset,
                    @intCast(glyph.rect.width),
                    @intCast(glyph.rect.height),
                );
            },
        }
        if (fixed_advance) |advance| {
            if (advance < x_advance) {
                x_advance = @intFromFloat(@ceil(@as(f32, @floatFromInt(x_advance)) /
                    @as(f32, @floatFromInt(advance))) *
                    @as(f32, @floatFromInt(advance)));
            } else {
                x_advance = advance;
            }
        }
        cursor.x += x_advance;
        cursor.y += y_advance;
    }
}

fn getFont(self: *Self, key: FontKey) !*Font {
    if (self.fonts.get(key)) |font| return font;

    const fc_pattern = c.FcPatternCreate();
    defer c.FcPatternDestroy(fc_pattern);
    var buf: [4096]u8 = undefined;
    _ = c.FcPatternAddString(fc_pattern, c.FC_FAMILY, try std.fmt.bufPrintSentinel(&buf, "{s}", .{key.name}, 0));
    _ = c.FcPatternAddDouble(fc_pattern, c.FC_PIXEL_SIZE, @floatFromInt(key.size));
    _ = c.FcPatternAddInteger(fc_pattern, c.FC_WEIGHT, switch (key.weight) {
        .thin => c.FC_WEIGHT_THIN,
        .extralight => c.FC_WEIGHT_EXTRALIGHT,
        .ultralight => c.FC_WEIGHT_ULTRALIGHT,
        .light => c.FC_WEIGHT_LIGHT,
        .demilight => c.FC_WEIGHT_DEMILIGHT,
        .semilight => c.FC_WEIGHT_SEMILIGHT,
        .book => c.FC_WEIGHT_BOOK,
        .regular => c.FC_WEIGHT_REGULAR,
        .normal => c.FC_WEIGHT_NORMAL,
        .medium => c.FC_WEIGHT_MEDIUM,
        .demibold => c.FC_WEIGHT_DEMIBOLD,
        .semibold => c.FC_WEIGHT_SEMIBOLD,
        .bold => c.FC_WEIGHT_BOLD,
        .extrabold => c.FC_WEIGHT_EXTRABOLD,
        .ultrabold => c.FC_WEIGHT_ULTRABOLD,
        .black => c.FC_WEIGHT_BLACK,
        .heavy => c.FC_WEIGHT_HEAVY,
        .extrablack => c.FC_WEIGHT_EXTRABLACK,
        .ultrablack => c.FC_WEIGHT_ULTRABLACK,
    });
    if (key.italic) {
        _ = c.FcPatternAddInteger(fc_pattern, c.FC_SLANT, c.FC_SLANT_ITALIC);
    }

    _ = c.FcConfigSubstitute(null, fc_pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(fc_pattern);

    var result: c.FcResult = undefined;
    const set = c.FcFontSort(null, fc_pattern, c.FcTrue, null, &result);
    defer c.FcFontSetDestroy(set);
    if (result != c.FcResultMatch) {
        return error.FontNotFound;
    }

    var fc_path: [*c]u8 = undefined;
    const fc_font = set.*.fonts[0];
    if (c.FcPatternGetString(fc_font, c.FC_FILE, 0, &fc_path) != c.FcResultMatch) {
        return error.FileNotFound;
    }

    var index: i32 = undefined;
    if (c.FcPatternGetInteger(fc_font, c.FC_INDEX, 0, &index) != c.FcResultMatch) {
        return error.FileNotFound;
    }

    var ft_face: c.FT_Face = undefined;
    if (c.FT_New_Face(self.ft, fc_path, index, &ft_face) != 0) {
        return error.FreeTypeError;
    }
    if (ft_face.*.num_fixed_sizes > 0 and !c.FT_IS_SCALABLE(ft_face)) {
        var best: c_int = 0;
        var best_diff = @abs(ft_face.*.available_sizes[0].height - key.size);
        for (1..@intCast(ft_face.*.num_fixed_sizes)) |i| {
            const h = ft_face.*.available_sizes[i].height;
            const diff = @abs(h - key.size);
            if (diff < best_diff) {
                best = @intCast(i);
                best_diff = diff;
            }
        }
        _ = c.FT_Select_Size(ft_face, best);
    } else {
        _ = c.FT_Set_Pixel_Sizes(ft_face, 0, key.size);
    }

    const allocator = self.arena.allocator();

    const num_fonts: usize = @intCast(set.*.nfont - 1);
    var fallbacks = try allocator.alloc([]const u8, num_fonts);
    for (set.*.fonts[1..num_fonts], 0..) |fc_fallback, i| {
        var full_name: [*c]u8 = undefined;
        if (c.FcPatternGetString(fc_fallback, c.FC_FULLNAME, 0, &full_name) != c.FcResultMatch) {
            return error.FileNotFound;
        }
        fallbacks[i] = try allocator.dupe(u8, std.mem.span(full_name));
    }
    const hb_font = c.hb_ft_font_create_referenced(ft_face);
    const hb_features = try allocator.alloc(c.hb_feature_t, key.features.len);
    for (key.features, 0..) |feature, i| {
        _ = c.hb_feature_from_string(feature.ptr, @intCast(feature.len), &hb_features[i]);
    }

    var scale_factor: f64 = undefined;
    if (c.FcPatternGetDouble(fc_font, "pixelsizefixupfactor", 0, &scale_factor) != c.FcResultMatch) {
        scale_factor = @as(f32, @floatFromInt(key.size)) /
            @as(f32, @floatFromInt(ft_face.*.size.*.metrics.y_ppem));
    }

    const font = try allocator.create(Font);
    font.* = .{
        .ft_face = ft_face,
        .hb_font = hb_font,
        .hb_features = hb_features,
        .fallbacks = fallbacks,
        .scale_factor = scale_factor,
    };

    try self.fonts.put(try key.dupe(allocator), font);
    log.debug("font \"{s} {d}\" loaded", .{ ft_face.*.family_name, key.size });
    return font;
}

pub fn getGlyph(self: *Self, font_key: FontKey, codepoint: u32) !Glyph {
    const key: GlyphKey = .{ .font_key = font_key, .condepoint = codepoint };
    const font = try self.getFont(font_key);

    if (self.cache_map.get(key)) |glyph| return glyph;

    _ = c.FT_Load_Glyph(font.ft_face, codepoint, c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR);
    const slot = font.ft_face.*.glyph;
    _ = c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL);

    const bitmap = slot.*.bitmap;
    const width: c_int = @intCast(bitmap.width);
    const height: c_int = @intCast(bitmap.rows);
    const top: i32 = @intFromFloat(@as(f64, @floatFromInt(slot.*.bitmap_top)) * font.scale_factor);
    const left: i32 = @intFromFloat(@as(f64, @floatFromInt(slot.*.bitmap_left)) * font.scale_factor);

    if (width == 0 or height == 0) {
        const glyph = Glyph{ .render_mode = .none, .rect = .{}, .top = 0, .left = 0 };
        try self.cache_map.put(key, glyph);
        return glyph;
    }

    var rect: c.stbrp_rect = .{
        .w = @intFromFloat(@as(f64, @floatFromInt(width)) * font.scale_factor),
        .h = @intFromFloat(@as(f64, @floatFromInt(height)) * font.scale_factor),
    };

    _ = c.stbrp_pack_rects(self.cache_ctx, &rect, 1);
    if (rect.was_packed == 0) {
        c.stbrp_init_target(
            self.cache_ctx,
            @intCast(atlas_width),
            @intCast(atlas_height),
            self.cache_nodes.ptr,
            @intCast(self.cache_nodes.len),
        );
        self.cache_map.clearRetainingCapacity();
        _ = c.stbrp_pack_rects(self.cache_ctx, &rect, 1);
        log.warn("Glyph cache is full, cleared", .{});
        if (rect.was_packed == 0) return error.GlyphTooLarge;
    }
    var glyph = Glyph{
        .render_mode = .none,
        .rect = .{
            .x = @intCast(rect.x),
            .y = @intCast(rect.y),
            .width = @intCast(rect.w),
            .height = @intCast(rect.h),
        },
        .top = @intCast(top),
        .left = @intCast(left),
    };

    switch (bitmap.pixel_mode) {
        c.FT_PIXEL_MODE_BGRA => {
            glyph.render_mode = .color;

            const src = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a8r8g8b8,
                width,
                height,
                @ptrCast(@alignCast(bitmap.buffer)),
                calcStride(width, 32),
            );
            defer _ = c.pixman_image_unref(src);

            var scale: c.pixman_transform = undefined;
            const scale_factor = doubleToFixed(1 / font.scale_factor);
            c.pixman_transform_init_scale(&scale, scale_factor, scale_factor);
            _ = c.pixman_image_set_transform(src, &scale);
            const kernel = c.PIXMAN_KERNEL_BOX;
            var n_values: i32 = undefined;
            const values = c.pixman_filter_create_separable_convolution(
                &n_values,
                scale_factor,
                scale_factor,
                kernel,
                kernel,
                kernel,
                kernel,
                1,
                1,
            );
            defer c.free(values);
            _ = c.pixman_image_set_filter(
                src,
                c.PIXMAN_FILTER_SEPARABLE_CONVOLUTION,
                values,
                n_values,
            );
            c.pixman_image_composite32(
                c.PIXMAN_OP_SRC,
                src,
                null,
                self.cache_atlas,
                0,
                0,
                0,
                0,
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            );
        },
        c.FT_PIXEL_MODE_GRAY => {
            glyph.render_mode = .gray;
            const stride: usize = @intCast(calcStride(width, 8));
            var buf: [256 * 256]u8 = undefined;
            for (0..@intCast(height)) |y| {
                for (0..@intCast(width)) |x| {
                    buf[y * stride + x] = bitmap.buffer[y * @as(usize, @intCast(width)) + x];
                }
            }
            const src = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a8,
                @intCast(width),
                @intCast(height),
                @ptrCast(@alignCast(&buf)),
                @intCast(stride),
            );
            defer _ = c.pixman_image_unref(src);

            c.pixman_image_composite32(
                c.PIXMAN_OP_SRC,
                src,
                null,
                self.cache_atlas,
                0,
                0,
                0,
                0,
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            );
        },
        c.FT_PIXEL_MODE_MONO => {
            glyph.render_mode = .mono;

            const stride: usize = @intCast(calcStride(width, 8));
            var buf: [256 * 256]u8 = undefined;
            for (0..@intCast(height)) |y| {
                for (0..@intCast(width)) |x| {
                    const pitch: usize = @intCast(bitmap.pitch);
                    const value = bitmap.buffer[y * pitch + x];
                    buf[y * stride + x] = @bitReverse(value);
                }
            }
            const src = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a1,
                @intCast(width),
                @intCast(height),
                @ptrCast(@alignCast(&buf)),
                @intCast(stride),
            );
            defer _ = c.pixman_image_unref(src);

            c.pixman_image_composite32(
                c.PIXMAN_OP_SRC,
                src,
                null,
                self.cache_atlas,
                0,
                0,
                0,
                0,
                rect.x,
                rect.y,
                rect.w,
                rect.h,
            );
        },
        else => return error.UnsupportedPixelMode,
    }

    try self.cache_map.put(key, glyph);
    return glyph;
}

inline fn doubleToFixed(d: f64) c.pixman_fixed_t {
    return @intFromFloat(d * 65536.0);
}

inline fn calcStride(width: c_int, bits_per_pixel: c_int) c_int {
    const bits = width * bits_per_pixel;
    const aligned_bits = (bits + 31) & ~@as(c_int, 31);
    return @divExact(aligned_bits, 8);
}

inline fn argbToColor(color: ARGB) c.pixman_color_t {
    return .{
        .alpha = @as(u16, @intCast(color.a)) << 8,
        .red = @as(u16, @intCast(color.r)) << 8,
        .green = @as(u16, @intCast(color.g)) << 8,
        .blue = @as(u16, @intCast(color.b)) << 8,
    };
}
