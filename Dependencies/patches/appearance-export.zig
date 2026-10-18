// Spookky's read-only appearance projection for the pinned Ghostty revision.
// Uses Ghostty's parser, conditional replay and formatter. No CLI arguments,
// application, surface or process are created from the source configuration.
export fn spookky_config_load_default_files(self: *Config) bool {
    const paths = @import("file_load.zig");
    const alloc = state.alloc;
    const xdg_old = paths.legacyDefaultXdgPath(alloc) catch return false;
    defer alloc.free(xdg_old);
    const xdg = paths.defaultXdgPath(alloc) catch return false;
    defer alloc.free(xdg);
    const mac_old = paths.legacyDefaultAppSupportPath(alloc) catch return false;
    defer alloc.free(mac_old);
    const mac = paths.preferredAppSupportPath(alloc) catch return false;
    defer alloc.free(mac);
    for ([_][]const u8{ xdg_old, xdg, mac_old }) |path| { _ = self.loadOptionalFile(alloc, path); }
    if (!std.mem.eql(u8, mac_old, mac)) { _ = self.loadOptionalFile(alloc, mac); }
    self.loadRecursiveFiles(alloc) catch return false;
    self.finalize() catch return false;
    return self._diagnostics.items().len == 0;
}

fn spookkyAppearanceKey(comptime name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "font-") or std.mem.startsWith(u8, name, "adjust-")) return true;
    for ([_][]const u8{ "background", "foreground", "palette", "bold-color", "background-opacity",
        "cursor-color", "cursor-opacity", "cursor-style", "cursor-style-blink", "cursor-text",
        "selection-background", "selection-foreground", "selection-invert-fg-bg",
        "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
        "alpha-blending", "minimum-contrast", "colorspace" }) |key_name| {
        if (std.mem.eql(u8, name, key_name)) return true;
    }
    return false;
}

export fn spookky_config_export_appearance(self: *Config, dark: bool) c.String {
    return spookkyAppearanceExport(self, dark) catch .empty;
}

fn spookkyAppearanceExport(self: *Config, dark: bool) !c.String {
    @setEvalBranchQuota(100_000);
    var changed = try self.changeConditionalState(.{ .theme = if (dark) .dark else .light });
    defer if (changed) |*value| value.deinit();
    const resolved = if (changed) |*value| value else self;
    if (resolved._diagnostics.items().len != 0) return error.InvalidConfiguration;
    var buffer: [262144]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime spookkyAppearanceKey(field.name)) {
            try @import("formatter.zig").formatEntry(field.type, field.name, @field(resolved.*, field.name), &writer);
        }
    }
    for (self.@"config-file".value.items) |entry| {
        const path = switch (entry) { inline else => |value| value };
        try writer.print("# spookky-watch={s}\n", .{path});
    }
    if (self.theme) |theme| {
        const arena = self._arena.?.allocator();
        for ([_][]const u8{theme.light, theme.dark}) |name| {
            if (try @import("theme.zig").open(arena, name, &self._diagnostics)) |opened| {
                defer opened.file.close();
                try writer.print("# spookky-watch={s}\n", .{opened.path});
            }
        }
    }
    return .fromSlice(try state.alloc.dupe(u8, writer.buffered()));
}
