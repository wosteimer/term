const std = @import("std");
const Platform = @import("platform/root.zig").Platform;
const c = @import("c");
const Pool = @import("core/pool.zig").Pool;
const Handler = @import("core/pool.zig").Handler;
const Graphemes = @import("Graphemes");
const Emoji = @import("Emoji");
const code_point = @import("code_point");

const Self = @This();
const Render = @This();

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
    hb_font: ?*c.hb_font_t,
    scale_factor: f64,
    path: []const u8,

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
    codepoint: ?u21 = null,
    weight: Weight = .normal,
    italic: bool = false,
    size: u8,

    pub fn dupe(self: *const FontKey, allocator: std.mem.Allocator) !FontKey {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .codepoint = self.codepoint,
            .weight = self.weight,
            .italic = self.italic,
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
        if (key.codepoint) |codepoint| {
            h.update(&std.mem.toBytes(&codepoint));
        }
        h.update(&[_]u8{ @intFromEnum(key.weight), @intFromBool(key.italic), key.size });
        return h.final();
    }

    pub fn eql(ctx: Ctx, a: FontKey, b: FontKey) bool {
        _ = ctx;
        return std.mem.eql(u8, a.name, b.name) and
            a.codepoint == b.codepoint and
            a.weight == b.weight and
            a.italic == b.italic and
            a.size == b.size;
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
    path: []const u8,
    codepoint: u32,
};

const GlyphContext = struct {
    const Ctx = @This();

    pub fn hash(ctx: Ctx, key: GlyphKey) u64 {
        _ = ctx;
        var h = std.hash.Wyhash.init(0);
        h.update(key.path);
        h.update(std.mem.asBytes(&key.codepoint));
        return h.final();
    }

    pub fn eql(_: Ctx, a: GlyphKey, b: GlyphKey) bool {
        return a.codepoint == b.codepoint and std.mem.eql(u8, a.path, b.path);
    }
};

pub const Shaped = struct {
    pub const Glyph = struct {
        font_path: []const u8,
        codepoint: u32,
        advance: Point,
        offset: Point,
    };
    glyphs: []Shaped.Glyph,
    ascender: i32,
};

const Shaper = struct {
    font: *Font,
    fixed_advance: ?i32 = null,
    hb_buffer: ?*c.hb_buffer_t,
    infos: []c.hb_glyph_info_t,
    positions: []c.hb_glyph_position_t,
    i: usize = 0,

    pub fn init(
        font: *Font,
        features: []const []const u8,
        text: []const u8,
        start: usize,
        end: usize,
        fixed_advance: ?i32,
    ) !Shaper {
        const max_features = 32;
        var hb_features_buf: [max_features]c.hb_feature_t = undefined;
        const hb_features_len = @min(features.len, max_features);
        for (features[0..hb_features_len], 0..) |feature, i| {
            _ = c.hb_feature_from_string(feature.ptr, @intCast(feature.len), &hb_features_buf[i]);
        }
        const hb_features = hb_features_buf[0..hb_features_len];

        const hb_buffer = c.hb_buffer_create();
        c.hb_buffer_add_utf8(hb_buffer, text.ptr, @intCast(text.len), @intCast(start), @intCast(end - start));
        c.hb_buffer_guess_segment_properties(hb_buffer);
        c.hb_shape(
            @ptrCast(font.hb_font),
            hb_buffer,
            @ptrCast(hb_features.ptr),
            @intCast(hb_features.len),
        );

        var glyph_count: u32 = undefined;
        const c_infos = c.hb_buffer_get_glyph_infos(hb_buffer, &glyph_count);
        const infos = @as([*]c.hb_glyph_info_t, @ptrCast(c_infos))[0..@intCast(glyph_count)];
        const c_positions = c.hb_buffer_get_glyph_positions(hb_buffer, &glyph_count);
        const positions = @as([*]c.hb_glyph_position_t, @ptrCast(c_positions))[0..@intCast(glyph_count)];

        return .{
            .font = font,
            .fixed_advance = fixed_advance,
            .hb_buffer = hb_buffer,
            .infos = infos,
            .positions = positions,
        };
    }

    pub fn deinit(self: *Shaper) void {
        c.hb_buffer_destroy(self.hb_buffer);
    }

    pub fn next(self: *Shaper) !?Shaped.Glyph {
        if (self.i == self.infos.len) return null;

        const info = self.infos[self.i];
        const position = self.positions[self.i];

        const x_advance = self.calcXAdvance(position);
        const y_advance: i32 = applyFontScaleFactor(self.font, position.y_advance >> 6);
        const x_offset: i32 = applyFontScaleFactor(self.font, position.x_offset >> 6);
        const y_offset: i32 = applyFontScaleFactor(self.font, position.y_offset >> 6);

        const entry = Shaped.Glyph{
            .font_path = self.font.path,
            .codepoint = info.codepoint,
            .offset = .{
                .x = x_offset,
                .y = y_offset,
            },
            .advance = .{
                .x = x_advance,
                .y = y_advance,
            },
        };
        self.i += 1;

        return entry;
    }

    fn calcXAdvance(self: *Shaper, position: c.hb_glyph_position_t) i32 {
        var x_advance: i32 = applyFontScaleFactor(self.font, position.x_advance >> 6);
        if (self.fixed_advance) |fixed_advance_value| {
            if (fixed_advance_value < x_advance) {
                const x_advance_f32: f32 = @floatFromInt(x_advance);
                const fixed_advance_f32: f32 = @floatFromInt(fixed_advance_value);
                const ceil: i32 = @ceil(x_advance_f32 / fixed_advance_f32);
                x_advance = ceil * fixed_advance_value;
            } else {
                x_advance = fixed_advance_value;
            }
        }
        return x_advance;
    }
};

pub const Image = Handler;

const InternalImage = struct {
    allocator: ?std.mem.Allocator = null,
    buf: []u32,
    pixman_image: ?*c.pixman_image_t,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !InternalImage {
        const buf = try allocator.alloc(u32, width * height);
        var self = bufInit(buf, width, height);
        self.allocator = allocator;
        return self;
    }

    pub fn bufInit(buf: []u32, width: usize, height: usize) InternalImage {
        std.debug.assert(width * height <= buf.len);
        const stride = calcStride(@intCast(width), @bitSizeOf(u32));
        const pixman_image = c.pixman_image_create_bits(
            c.PIXMAN_a8r8g8b8,
            @intCast(width),
            @intCast(height),
            buf.ptr,
            stride,
        );
        std.debug.assert(pixman_image != null);
        return .{
            .buf = buf,
            .pixman_image = pixman_image,
        };
    }

    pub fn deinit(self: *const InternalImage) void {
        if (self.allocator) |allocator| {
            allocator.free(self.buf);
        }
        _ = c.pixman_image_unref(self.pixman_image);
    }

    pub fn fill(self: *const InternalImage, color: ARGB) void {
        _ = c.pixman_image_fill_rectangles(
            c.PIXMAN_OP_SRC,
            self.pixman_image,
            &argbToColor(color),
            1,
            &c.pixman_rectangle16{
                .x = 0,
                .y = 0,
                .width = @intCast(c.pixman_image_get_width(self.pixman_image)),
                .height = @intCast(c.pixman_image_get_height(self.pixman_image)),
            },
        );
    }

    pub fn drawRect(self: *const InternalImage, rect: Rect, color: ARGB) void {
        const width: i32 = @intCast(c.pixman_image_get_width(self.pixman_image));
        const height: i32 = @intCast(c.pixman_image_get_height(self.pixman_image));
        const x1 = std.math.clamp(rect.x, 0, width);
        const x2 = std.math.clamp(rect.x + @as(i32, @intCast(rect.width)), 0, width);
        const y1 = std.math.clamp(rect.y, 0, height);
        const y2 = std.math.clamp(rect.y + @as(i32, @intCast(rect.height)), 0, height);
        _ = c.pixman_image_fill_boxes(
            c.PIXMAN_OP_SRC,
            self.pixman_image,
            &argbToColor(color),
            1,
            &c.pixman_box32{
                .x1 = x1,
                .y1 = y1,
                .x2 = x2,
                .y2 = y2,
            },
        );
    }

    pub fn drawText(self: *const InternalImage, info: DrawTextInfo, cache: *FontCache) !void {
        var cursor = info.start;
        const main_font_key = FontKey{
            .name = info.font.name,
            .size = info.font.size,
            .italic = info.font.italic,
            .weight = info.font.weight,
        };
        const main_font = try cache.getFont(main_font_key);
        const ascender: i32 = @intCast(applyFontScaleFactor(
            main_font,
            main_font.*.ft_face.*.size.*.metrics.ascender >> 6,
        ));

        const emoji_font_key = FontKey{
            .name = "emoji",
            .size = info.font.size,
            .italic = info.font.italic,
            .weight = info.font.weight,
        };

        var fixed_advance: ?i32 = null;
        if (info.font.monospace) {
            const max_advance: i32 = @intCast(main_font.ft_face.*.size.*.metrics.max_advance >> 6);
            fixed_advance = applyFontScaleFactor(main_font, max_advance);
        }

        var font = main_font;
        var next_font_key = font;

        var iter = Graphemes.iterator(info.text);
        var finish_run: bool = false;
        var fallback: bool = false;
        var start: usize = 0;
        var end: usize = 0;

        while (iter.next()) |current| {
            const bytes = current.bytes(info.text);
            const codepoint = code_point.decodeAtIndex(bytes, 0).?.code;
            if (Emoji.isEmojiPresentation(codepoint)) {
                fallback = true;
                finish_run = true;
                const emoji_font = try cache.getFont(emoji_font_key);
                next_font_key = emoji_font;
            } else if (fallback and c.FT_Get_Char_Index(main_font.ft_face, codepoint) != 0) {
                fallback = false;
                finish_run = true;
                next_font_key = main_font;
            } else if (c.FT_Get_Char_Index(font.ft_face, codepoint) == 0) {
                fallback = true;
                finish_run = true;
                var next_key = main_font_key;
                next_key.codepoint = codepoint;
                next_font_key = try cache.getFont(next_key);
            }

            if (finish_run and start != end) {
                var shaper = try Shaper.init(font, info.font.features, info.text, start, end, fixed_advance);
                defer shaper.deinit();
                try self.drawShaper(.{
                    .shaper = &shaper,
                    .ascender = ascender,
                    .cursor = &cursor,
                    .color = info.color,
                    .cache = cache,
                });
                start = end;
            }

            finish_run = false;
            end += bytes.len;
            font = next_font_key;
        }

        if (start != end) {
            var shaper = try Shaper.init(font, info.font.features, info.text, start, end, fixed_advance);
            defer shaper.deinit();
            try self.drawShaper(.{
                .shaper = &shaper,
                .ascender = ascender,
                .cursor = &cursor,
                .color = info.color,
                .cache = cache,
            });
        }
    }

    pub const DrawShaperInfo = struct {
        shaper: *Shaper,
        cursor: *Point,
        ascender: i32,
        color: ARGB = @bitCast(@as(u32, 0xFFFFFFFF)),
        cache: *FontCache,
    };

    fn drawShaper(self: *const InternalImage, info: DrawShaperInfo) !void {
        const dst = self.pixman_image;
        const ascender = info.ascender;

        while (try info.shaper.next()) |shaped_glyph| {
            const font = info.cache.fonts.get(shaped_glyph.font_path).?;
            const glyph = try info.cache.getGlyph(font, shaped_glyph.codepoint);
            switch (glyph.render_mode) {
                .none => {},
                .color => {
                    c.pixman_image_composite32(
                        c.PIXMAN_OP_OVER,
                        info.cache.atlas,
                        null,
                        dst,
                        glyph.rect.x,
                        glyph.rect.y,
                        0,
                        0,
                        info.cursor.x + shaped_glyph.offset.x + glyph.left,
                        info.cursor.y + shaped_glyph.offset.y + (ascender - glyph.top),
                        @intCast(glyph.rect.width),
                        @intCast(glyph.rect.height),
                    );
                },
                .gray, .mono => {
                    const src = c.pixman_image_create_solid_fill(&argbToColor(info.color));
                    defer _ = c.pixman_image_unref(src);
                    c.pixman_image_composite32(
                        c.PIXMAN_OP_OVER,
                        src,
                        info.cache.atlas,
                        dst,
                        0,
                        0,
                        glyph.rect.x,
                        glyph.rect.y,
                        info.cursor.x + shaped_glyph.offset.x + glyph.left,
                        info.cursor.y + shaped_glyph.offset.y + (ascender - glyph.top),
                        @intCast(glyph.rect.width),
                        @intCast(glyph.rect.height),
                    );
                },
            }

            info.cursor.x += shaped_glyph.advance.x;
            info.cursor.y += shaped_glyph.advance.y;
        }
    }

    pub fn drawImage(self: *const InternalImage, src_image: *const InternalImage, src_offset: Point, dst_rect: Rect) void {
        const dst = self.pixman_image;
        const src = src_image.pixman_image;

        c.pixman_image_composite32(
            c.PIXMAN_OP_OVER,
            src,
            null,
            dst,
            @intCast(src_offset.x),
            @intCast(src_offset.y),
            0,
            0,
            @intCast(dst_rect.x),
            @intCast(dst_rect.y),
            @intCast(dst_rect.width),
            @intCast(dst_rect.height),
        );
    }
};

const FontCache = struct {
    const atlas_width = 4096;
    const atlas_height = 4096;

    arena: *std.heap.ArenaAllocator,
    ft: c.FT_Library,
    key_to_path: std.HashMap(FontKey, []const u8, FontContext, 70),
    fonts: std.StringHashMap(*Font),

    atlas_buf: []u32,
    atlas: ?*c.pixman_image_t = null,
    ctx: ?*c.stbrp_context = null,
    nodes: []c.stbrp_node,
    map: std.HashMap(GlyphKey, Glyph, GlyphContext, 70),

    pub fn init(allocator: std.mem.Allocator) !FontCache {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const arena_allocator = arena.allocator();
        var ft: c.FT_Library = undefined;
        _ = c.FT_Init_FreeType(&ft);
        _ = c.FcInit();
        var self = FontCache{
            .arena = arena,
            .ft = ft,
            .ctx = try arena_allocator.create(c.stbrp_context),
            .key_to_path = .init(arena_allocator),
            .fonts = .init(arena_allocator),
            .atlas_buf = try arena_allocator.alloc(u32, atlas_width * atlas_height),
            .nodes = try arena_allocator.alloc(c.stbrp_node, atlas_width),
            .map = .init(arena_allocator),
        };
        self.atlas = c.pixman_image_create_bits_no_clear(
            c.PIXMAN_a8r8g8b8,
            @intCast(atlas_width),
            @intCast(atlas_height),
            self.atlas_buf.ptr,
            calcStride(atlas_width, 32),
        );
        c.stbrp_init_target(
            self.ctx,
            @intCast(atlas_width),
            @intCast(atlas_height),
            self.nodes.ptr,
            @intCast(self.nodes.len),
        );
        return self;
    }

    pub fn deinit(self: *FontCache) void {
        var fonts = self.fonts.valueIterator();
        while (fonts.next()) |font| font.*.deinit();
        _ = c.pixman_image_unref(self.atlas);

        self.arena.deinit();
        const allocator = self.arena.child_allocator;
        allocator.destroy(self.arena);

        _ = c.FT_Done_FreeType(self.ft);
        c.FcFini();
    }

    const GetFontError = error{ OutOfMemory, InvalidFont };

    pub fn getFont(self: *FontCache, key: FontKey) GetFontError!*Font {
        if (self.key_to_path.get(key)) |path| {
            const font = self.fonts.get(path).?;
            return font;
        }

        const fc_pattern = createFcPattern(key);
        defer {
            var charset: ?*c.FcCharSet = undefined;
            if (c.FcPatternGetCharSet(fc_pattern, c.FC_CHARSET, 0, &charset) == c.FcResultMatch) {
                c.FcCharSetDestroy(charset);
            }
            c.FcPatternDestroy(fc_pattern);
        }
        var result: c.FcResult = undefined;
        const fc_font = c.FcFontMatch(null, fc_pattern, &result);
        if (result != c.FcResultMatch) {
            return error.InvalidFont;
        }
        defer c.FcPatternDestroy(fc_font);

        var fc_path: [*c]u8 = undefined;
        if (c.FcPatternGetString(fc_font, c.FC_FILE, 0, &fc_path) != c.FcResultMatch) {
            return error.InvalidFont;
        }

        const allocator = self.arena.allocator();
        const path = try allocator.dupe(u8, std.mem.span(fc_path));

        try self.key_to_path.put(try key.dupe(allocator), path);
        if (self.fonts.get(path)) |font| {
            return font;
        }

        const ft_face = try self.createFtFace(fc_font, key);

        log.debug("font \"{s} {d}\" loaded", .{ ft_face.*.family_name, key.size });

        const hb_font = c.hb_ft_font_create_referenced(ft_face);

        var scale_factor: f64 = undefined;
        if (c.FcPatternGetDouble(fc_font, "pixelsizefixupfactor", 0, &scale_factor) != c.FcResultMatch) {
            const font_size: f32 = @floatFromInt(key.size);
            const y_ppem: f32 = @floatFromInt(ft_face.*.size.*.metrics.y_ppem);
            scale_factor = font_size / y_ppem;
        }

        const font = try allocator.create(Font);
        font.* = .{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .scale_factor = scale_factor,
            .path = path,
        };
        try self.fonts.put(path, font);

        return font;
    }

    fn createFcPattern(key: FontKey) ?*c.FcPattern {
        const fc_pattern = c.FcPatternCreate();

        const name_max_len = 256;
        var name_buf: [name_max_len]u8 = undefined;
        const name_len: usize = @min(name_max_len, key.name.len);
        const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{key.name[0..name_len]}, 0) catch unreachable;
        _ = c.FcPatternAddString(fc_pattern, c.FC_FAMILY, name);

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

        if (key.codepoint != 0) {
            const charset = c.FcCharSetCreate();
            if (key.codepoint) |codepoint| {
                _ = c.FcCharSetAddChar(charset, codepoint);
            }
            _ = c.FcPatternAddCharSet(fc_pattern, c.FC_CHARSET, charset);
        }

        _ = c.FcConfigSubstitute(null, fc_pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(fc_pattern);

        return fc_pattern;
    }

    fn createFtFace(self: *FontCache, fc_font: ?*c.FcPattern, key: FontKey) error{InvalidFont}!c.FT_Face {
        var fc_path: [*c]u8 = undefined;
        if (c.FcPatternGetString(fc_font, c.FC_FILE, 0, &fc_path) != c.FcResultMatch) {
            return error.InvalidFont;
        }

        var index: i32 = undefined;
        if (c.FcPatternGetInteger(fc_font, c.FC_INDEX, 0, &index) != c.FcResultMatch) {
            return error.InvalidFont;
        }

        var ft_face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft, fc_path, index, &ft_face) != 0) {
            return error.InvalidFont;
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

        return ft_face;
    }

    const GetGlyphError = error{ GlyphNotFound, GlyphNotRendered, GlyphTooLarge, UnsupportedPixelMode } ||
        GetFontError;

    pub fn getGlyph(self: *FontCache, font: *Font, codepoint: u32) GetGlyphError!Glyph {
        const key = GlyphKey{ .path = font.path, .codepoint = codepoint };
        if (self.map.get(key)) |glyph| return glyph;

        if (c.FT_Load_Glyph(font.ft_face, codepoint, c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR) != 0) {
            return error.GlyphNotFound;
        }
        const slot = font.ft_face.*.glyph;
        if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) {
            return error.GlyphNotRendered;
        }

        const bitmap = slot.*.bitmap;
        const width: u32 = @intCast(bitmap.width);
        const height: u32 = @intCast(bitmap.rows);
        const pitch: usize = @intCast(bitmap.pitch);
        const top: i32 = applyFontScaleFactor(font, slot.*.bitmap_top);
        const left: i32 = applyFontScaleFactor(font, slot.*.bitmap_left);

        if (width == 0 or height == 0) {
            const glyph = Glyph{ .render_mode = .none, .rect = .{}, .top = 0, .left = 0 };
            try self.map.put(key, glyph);
            return glyph;
        }

        const rect = try self.packRect(applyFontScaleFactor(font, width), applyFontScaleFactor(font, height));
        var glyph = Glyph{
            .render_mode = .none,
            .rect = rect,
            .top = @intCast(top),
            .left = @intCast(left),
        };

        switch (bitmap.pixel_mode) {
            c.FT_PIXEL_MODE_BGRA => self.copyColorGlyphToAtlas(
                @ptrCast(@alignCast(bitmap.buffer)),
                width,
                height,
                font.scale_factor,
                &glyph,
            ),
            c.FT_PIXEL_MODE_GRAY => self.copyGrayGlyphToAtlas(bitmap.buffer, width, height, &glyph),
            c.FT_PIXEL_MODE_MONO => self.copyMonoGlyphToAtlas(bitmap.buffer, width, height, pitch, &glyph),
            else => return error.UnsupportedPixelMode,
        }

        try self.map.put(key, glyph);
        return glyph;
    }

    fn packRect(self: *FontCache, width: u32, height: u32) error{GlyphTooLarge}!Rect {
        var rect: c.stbrp_rect = .{
            .w = @intCast(width),
            .h = @intCast(height),
        };
        _ = c.stbrp_pack_rects(self.ctx, &rect, 1);
        if (rect.was_packed == 0) {
            c.stbrp_init_target(
                self.ctx,
                @intCast(atlas_width),
                @intCast(atlas_height),
                self.nodes.ptr,
                @intCast(self.nodes.len),
            );
            self.map.clearRetainingCapacity();
            _ = c.stbrp_pack_rects(self.ctx, &rect, 1);
            log.warn("Glyph cache is full, cleared", .{});
            if (rect.was_packed == 0) return error.GlyphTooLarge;
        }
        return .{
            .x = @intCast(rect.x),
            .y = @intCast(rect.y),
            .width = @intCast(rect.w),
            .height = @intCast(rect.h),
        };
    }

    fn copyColorGlyphToAtlas(
        self: *FontCache,
        buf: [*]u32,
        width: u32,
        height: u32,
        scale_factor: f64,
        glyph: *Glyph,
    ) void {
        glyph.render_mode = .color;

        const src = c.pixman_image_create_bits_no_clear(
            c.PIXMAN_a8r8g8b8,
            @intCast(width),
            @intCast(height),
            buf,
            calcStride(@intCast(width), 32),
        );
        defer _ = c.pixman_image_unref(src);

        setScale(src, scale_factor);

        c.pixman_image_composite32(
            c.PIXMAN_OP_SRC,
            src,
            null,
            self.atlas,
            0,
            0,
            0,
            0,
            glyph.rect.x,
            glyph.rect.y,
            @intCast(glyph.rect.width),
            @intCast(glyph.rect.height),
        );
    }

    fn setScale(src: ?*c.pixman_image, scale_factor: f64) void {
        var scale: c.pixman_transform = undefined;
        const inv_scale_factor = doubleToFixed(1 / scale_factor);
        c.pixman_transform_init_scale(&scale, inv_scale_factor, inv_scale_factor);
        _ = c.pixman_image_set_transform(src, &scale);
        const kernel = c.PIXMAN_KERNEL_BOX;
        var n_values: i32 = undefined;
        const values = c.pixman_filter_create_separable_convolution(
            &n_values,
            inv_scale_factor,
            inv_scale_factor,
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
    }

    fn copyGrayGlyphToAtlas(self: *FontCache, buf: [*]u8, width: u32, height: u32, glyph: *Glyph) void {
        glyph.render_mode = .gray;
        const stride: usize = @intCast(calcStride(@intCast(width), 8));
        var tmp_buf: [256 * 256]u8 = undefined;
        for (0..@intCast(height)) |y| {
            for (0..@intCast(width)) |x| {
                tmp_buf[y * stride + x] = buf[y * @as(usize, @intCast(width)) + x];
            }
        }
        const src = c.pixman_image_create_bits_no_clear(
            c.PIXMAN_a8,
            @intCast(width),
            @intCast(height),
            @ptrCast(@alignCast(&tmp_buf)),
            @intCast(stride),
        );
        defer _ = c.pixman_image_unref(src);

        c.pixman_image_composite32(
            c.PIXMAN_OP_SRC,
            src,
            null,
            self.atlas,
            0,
            0,
            0,
            0,
            glyph.rect.x,
            glyph.rect.y,
            @intCast(glyph.rect.width),
            @intCast(glyph.rect.height),
        );
    }

    fn copyMonoGlyphToAtlas(self: *FontCache, buf: [*]u8, width: u32, height: u32, pitch: usize, glyph: *Glyph) void {
        glyph.render_mode = .mono;

        const stride: usize = @intCast(calcStride(@intCast(width), 8));
        var tmp_buf: [256 * 256]u8 = undefined;
        for (0..@intCast(height)) |y| {
            for (0..@intCast(width)) |x| {
                const value = buf[y * pitch + x];
                tmp_buf[y * stride + x] = @bitReverse(value);
            }
        }
        const src = c.pixman_image_create_bits_no_clear(
            c.PIXMAN_a1,
            @intCast(width),
            @intCast(height),
            @ptrCast(@alignCast(&tmp_buf)),
            @intCast(stride),
        );
        defer _ = c.pixman_image_unref(src);

        c.pixman_image_composite32(
            c.PIXMAN_OP_SRC,
            src,
            null,
            self.atlas,
            0,
            0,
            0,
            0,
            glyph.rect.x,
            glyph.rect.y,
            @intCast(glyph.rect.width),
            @intCast(glyph.rect.height),
        );
    }
};

const image_pool_capacity = 64;

allocator: std.mem.Allocator,

platform: *Platform,
font_cache: FontCache,
image_pool: Pool(InternalImage),

pub fn init(allocator: std.mem.Allocator, platform: *Platform) !Self {
    return .{
        .allocator = allocator,
        .font_cache = try .init(allocator),
        .image_pool = try .init(allocator, image_pool_capacity),
        .platform = platform,
    };
}

pub fn deinit(self: *Self) void {
    self.image_pool.deinit(self.allocator);
    self.font_cache.deinit();
}

pub fn createImage(self: *Self, width: usize, height: usize) !Image {
    const handler = try self.image_pool.create();
    const entry = self.image_pool.getEntry(handler) catch unreachable;
    entry.value = try InternalImage.init(self.allocator, width, height);
    return handler;
}

pub fn createBufImage(self: *Self, buf: []u32, width: u32, height: u32) !Image {
    const handler = try self.image_pool.create();
    const entry = self.image_pool.getEntry(handler) catch unreachable;
    entry.value = InternalImage.bufInit(buf, width, height);
    return handler;
}

pub fn destroyImage(self: *Self, image: Image) !void {
    const entry = try self.image_pool.getEntry(image);
    entry.value.?.deinit();
    self.image_pool.destroy(image) catch unreachable;
}

pub fn startDraw(self: *Self) !?Image {
    if (self.platform.getBuffer()) |buf| {
        const size = self.platform.getSize();
        return try self.createBufImage(buf, size.width, size.height);
    }
    return null;
}

pub fn endDraw(self: *Self, image: Image) !void {
    try self.destroyImage(image);
    self.platform.present();
}

pub fn fill(self: *Self, image: Image, color: ARGB) !void {
    const entry = try self.image_pool.getEntry(image);
    const internal = entry.value.?;
    internal.fill(color);
}

pub fn drawRect(self: *Render, image: Image, rect: Rect, color: ARGB) !void {
    const entry = try self.image_pool.getEntry(image);
    const internal = entry.value.?;
    internal.drawRect(rect, color);
}

pub const DrawTextInfo = struct {
    pub const Font = struct {
        name: []const u8,
        size: u8,
        weight: Weight = .normal,
        italic: bool = false,
        features: []const []const u8 = &.{},
        monospace: bool = false,
    };
    font: DrawTextInfo.Font,
    start: Point = .{},
    color: ARGB = @bitCast(@as(u32, 0xFFFFFFFF)),
    text: []const u8,
};

pub fn drawText(self: *Self, image: Image, info: DrawTextInfo) !void {
    const entry = try self.image_pool.getEntry(image);
    const internal = entry.value.?;
    try internal.drawText(info, &self.font_cache);
}

pub fn drawImage(self: *Render, dst: Image, src: Image, src_offset: Point, dst_rect: Rect) !void {
    const dst_entry = try self.image_pool.getEntry(dst);
    const src_entry = try self.image_pool.getEntry(src);

    const dst_internal = dst_entry.value.?;
    const src_internal = src_entry.value.?;

    dst_internal.drawImage(&src_internal, src_offset, dst_rect);
}

pub const Metrics = struct {
    height: i32,
    max_advance: i32,
    ascender: i32,
    descender: i32,
};

pub const GetFontMetricsInfo = struct {
    name: []const u8,
    size: u8,
    weight: Weight = .normal,
    italic: bool = false,
};

pub fn getFontMetrics(self: *Render, info: GetFontMetricsInfo) !Metrics {
    const key = FontKey{
        .name = info.name,
        .size = info.size,
        .codepoint = 0,
        .weight = info.weight,
        .italic = info.italic,
    };
    const font = try self.font_cache.getFont(key);
    return .{
        .height = @intCast(font.ft_face.*.size.*.metrics.height >> 6),
        .max_advance = @intCast(font.ft_face.*.size.*.metrics.max_advance >> 6),
        .ascender = @intCast(font.ft_face.*.size.*.metrics.ascender >> 6),
        .descender = @intCast(font.ft_face.*.size.*.metrics.descender >> 6),
    };
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

inline fn applyFontScaleFactor(font: *Font, value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int => @intFromFloat(@as(f64, @floatFromInt(value)) * font.scale_factor),
        .float => value * font.scale_factor,
        else => @compileError("Invalid value"),
    };
}
