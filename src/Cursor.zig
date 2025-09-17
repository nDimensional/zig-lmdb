const std = @import("std");
const assert = std.debug.assert;
const hex = std.fmt.fmtSliceHexLower;

const c = @import("c.zig").c;
const errors = @import("errors.zig");
const throw = errors.throw;

const Transaction = @import("Transaction.zig");
const Database = @import("Database.zig");

const Cursor = @This();

ptr: ?*c.MDB_cursor = null,

pub const Entry = struct { key: []const u8, value: []const u8 };

pub fn init(db: Database) !Cursor {
    var cursor = Cursor{};
    try throw(c.mdb_cursor_open(db.txn.ptr, db.dbi, &cursor.ptr));
    return cursor;
}

pub fn deinit(self: Cursor) void {
    c.mdb_cursor_close(self.ptr);
}

pub fn getCurrentEntry(self: Cursor) !Entry {
    var k: c.MDB_val = undefined;
    var v: c.MDB_val = undefined;

    try throw(c.mdb_cursor_get(self.ptr, &k, &v, c.MDB_GET_CURRENT));
    return Entry{
        .key = @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size],
        .value = @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size],
    };
}

pub fn getCurrentKey(self: Cursor) ![]const u8 {
    var k: c.MDB_val = undefined;
    try throw(c.mdb_cursor_get(self.ptr, &k, null, c.MDB_GET_CURRENT));
    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}

pub fn getCurrentValue(self: Cursor) ![]const u8 {
    var v: c.MDB_val = undefined;
    try throw(c.mdb_cursor_get(self.ptr, null, &v, c.MDB_GET_CURRENT));
    return @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size];
}

pub fn setCurrentValue(self: Cursor, value: []const u8) !void {
    var k: c.MDB_val = undefined;
    try throw(c.mdb_cursor_get(self.ptr, &k, null, c.MDB_GET_CURRENT));

    var v: c.MDB_val = .{ .mv_size = value.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(value.ptr))) };
    try throw(c.mdb_cursor_put(self.ptr, &k, &v, c.MDB_CURRENT));
}

pub fn deleteCurrentKey(self: Cursor) !void {
    try throw(c.mdb_cursor_del(self.ptr, 0));
}

pub fn goToNext(self: Cursor) !?[]const u8 {
    var k: c.MDB_val = undefined;

    switch (c.mdb_cursor_get(self.ptr, &k, null, c.MDB_NEXT)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}

pub fn goToPrevious(self: Cursor) !?[]const u8 {
    var k: c.MDB_val = undefined;

    switch (c.mdb_cursor_get(self.ptr, &k, null, c.MDB_PREV)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}

pub fn goToLast(self: Cursor) !?[]const u8 {
    var k: c.MDB_val = undefined;

    switch (c.mdb_cursor_get(self.ptr, &k, null, c.MDB_LAST)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}

pub fn goToFirst(self: Cursor) !?[]const u8 {
    var k: c.MDB_val = undefined;

    switch (c.mdb_cursor_get(self.ptr, &k, null, c.MDB_FIRST)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}

pub fn goToKey(self: Cursor, key: []const u8) !void {
    var k: c.MDB_val = undefined;
    k.mv_size = key.len;
    k.mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr)));

    try throw(c.mdb_cursor_get(self.ptr, &k, null, c.MDB_SET_KEY));
}

pub fn seek(self: Cursor, key: []const u8) !?[]const u8 {
    var k: c.MDB_val = undefined;
    k.mv_size = key.len;
    k.mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr)));

    switch (c.mdb_cursor_get(self.ptr, &k, null, c.MDB_SET_RANGE)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(k.mv_data))[0..k.mv_size];
}
