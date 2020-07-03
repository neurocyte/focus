const focus = @import("../focus.zig");
usingnamespace focus.common;
const Window = focus.Window;

pub const Buffer = struct {
    allocator: *Allocator,
    bytes: ArrayList(u8),

    pub fn init(allocator: *Allocator) Buffer {
        return Buffer{
            .allocator = allocator,
            .bytes = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit();
    }

    pub fn getBufferEnd(self: *Buffer) usize {
        return self.bytes.items.len;
    }

    pub fn getPosForLine(self: *Buffer, line: usize) usize {
        var pos: usize = 0;
        var lines_remaining = line;
        while (lines_remaining > 0) : (lines_remaining -= 1) {
            pos = if (self.searchForwards(pos, "\n")) |next_pos| next_pos + 1 else self.bytes.items.len;
        }
        return pos;
    }

    pub fn getPosForLineCol(self: *Buffer, line: usize, col: usize) usize {
        var pos = self.getPosForLine(line);
        const end = if (self.searchForwards(pos, "\n")) |line_end| line_end else self.bytes.items.len;
        pos += min(col, end - pos);
        return pos;
    }

    pub fn getLineColForPos(self: *Buffer, pos: usize) [2]usize {
        var line: usize = 0;
        const col = pos - self.lineStart();
        var pos_remaining = pos;
        while (self.searchBackwards(pos_remaining, "\n")) |line_start| {
            pos_remaining = line_start - 1;
            line += 1;
        }
        return .{line, col};
    }

    pub fn searchBackwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const bytes = self.bytes.items[0..pos];
        return if (std.mem.lastIndexOf(u8, bytes, needle)) |result_pos| result_pos + needle.len else null;
    }

    pub fn searchForwards(self: *Buffer, pos: usize, needle: []const u8) ?usize {
        const bytes = self.bytes.items[pos..];
        return if (std.mem.indexOf(u8, bytes, needle)) |result_pos| result_pos + pos else null;
    }

    pub fn dupe(self: *Buffer, allocator: *Allocator, start: usize, end: usize) ! []const u8 {
        assert(start <= end);
        assert(end <= self.bytes.items.len);
        return std.mem.dupe(allocator, u8, self.bytes.items[start..end]);
    }

    pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) ! void {
        try self.bytes.resize(self.bytes.items.len + bytes.len);
        std.mem.copyBackwards(u8, self.bytes.items[pos+bytes.len..], self.bytes.items[pos..self.bytes.items.len - bytes.len]);
        std.mem.copy(u8, self.bytes.items[pos..], bytes);
    }

    pub fn delete(self: *Buffer, start: usize, end: usize) void {
        assert(start <= end);
        assert(end <= self.bytes.items.len);
        std.mem.copy(u8, self.bytes.items[start..], self.bytes.items[end..]);
        self.bytes.shrink(self.bytes.items.len - (end - start));
    }

    pub fn countLines(self: *Buffer) usize {
        var lines: usize = 0;
        var iter = std.mem.split(self.bytes.items, "\n");
        while (iter.next()) |_| lines += 1;
        return lines;
    }
};

pub const Point = struct {
    // what char we're at
    // 0 <= pos <= buffer.getBufferEnd()
    pos: usize,
    // what column we 'want' to be at
    // should only be updated by left/right movement
    // 0 <= col
    col: usize,
};

pub const Cursor = struct {
    // the actual cursor
    head: Point,
    // the other end of the selection, if view.marked
    tail: Point,
    // allocated by view.allocator
    clipboard: []const u8,
};

pub const View = struct {
    allocator: *Allocator,
    buffer: *Buffer,
    // cursors.len > 0
    cursors: ArrayList(Cursor),
    marked: bool,
    dragging: bool,
    ctrl_dragging: bool,
    top_pixel: isize,

    const scroll_amount = 16;

    pub fn init(allocator: *Allocator, buffer: *Buffer) ! View {
        var cursors = ArrayList(Cursor).init(allocator);
        try cursors.append(.{
            .head = .{.pos=0, .col=0},
            .tail = .{.pos=0, .col=0},
            .clipboard="",
        });
        return View{
            .allocator = allocator,
            .buffer = buffer,
            .cursors = cursors,
            .marked = false,
            .dragging = false,
            .ctrl_dragging = false,
            .top_pixel = 0,
        };
    }

    pub fn deinit(self: *View) void {
        for (self.cursors.items) |cursor| {
            self.allocator.free(cursor.clipboard);
        }
        self.cursors.deinit();
    }

    pub fn frame(self: *View, window: *Window, rect: Rect) ! void {
        // handle events
        // if we get textinput, we'll also get the keydown first
        // if the keydown is mapped to a command, we'll do that and ignore the textinput
        // TODO this assumes that they always arrive in the same frame, which the sdl docs are not clear about
        var accept_textinput = false;
        for (window.events.items) |event| {
            switch (event.type) {
                c.SDL_KEYDOWN => {
                    const sym = event.key.keysym;
                    if (sym.mod & @intCast(u16, c.KMOD_CTRL) != 0) {
                        switch (sym.sym) {
                            ' ' => self.toggleMark(),
                            'c' => {
                                for (self.cursors.items) |*cursor| try self.copy(cursor);
                                self.clearMark();
                            },
                            'x' => {
                                for (self.cursors.items) |*cursor| try self.cut(cursor);
                                self.clearMark();
                            },
                            'v' => {
                                for (self.cursors.items) |*cursor| try self.paste(cursor);
                                self.clearMark();
                            },
                            'j' => for (self.cursors.items) |*cursor| self.goLeft(cursor),
                            'l' => for (self.cursors.items) |*cursor| self.goRight(cursor),
                            'k' => for (self.cursors.items) |*cursor| self.goDown(cursor),
                            'i' => for (self.cursors.items) |*cursor| self.goUp(cursor),
                            else => accept_textinput = true,
                        }
                    } else if (sym.mod & @intCast(u16, c.KMOD_ALT) != 0) {
                        switch (sym.sym) {
                            ' ' => for (self.cursors.items) |*cursor| self.swapHead(cursor),
                            'j' => for (self.cursors.items) |*cursor| self.goLineStart(cursor),
                            'l' => for (self.cursors.items) |*cursor| self.goLineEnd(cursor),
                            'k' => for (self.cursors.items) |*cursor| self.goPageEnd(cursor),
                            'i' => for (self.cursors.items) |*cursor| self.goPageStart(cursor),
                            else => accept_textinput = true,
                        }
                    } else {
                        switch (sym.sym) {
                            c.SDLK_BACKSPACE => {
                                for (self.cursors.items) |*cursor| self.deleteBackwards(cursor);
                                self.clearMark();
                            },
                            c.SDLK_RETURN => {
                                for (self.cursors.items) |*cursor| try self.insert(cursor, &[1]u8{'\n'});
                                self.clearMark();
                            },
                            c.SDLK_ESCAPE => {
                                try self.collapseCursors();
                                self.clearMark();
                            },
                            c.SDLK_RIGHT => for (self.cursors.items) |*cursor| self.goRight(cursor),
                            c.SDLK_LEFT => for (self.cursors.items) |*cursor| self.goLeft(cursor),
                            c.SDLK_DOWN => for (self.cursors.items) |*cursor| self.goDown(cursor),
                            c.SDLK_UP => for (self.cursors.items) |*cursor| self.goUp(cursor),
                            c.SDLK_DELETE => {
                                for (self.cursors.items) |*cursor| self.deleteForwards(cursor);
                                self.clearMark();
                            },
                            else => accept_textinput = true,
                        }
                    }
                },
                c.SDL_TEXTINPUT => {
                    if (accept_textinput) {
                        const text = event.text.text[0..std.mem.indexOfScalar(u8, &event.text.text, 0).?];
                        for (self.cursors.items) |*cursor| try self.insert(cursor, text);
                        self.clearMark();
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    const button = event.button;
                    if (button.button == c.SDL_BUTTON_LEFT) {
                        const line = @divTrunc(self.top_pixel + @intCast(Coord, button.y) - rect.y, window.atlas.char_height);
                        const col = @divTrunc(@intCast(Coord, button.x) - rect.x + @divTrunc(window.atlas.char_width, 2), window.atlas.char_width);
                        const pos = self.buffer.getPosForLineCol(@intCast(usize, max(line, 0)), @intCast(usize, max(col, 0)));
                        if (@enumToInt(c.SDL_GetModState()) & c.KMOD_CTRL != 0) {
                            self.ctrl_dragging = true;
                            var cursor = try self.newCursor();
                            self.updatePos(&cursor.head, pos);
                            self.updatePos(&cursor.tail, pos);
                        } else {
                            self.dragging = true;
                            for (self.cursors.items) |*cursor| {
                                self.updatePos(&cursor.head, pos);
                                self.updatePos(&cursor.tail, pos);
                            }
                            self.clearMark();
                        }
                    }
                },
                c.SDL_MOUSEBUTTONUP => {
                    const button = event.button;
                    if (button.button == c.SDL_BUTTON_LEFT) {
                        self.dragging = false;
                        self.ctrl_dragging = false;
                    }
                },
                c.SDL_MOUSEWHEEL => {
                    self.top_pixel -= scroll_amount * @intCast(i16, event.wheel.y);
                },
                else => {},
            }
        }

        if (self.dragging or self.ctrl_dragging) {
            // get mouse state
            var global_mouse_x: c_int = undefined;
            var global_mouse_y: c_int = undefined;
            const mouse_state = c.SDL_GetGlobalMouseState(&global_mouse_x, &global_mouse_y);
            var window_x: c_int = undefined;
            var window_y: c_int = undefined;
            c.SDL_GetWindowPosition(window.sdl_window, &window_x, &window_y);
            const mouse_x = @intCast(Coord, global_mouse_x - window_x);
            const mouse_y = @intCast(Coord, global_mouse_y - window_y);

            // update selection of dragged cursor
            const line = @divTrunc(self.top_pixel + mouse_y - rect.y, window.atlas.char_height);
            const col = @divTrunc(mouse_x - rect.x + @divTrunc(window.atlas.char_width, 2), window.atlas.char_width);
            const pos = self.buffer.getPosForLineCol(@intCast(usize, max(line, 0)), @intCast(usize, max(col, 0)));
            if (self.ctrl_dragging) {
                var cursor = &self.cursors.items[self.cursors.items.len-1];
                if (cursor.tail.pos != pos and !self.marked) {
                    self.setMark();
                }
                self.updatePos(&cursor.head, pos);
            } else {
                for (self.cursors.items) |*cursor| {
                    if (cursor.tail.pos != pos and !self.marked) {
                        self.setMark();
                    }
                    self.updatePos(&cursor.head, pos);
                }
            }
            
            // if dragging outside window, scroll
            if (mouse_y <= rect.y) self.top_pixel -= scroll_amount;
            if (mouse_y >= rect.y + rect.h) self.top_pixel += scroll_amount;
        }

        // calculate visible range
        // ensure we don't scroll off the top or bottom of the buffer
        const max_pixels = @intCast(isize, self.buffer.countLines()) * @intCast(isize, window.atlas.char_height);
        if (self.top_pixel < 0) self.top_pixel = 0;
        if (self.top_pixel > max_pixels) self.top_pixel = max_pixels;
        const num_visible_lines = @divTrunc(rect.h, window.atlas.char_height) + @rem(@rem(rect.h, window.atlas.char_height), 1); // round up
        const visible_start_line = @divTrunc(self.top_pixel, window.atlas.char_height); // round down
        const visible_end_line = visible_start_line + num_visible_lines;

        // draw background
        const background_color = Color{ .r = 0x2e, .g=0x34, .b=0x36, .a=255 };
        try window.queueRect(rect, background_color);

        // draw cursors, selections, text
        const text_color = Color{ .r = 0xee, .g = 0xee, .b = 0xec, .a = 255 };
        const multi_cursor_color = Color{ .r = 0x7a, .g = 0xa6, .b = 0xda, .a = 255 };
        var highlight_color = text_color; highlight_color.a = 100;
        var lines = std.mem.split(self.buffer.bytes.items, "\n");
        var line_ix: usize = 0;
        var line_start_pos: usize = 0;
        while (lines.next()) |line| : (line_ix += 1) {
            if (line_ix > visible_end_line) break;

            const line_end_pos = line_start_pos + line.len;
            
            if (line_ix >= visible_start_line) {
                const y = rect.y - @rem(self.top_pixel+1, window.atlas.char_height) + ((@intCast(Coord, line_ix) - visible_start_line) * window.atlas.char_height);

                for (self.cursors.items) |cursor| {
                    // draw cursor
                    if (cursor.head.pos >= line_start_pos and cursor.head.pos <= line_end_pos) {
                        const x = rect.x + (@intCast(Coord, (cursor.head.pos - line_start_pos)) * window.atlas.char_width);
                        const w = @divTrunc(window.atlas.char_width, 8);
                        try window.queueRect(
                            .{
                                .x = @intCast(Coord, x) - @divTrunc(w, 2),
                                .y = @intCast(Coord, y),
                                .w=w,
                                .h=window.atlas.char_height
                            },
                            if (self.cursors.items.len > 1) multi_cursor_color else text_color,
                        );
                    }

                    // draw selection
                    if (self.marked) {
                        const selection_start_pos = min(cursor.head.pos, cursor.tail.pos);
                        const selection_end_pos = max(cursor.head.pos, cursor.tail.pos);
                        const highlight_start_pos = min(max(selection_start_pos, line_start_pos), line_end_pos);
                        const highlight_end_pos = min(max(selection_end_pos, line_start_pos), line_end_pos);
                        if ((highlight_start_pos < highlight_end_pos)
                                or (selection_start_pos <= line_end_pos
                                        and selection_end_pos > line_end_pos)) {
                            const x = rect.x + (@intCast(Coord, (highlight_start_pos - line_start_pos)) * window.atlas.char_width);
                            const w = if (selection_end_pos > line_end_pos)
                                rect.x + rect.w - x
                                else
                                @intCast(Coord, (highlight_end_pos - highlight_start_pos)) * window.atlas.char_width;
                            try window.queueRect(
                                .{
                                    .x = @intCast(Coord, x),
                                    .y = @intCast(Coord, y),
                                    .w = @intCast(Coord, w),
                                    .h = window.atlas.char_height,
                                },
                                highlight_color
                            );
                        }
                    }
                }
                
                // draw text
                // TODO need to ensure this text lives long enough - buffer might get changed in another window
                try window.queueText(.{.x = rect.x, .y = @intCast(Coord, y)}, text_color, line);
            }
            
            line_start_pos = line_end_pos + 1; // + 1 for '\n'
        }

        // draw scrollbar
        {
            const ratio = @intToFloat(f64, self.top_pixel) / @intToFloat(f64, max_pixels);
            const y = rect.y + min(@floatToInt(Coord, @intToFloat(f64, rect.h) * ratio), rect.h - window.atlas.char_height);
            const x = rect.x + rect.w - window.atlas.char_width;
            try window.queueText(.{.x = x, .y = y}, highlight_color, "<");
        }
    }

    pub fn searchBackwards(self: *View, point: Point, needle: []const u8) ?usize {
        return self.buffer.searchBackwards(point.pos, needle);
    }

    pub fn searchForwards(self: *View, point: Point, needle: []const u8) ?usize {
        return self.buffer.searchForwards(point.pos, needle);
    }

    pub fn getLineStart(self: *View, point: Point) usize {
        return self.searchBackwards(point, "\n") orelse 0;
    }

    pub fn getLineEnd(self: *View, point: Point) usize {
        return self.searchForwards(point, "\n") orelse self.buffer.getBufferEnd();
    }

    pub fn updateCol(self: *View, point: *Point) void {
        point.col = point.pos - self.getLineStart(point.*);
    }

    pub fn updatePos(self: *View, point: *Point, pos: usize) void {
        point.pos = pos;
        self.updateCol(point);
    }

    pub fn goPos(self: *View, cursor: *Cursor, pos: usize) void {
        self.updatePos(&cursor.head, pos);
    }

    pub fn goCol(self: *View, cursor: *Cursor, col: usize) void {
        const line_start = self.getLineStart(cursor.head);
        cursor.head.col = min(col, self.getLineEnd(cursor.head) - line_start);
        cursor.head.pos = line_start + cursor.head.col;
    }

    pub fn goLine(self: *View, cursor: *Cursor, line: usize) void {
        cursor.head.pos = self.buffer.getPosForLine(line);
        // leave head.col intact
    }

    pub fn goLineCol(self: *View, cursor: *Cursor, line: usize, col: usize) void {
        self.goLine(cursor, line);
        self.goCol(cursor, col);
    }

    pub fn goLeft(self: *View, cursor: *Cursor) void {
        cursor.head.pos -= @as(usize, if (cursor.head.pos == 0) 0 else 1);
        self.updateCol(&cursor.head);
    }

    pub fn goRight(self: *View, cursor: *Cursor) void {
        cursor.head.pos += @as(usize, if (cursor.head.pos >= self.buffer.getBufferEnd()) 0 else 1);
        self.updateCol(&cursor.head);
    }

    pub fn goDown(self: *View, cursor: *Cursor) void {
        if (self.searchForwards(cursor.head, "\n")) |line_end| {
            const col = cursor.head.col;
            cursor.head.pos = line_end + 1;
            self.goCol(cursor, col);
            cursor.head.col = col;
        }
    }

    pub fn goUp(self: *View, cursor: *Cursor) void {
        if (self.searchBackwards(cursor.head, "\n")) |line_start| {
            const col = cursor.head.col;
            cursor.head.pos = line_start - 1;
            self.goCol(cursor, col);
            cursor.head.col = col;
        }
    }

    pub fn goLineStart(self: *View, cursor: *Cursor) void {
        cursor.head.pos = self.getLineStart(cursor.head);
        cursor.head.col = 0;
    }

    pub fn goLineEnd(self: *View, cursor: *Cursor) void {
        cursor.head.pos = self.searchForwards(cursor.head, "\n") orelse self.buffer.getBufferEnd();
        self.updateCol(&cursor.head);
    }

    pub fn goPageStart(self: *View, cursor: *Cursor) void {
        self.goPos(cursor, 0);
    }

    pub fn goPageEnd(self: *View, cursor: *Cursor) void {
        self.goPos(cursor, self.buffer.getBufferEnd());
    }

    pub fn insert(self: *View, cursor: *Cursor, bytes: []const u8) ! void {
        self.deleteSelection(cursor);
        try self.buffer.insert(cursor.head.pos, bytes);
        const insert_at = cursor.head.pos;
        for (self.cursors.items) |*other_cursor| {
            for (&[2]*Point{&other_cursor.head, &other_cursor.tail}) |point| {
                // ptr compare is because we want paste to leave each cursor after its own insert
                if (point.pos > insert_at or (point.pos == insert_at and @ptrToInt(other_cursor) >= @ptrToInt(cursor))) {
                    point.pos += bytes.len;
                    self.updateCol(point);
                }
            }
        }
    }

    pub fn delete(self: *View, start: usize, end: usize) void {
        assert(start <= end);
        self.buffer.delete(start, end);
        for (self.cursors.items) |*other_cursor| {
            for (&[2]*Point{&other_cursor.head, &other_cursor.tail}) |point| {
                if (point.pos >= start and point.pos <= end) point.pos = start;
                if (point.pos > end) point.pos -= (end - start);
                self.updateCol(point);
            }
        }
    }

    pub fn deleteSelection(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            const selection = self.getSelection(cursor);
            self.delete(selection[0], selection[1]);
        }
    }

    pub fn deleteBackwards(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            self.deleteSelection(cursor);
        } else if (cursor.head.pos > 0) {
            self.delete(cursor.head.pos-1, cursor.head.pos);
        }
    }

    pub fn deleteForwards(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            self.deleteSelection(cursor);
        } else if (cursor.head.pos < self.buffer.getBufferEnd()) {
            self.delete(cursor.head.pos, cursor.head.pos+1);
        }
    }

    pub fn clearMark(self: *View) void {
        self.marked = false;
    }

    pub fn setMark(self: *View) void {
        self.marked = true;
        for (self.cursors.items) |*cursor| {
            cursor.tail = cursor.head;
        }
    }

    pub fn toggleMark(self: *View) void {
        if (self.marked) {
            self.clearMark();
        } else {
            self.setMark();
        }
    }

    pub fn swapHead(self: *View, cursor: *Cursor) void {
        if (self.marked) {
            std.mem.swap(Point, &cursor.head, &cursor.tail);
        }
    }

    pub fn getSelection(self: *View, cursor: *Cursor) [2]usize {
        if (self.marked) {
            const selection_start_pos = min(cursor.head.pos, cursor.tail.pos);
            const selection_end_pos = max(cursor.head.pos, cursor.tail.pos);
            return [2]usize{selection_start_pos, selection_end_pos};
        } else {
            return [2]usize{cursor.head.pos, cursor.head.pos};
        }
    }

    pub fn dupeSelection(self: *View, cursor: *Cursor) ! []const u8 {
        const selection = self.getSelection(cursor);
        return self.buffer.dupe(self.allocator, selection[0], selection[1]);
    }

    pub fn copy(self: *View, cursor: *Cursor) ! void {
        self.allocator.free(cursor.clipboard);
        cursor.clipboard = try self.dupeSelection(cursor);
    }

    pub fn cut(self: *View, cursor: *Cursor) ! void {
        self.allocator.free(cursor.clipboard);
        cursor.clipboard = try self.dupeSelection(cursor);
        self.deleteSelection(cursor);
    }

    pub fn paste(self: *View, cursor: *Cursor) ! void {
        try self.insert(cursor, cursor.clipboard);
    }

    pub fn newCursor(self: *View) ! *Cursor {
        try self.cursors.append(.{
            .head = .{.pos=0, .col=0},
            .tail = .{.pos=0, .col=0},
            .clipboard="",
        });
        return &self.cursors.items[self.cursors.items.len-1];
    }

    pub fn collapseCursors(self: *View) ! void {
        var size: usize = 0;
        for (self.cursors.items) |cursor| {
            size += cursor.clipboard.len;
        }
        var clipboard = try ArrayList(u8).initCapacity(self.allocator, size);
        for (self.cursors.items) |cursor| {
            clipboard.appendSlice(cursor.clipboard) catch unreachable;
            self.allocator.free(cursor.clipboard);
        }
        self.cursors.shrink(1);
        self.cursors.items[0].clipboard = clipboard.toOwnedSlice();
    }
};
