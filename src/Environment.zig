const std = @import("std");
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const throw = errors.throw;

const Transaction = @import("Transaction.zig");
const Stat = @import("Stat.zig");

const Environment = @This();

pub const Options = struct {
    map_size: usize = 10 * 1024 * 1024,
    max_dbs: u32 = 0,
    max_readers: u32 = 126,
    read_only: bool = false,
    write_map: bool = false,
    no_tls: bool = false,
    no_lock: bool = false,
    mode: u16 = 0o664,
};

pub const Info = struct {
    map_size: usize,
    max_readers: u32,
    num_readers: u32,
};

ptr: ?*c.MDB_env = null,

pub fn init(path: [*:0]const u8, options: Options) !Environment {
    var env = Environment{};

    try throw(c.mdb_env_create(&env.ptr));
    errdefer c.mdb_env_close(env.ptr);

    try throw(c.mdb_env_set_mapsize(env.ptr, options.map_size));
    if (options.max_dbs > 0)
        try throw(c.mdb_env_set_maxdbs(env.ptr, options.max_dbs));
    try throw(c.mdb_env_set_maxreaders(env.ptr, options.max_readers));

    var flags: c_uint = 0;
    if (options.read_only) flags |= c.MDB_RDONLY;
    if (options.write_map) flags |= c.MDB_WRITEMAP;
    if (options.no_lock) flags |= c.MDB_NOLOCK;
    if (options.no_tls) flags |= c.MDB_NOTLS;

    try throw(c.mdb_env_open(env.ptr, path, flags, options.mode));

    return env;
}

pub fn deinit(self: Environment) void {
    c.mdb_env_close(self.ptr);
}

pub fn sync(self: Environment) !void {
    try throw(c.mdb_env_sync(self.ptr, 0));
}

pub fn stat(self: Environment) !Stat {
    var result: c.MDB_stat = undefined;
    try throw(c.mdb_env_stat(self.ptr, &result));

    return .{
        .psize = result.ms_psize,
        .depth = result.ms_depth,
        .branch_pages = result.ms_branch_pages,
        .leaf_pages = result.ms_leaf_pages,
        .overflow_pages = result.ms_overflow_pages,
        .entries = result.ms_entries,
    };
}

pub fn info(self: Environment) !Info {
    var result: c.MDB_envinfo = undefined;
    try throw(c.mdb_env_info(self.ptr, &result));

    return .{
        .map_size = result.me_mapsize,
        .max_readers = result.me_maxreaders,
        .num_readers = result.me_numreaders,
    };
}

pub fn resize(self: Environment, size: usize) !void {
    try throw(c.mdb_env_set_mapsize(self.ptr, size));
}

pub fn transaction(self: Environment, options: Transaction.Options) !Transaction {
    return try Transaction.init(self, options);
}
