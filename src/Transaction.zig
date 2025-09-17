const std = @import("std");
const hex = std.fmt.fmtSliceHexLower;

const c = @import("c.zig").c;
const errors = @import("errors.zig");
const throw = errors.throw;

const Environment = @import("Environment.zig");
const Database = @import("Database.zig");
const Cursor = @import("Cursor.zig");

const Transaction = @This();

pub const Options = struct {
    mode: Mode,
    parent: ?Transaction = null,
};

pub const Mode = enum { ReadOnly, ReadWrite };

ptr: ?*c.MDB_txn = null,

pub fn init(env: Environment, options: Options) !Transaction {
    var txn = Transaction{};

    var flags: c_uint = 0;
    switch (options.mode) {
        .ReadOnly => {
            flags |= c.MDB_RDONLY;
        },
        .ReadWrite => {},
    }

    var parentPtr: ?*c.MDB_txn = null;
    if (options.parent) |parent| {
        parentPtr = parent.ptr;
    }

    try throw(c.mdb_txn_begin(env.ptr, parentPtr, flags, &txn.ptr));

    return txn;
}

pub fn abort(self: Transaction) void {
    c.mdb_txn_abort(self.ptr);
}

pub fn commit(self: Transaction) !void {
    try throw(c.mdb_txn_commit(self.ptr));
}

pub fn get(self: Transaction, key: []const u8) !?[]const u8 {
    const db = try Database.open(self, null, .{});
    return try db.get(key);
}

pub fn set(self: Transaction, key: []const u8, value: []const u8) !void {
    const db = try Database.open(self, null, .{});
    try db.set(key, value);
}

pub fn delete(self: Transaction, key: []const u8) !void {
    const db = try Database.open(self, null, .{});
    try db.delete(key);
}

pub fn cursor(self: Transaction) !Cursor {
    const db = try Database.open(self, null, .{});
    return try Cursor.init(db);
}

pub fn database(self: Transaction, name: ?[*:0]const u8, options: Database.Options) !Database {
    return Database.open(self, name, options);
}
