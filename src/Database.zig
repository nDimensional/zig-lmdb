const c = @import("c.zig").c;
const errors = @import("errors.zig");
const throw = errors.throw;

const Transaction = @import("Transaction.zig");
const Cursor = @import("Cursor.zig");
const Stat = @import("Stat.zig");

const Database = @This();

pub const DBI = c.MDB_dbi;

pub const Options = struct {
    reverse_key: bool = false,
    integer_key: bool = false,
    create: bool = false,
};

txn: Transaction,
dbi: DBI,

pub fn open(txn: Transaction, name: ?[*:0]const u8, options: Options) !Database {
    var dbi: Database.DBI = 0;

    var flags: c_uint = 0;
    if (options.reverse_key) flags |= c.MDB_REVERSEKEY;
    if (options.integer_key) flags |= c.MDB_INTEGERKEY;
    if (options.create) flags |= c.MDB_CREATE;

    try throw(c.mdb_dbi_open(txn.ptr, name, flags, &dbi));

    return .{ .txn = txn, .dbi = dbi };
}

pub fn get(self: Database, key: []const u8) !?[]const u8 {
    var k: c.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
    var v: c.MDB_val = .{ .mv_size = 0, .mv_data = null };

    switch (c.mdb_get(self.txn.ptr, self.dbi, &k, &v)) {
        c.MDB_NOTFOUND => return null,
        else => |rc| try throw(rc),
    }

    return @as([*]u8, @ptrCast(v.mv_data))[0..v.mv_size];
}

pub fn set(self: Database, key: []const u8, value: []const u8) !void {
    var k: c.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
    var v: c.MDB_val = .{ .mv_size = value.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(value.ptr))) };

    try throw(c.mdb_put(self.txn.ptr, self.dbi, &k, &v, 0));
}

pub fn delete(self: Database, key: []const u8) !void {
    var k: c.MDB_val = .{ .mv_size = key.len, .mv_data = @as([*]u8, @ptrFromInt(@intFromPtr(key.ptr))) };
    try throw(c.mdb_del(self.txn.ptr, self.dbi, &k, null));
}

pub fn cursor(self: Database) !Cursor {
    return try Cursor.init(self);
}

pub fn stat(self: Database) !Stat {
    var result: c.MDB_stat = undefined;
    try throw(c.mdb_stat(self.txn.ptr, self.dbi, &result));

    return .{
        .psize = result.ms_psize,
        .depth = result.ms_depth,
        .branch_pages = result.ms_branch_pages,
        .leaf_pages = result.ms_leaf_pages,
        .overflow_pages = result.ms_overflow_pages,
        .entries = result.ms_entries,
    };
}
