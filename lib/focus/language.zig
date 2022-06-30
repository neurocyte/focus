const std = @import("std");
const focus = @import("../focus.zig");
const u = focus.util;
const c = focus.util.c;
const style = focus.style;

pub const clojure = @import("./language/clojure.zig");

pub const Language = enum {
    Zig,
    Java,
    Shell,
    Julia,
    Javascript,
    Nix,
    Clojure,
    Unknown,

    pub fn fromFilename(filename: []const u8) Language {
        // TODO writing this as `return if ...` causes a confusing compiler error
        if (std.mem.endsWith(u8, filename, ".zig"))
            return .Zig
        else if (std.mem.endsWith(u8, filename, ".java"))
            return .Java
        else if (std.mem.endsWith(u8, filename, ".sh"))
            return .Shell
        else if (std.mem.endsWith(u8, filename, ".jl"))
            return .Julia
        else if (std.mem.endsWith(u8, filename, ".js"))
            return .Javascript
        else if (std.mem.endsWith(u8, filename, ".nix"))
            return .Nix
        else if (std.mem.endsWith(u8, filename, ".clj") or std.mem.endsWith(u8, filename, ".cljs") or std.mem.endsWith(u8, filename, ".cljc"))
            return .Clojure
        else
            return .Unknown;
    }

    pub fn commentString(self: Language) ?[]const u8 {
        return switch (self) {
            .Zig, .Java, .Javascript => "//",
            .Shell, .Julia, .Nix => "#",
            .Clojure => ";",
            .Unknown => null,
        };
    }

    pub fn extendRangeToLineBoundary(source: []const u8, range: [2]usize) [2]usize {
        var extended_range = range;
        while (extended_range[0] > 0 and source[extended_range[0] - 1] != '\n') extended_range[0] -= 1;
        while (extended_range[1] < source.len and source[extended_range[1]] != '\n') extended_range[1] += 1;
        return extended_range;
    }

    pub fn highlight(self: Language, allocator: u.Allocator, source: []const u8, init_range: [2]usize) []const u.Color {
        const range = extendRangeToLineBoundary(source, init_range);
        const colors = allocator.alloc(u.Color, range[1] - range[0]) catch u.oom();
        switch (self) {
            .Zig => {
                const source_z = allocator.dupeZ(u8, source[range[0]..range[1]]) catch u.oom();
                defer allocator.free(source_z);
                var tokenizer = std.zig.Tokenizer.init(source_z);
                std.mem.set(u.Color, colors, style.comment_color);
                while (true) {
                    var token = tokenizer.next();
                    switch (token.tag) {
                        .eof => break,
                        .doc_comment, .container_doc_comment => {},
                        .identifier, .builtin, .integer_literal, .float_literal => std.mem.set(
                            u.Color,
                            colors[token.loc.start..token.loc.end],
                            style.identColor(tokenizer.buffer[token.loc.start..token.loc.end]),
                        ),
                        .keyword_try, .keyword_catch => std.mem.set(
                            u.Color,
                            colors[token.loc.start..token.loc.end],
                            style.emphasisRed,
                        ),
                        .keyword_defer, .keyword_errdefer => std.mem.set(
                            u.Color,
                            colors[token.loc.start..token.loc.end],
                            style.emphasisOrange,
                        ),
                        .keyword_break, .keyword_continue, .keyword_return => std.mem.set(
                            u.Color,
                            colors[token.loc.start..token.loc.end],
                            style.emphasisGreen,
                        ),
                        else => std.mem.set(
                            u.Color,
                            colors[token.loc.start..token.loc.end],
                            style.keyword_color,
                        ),
                    }
                }
            },
            .Clojure => {
                var tokenizer = clojure.Tokenizer.init(source);
                std.mem.set(u.Color, colors, style.comment_color);
                while (true) {
                    const source_start = tokenizer.pos;
                    const token = tokenizer.next();
                    const source_end = tokenizer.pos;
                    if (token == .eof) break;
                    if (source_end < range[0] or source_start > range[1]) continue;
                    const colors_start = if (source_start > range[0]) source_start - range[0] else 0;
                    const colors_end = if (source_end > range[1]) range[1] - range[0] else source_end - range[0];
                    switch (token) {
                        .err => std.mem.set(
                            u.Color,
                            colors[colors_start..colors_end],
                            style.emphasisRed,
                        ),
                        .symbol, .keyword => std.mem.set(
                            u.Color,
                            colors[colors_start..colors_end],
                            style.identColor(source[source_start..source_end]),
                        ),
                        .comment => {},
                        else => std.mem.set(
                            u.Color,
                            colors[colors_start..colors_end],
                            style.keyword_color,
                        ),
                    }
                }
            },
            else => {
                std.mem.set(u.Color, colors, style.text_color);
            },
        }
        return colors[init_range[0] - range[0] ..];
    }

    fn isLikeIdent(self: Language, char: u8, is_first_char: bool) bool {
        return switch (self) {
            // https://clojure.org/reference/reader#_symbols
            .Clojure => switch (char) {
                'a'...'z', 'A'...'Z', '*', '+', '!', '-', '_', '\'', '?', '<', '>', '=' => true,
                // not technically true, but useful to treat keywords as whole tokens
                ':' => true,
                '0'...'9' => !is_first_char,
                else => false,
            },
            // generic
            else => switch (char) {
                'a'...'z', 'A'...'Z', '_' => true,
                '0'...'9' => !is_first_char,
                else => false,
            },
        };
    }

    pub fn getTokenRanges(self: Language, allocator: u.Allocator, source: []const u8, init_range: [2]usize) []const [2]usize {
        const range = extendRangeToLineBoundary(source, init_range);
        var token_ranges = u.ArrayList([2]usize).init(allocator);
        defer token_ranges.deinit();
        switch (self) {
            .Zig => {
                const source_z = allocator.dupeZ(u8, source[range[0]..range[1]]) catch u.oom();
                defer allocator.free(source_z);
                var tokenizer = std.zig.Tokenizer.init(source_z);
                while (true) {
                    var token = tokenizer.next();
                    if (token.loc.end > token.loc.start and source_z[token.loc.end - 1] == '\n')
                        // make sure that no tokens include the \n
                        token.loc.end -= 1;
                    switch (token.tag) {
                        .eof => break,
                        else => token_ranges.append(.{
                            range[0] + token.loc.start,
                            range[0] + token.loc.end,
                        }) catch u.oom(),
                    }
                }
            },
            else => {
                var start: usize = range[0];
                while (start < range[1]) {
                    var end = start;
                    while (end < range[1] and self.isLikeIdent(source[end], start == end)) : (end += 1) {}
                    if (end > start) token_ranges.append(.{ start, end }) catch u.oom();
                    start = end + 1;
                    while (start < range[1] and !self.isLikeIdent(source[start], start == end)) : (start += 1) {}
                }
            },
        }
        return token_ranges.toOwnedSlice();
    }

    pub fn getTokens(self: Language, allocator: u.Allocator, source: []const u8, range: [2]usize) []const []const u8 {
        const token_ranges = self.getTokenRanges(allocator, source, range);
        defer allocator.free(token_ranges);
        var tokens = u.ArrayList([]const u8).init(allocator);
        for (token_ranges) |token_range| {
            const token = allocator.dupe(u8, source[token_range[0]..token_range[1]]) catch u.oom();
            tokens.append(token) catch u.oom();
        }
        return tokens.toOwnedSlice();
    }

    pub fn getTokenRangeAround(self: Language, allocator: u.Allocator, source: []const u8, pos: usize) ?[2]usize {
        const token_ranges = self.getTokenRanges(allocator, source, .{ pos, pos });
        defer allocator.free(token_ranges);
        for (token_ranges) |token_range| {
            if (token_range[0] <= pos and pos <= token_range[1]) return token_range;
        }
        return null;
    }

    pub fn format(self: Language, allocator: u.Allocator, source: []const u8) ?[]const u8 {
        switch (self) {
            .Zig => {
                const source_z = allocator.dupeZ(u8, source) catch u.oom();
                defer allocator.free(source_z);
                var tree = std.zig.parse(allocator, source_z) catch u.oom();
                if (tree.errors.len > 0) return null;
                defer tree.deinit(allocator);
                return tree.render(allocator) catch u.oom();
            },
            else => return null,
        }
    }
};
