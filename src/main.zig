const std = @import("std");

const os = std.os;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fd_t = std.os.linux.fd_t;

const log = std.log.scoped(.filewatch);

const fifo_path = "/tmp/fwatch-fifo";

pub fn FileEvent(comptime T: type) type {
    return struct {
        event_type: FileEventType,
        context: T,
    };
}

pub const FileEventType = enum { modified, deleted };

pub fn FileWatcher(comptime T: type) type {
    const FileTable = std.StringHashMapUnmanaged(T);
    const DirData = struct {
        inotify_wd: c_int,
        watched_files: FileTable,
    };
    const DirTable = std.StringHashMapUnmanaged(DirData);
    const Callback = *const fn (event_type: FileEventType, path: []const u8, context: T) anyerror!void;

    return struct {
        const Self = @This();

        // TODO Perhaps an arena is not necessary?
        arena: std.heap.ArenaAllocator,

        inotify_fd: i32,
        directory_table: DirTable,

        mutex: Mutex = .{},
        thread: ?Thread = null,
        callback: Callback,

        thread_fifo: ?std.fs.File = null,

        pub fn init(allocator: Allocator, callback: Callback) !*Self {
            var arena = std.heap.ArenaAllocator.init(allocator);

            const fd = try os.inotify_init1(0);
            errdefer os.close(fd);

            const ptr = try arena.allocator().create(Self);
            ptr.* = Self{
                .arena = arena,
                .inotify_fd = fd,
                .directory_table = DirTable{},
                .callback = callback,
            };

            return ptr;
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.directory_table.valueIterator();
            while (iterator.next()) |dir_data| {
                const result = os.linux.inotify_rm_watch(self.inotify_fd, dir_data.inotify_wd);
                std.debug.assert(result == 0);
            }

            // send termination signal over fifo
            term: {
                const fifo = std.fs.openFileAbsolute(fifo_path, .{ .mode = .write_only }) catch |err| {
                    switch (err) {
                        error.FileNotFound => break :term,
                        else => {
                            std.log.err("Unable to send termination signal: {}", .{err});
                            break :term;
                        },
                    }
                };
                defer fifo.close();
                _ = fifo.write(&.{1}) catch unreachable; // TODO send an enum? also handle error
            }

            if (self.thread) |thread| {
                thread.join();
            }
            if (self.thread_fifo) |fifo| {
                fifo.close();
                std.fs.deleteFileAbsolute(fifo_path) catch {};
            }

            //self.mutex.lock();
            //defer self.mutex.unlock();

            self.arena.deinit();
        }

        pub fn start(self: *Self) !void {
            // TODO maybe inotify_init should be called here?
            assert(self.thread == null);

            std.fs.deleteFileAbsolute(fifo_path) catch {};
            const result = mkfifo(fifo_path, 0o666);
            assert(result == 0);

            const thread = try Thread.spawn(.{}, thread_main, .{self});
            self.thread = thread;

            const fifo = try std.fs.openFileAbsolute(fifo_path, .{ .mode = .write_only });
            errdefer fifo.close();
            self.thread_fifo = fifo;
        }

        pub fn add(self: *Self, path: []const u8, context: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const allocator = self.arena.allocator();

            const owned_path = try allocator.dupe(u8, path);
            const basename = std.fs.path.basename(owned_path);
            const dir_path = std.fs.path.dirname(owned_path) orelse blk: {
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                break :blk cwd;
            };
            const mask = os.linux.IN.CLOSE_WRITE | os.linux.IN.ONLYDIR | os.linux.IN.DELETE | os.linux.IN.EXCL_UNLINK | os.linux.IN.MOVED_TO;
            const wd = try os.inotify_add_watch(self.inotify_fd, dir_path, mask);

            const result = try self.directory_table.getOrPut(allocator, dir_path);
            if (!result.found_existing) {
                const data = DirData{
                    .inotify_wd = wd,
                    .watched_files = FileTable{},
                };
                result.value_ptr.* = data;
            }

            var current_data = result.value_ptr;

            try current_data.watched_files.put(allocator, basename, context);

            log.info("Start watching {s}", .{owned_path});
        }

        pub fn remove(self: *Self, path: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const basename = std.fs.path.basename(path);
            const dir_path = std.fs.path.dirname(path) orelse return error.PathInvalid;

            var dir_data = self.directory_table.get(dir_path) orelse return error.FileNotWatched;
            const wd = dir_data.inotify_wd;
            _ = dir_data.watched_files.remove(basename);
            if (dir_data.watched_files.size == 0) {
                os.inotify_rm_watch(self.inotify_fd, wd);
                _ = self.directory_table.remove(dir_path);
                log.info("Watch removed {s}", .{path});
            }
        }

        fn thread_main(watcher: *Self) !void {
            log.info("Watch thread started", .{});
            defer log.info("Watch thread stopped", .{});

            const allocator = watcher.arena.allocator();
            const fd = watcher.inotify_fd;
            const termination_fd = try os.open(fifo_path, .{ .ACCMODE = .RDONLY }, 0); // TODO use std.fs

            var buf: [4096]u8 align(@alignOf(os.linux.inotify_event)) = undefined;

            var fds = [_]std.os.pollfd{
                os.pollfd{ .fd = fd, .events = os.linux.POLL.IN, .revents = 0 },
                os.pollfd{ .fd = termination_fd, .events = os.linux.POLL.IN, .revents = 0 },
            };
            const inotify_pollfd = &fds[0];
            const termination_pollfd = &fds[1];

            loop: while (true) {
                _ = try os.poll(fds[0..], -1);

                if (termination_pollfd.revents != 0) {
                    break;
                }

                if (inotify_pollfd.revents != 0) {
                    const num_read = os.read(fd, &buf) catch |err| {
                        switch (err) {
                            error.NotOpenForReading => break, // file descriptor was closed - terminate thread
                            else => return err,
                        }
                    };

                    if (num_read == 0) {
                        return error.INotifyError;
                    }
                    if (num_read == -1) {
                        return error.INotifyError;
                    }

                    var ptr: [*]u8 = &buf;
                    const end_ptr = ptr + num_read;
                    while (@intFromPtr(ptr) < @intFromPtr(end_ptr)) {
                        const event: *os.linux.inotify_event = @ptrCast(@alignCast(ptr));
                        const basename_ptr = ptr + @sizeOf(os.linux.inotify_event);
                        const basename = std.mem.span(@as([*:0]u8, @ptrCast(basename_ptr)));

                        watcher.mutex.lock();
                        defer watcher.mutex.unlock();

                        var dir_iter = watcher.directory_table.iterator();
                        var found_dir_path: ?[]const u8 = null;
                        var found_dir_data: ?DirData = null;
                        while (dir_iter.next()) |entry| {
                            if (entry.value_ptr.inotify_wd == event.wd) {
                                found_dir_path = entry.key_ptr.*;
                                found_dir_data = entry.value_ptr.*;
                                break;
                            }
                        }

                        if (found_dir_data != null) {
                            const dir_data = found_dir_data.?;
                            const dir_path = found_dir_path.?;

                            const full_path = try std.fs.path.join(allocator, &.{ dir_path, basename });
                            defer allocator.free(full_path);
                            const file = dir_data.watched_files.get(basename);

                            if (event.mask & os.linux.IN.CLOSE_WRITE == os.linux.IN.CLOSE_WRITE) {
                                // File was modified
                                if (file) |f| {
                                    log.info("Modified {s}", .{full_path});
                                    watcher.callback(.modified, full_path, f) catch |err| {
                                        log.err("Callback failed for {s} - {}", .{ full_path, err });
                                    };
                                }
                            } else if (event.mask & os.linux.IN.MOVED_TO == os.linux.IN.MOVED_TO) {
                                if (file) |f| {
                                    // We count this as a modification of the file
                                    log.info("Moved {s}", .{full_path});
                                    watcher.callback(.modified, full_path, f) catch |err| {
                                        log.err("Callback failed for {s} - {}", .{ full_path, err });
                                    };
                                }
                            } else if (event.mask & os.linux.IN.DELETE == os.linux.IN.DELETE) {
                                // File or directory was deleted

                                if (file) |f| {
                                    log.info("Deleted {s}", .{full_path});
                                    watcher.callback(.deleted, full_path, f) catch |err| {
                                        log.err("Callback failed for {s} - {}", .{ full_path, err });
                                    };
                                }
                            } else if (event.mask & os.linux.IN.IGNORED == os.linux.IN.IGNORED) {
                                // Directory watch was removed
                                // Watcher handles the clean up, so we don't need to do anything here

                                break :loop;
                            }
                        }

                        ptr = @alignCast(ptr + @sizeOf(os.linux.inotify_event) + event.len);
                    }
                }
            }
        }
    };
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

// * Tests

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const test_allocator = std.testing.allocator;
const test_path = "/tmp/hotreload_test.txt";

const TestFile = struct {
    events: std.ArrayList(FileEventType),

    fn init(allocator: Allocator) @This() {
        return .{ .events = std.ArrayList(FileEventType).init(allocator) };
    }

    fn deinit(self: *@This()) void {
        self.events.deinit();
    }
};

fn onFileChanged(event_type: FileEventType, path: []const u8, context: *TestFile) !void {
    _ = path;
    try context.events.append(event_type);
}

test "init and deinit" {
    var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
    watcher.deinit();
}

test "init, start and deinit" {
    var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
    defer watcher.deinit();
    try watcher.start();
}

test "file created" {
    var f = TestFile.init(test_allocator);
    defer f.deinit();

    var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
    defer watcher.deinit();

    try watcher.start();
    try watcher.add(test_path, &f);

    const file = try std.fs.createFileAbsolute(test_path, .{ .read = true });
    defer std.fs.deleteFileAbsolute(test_path) catch unreachable;
    file.close();

    while (f.events.items.len == 0) {}

    try expect(std.mem.eql(FileEventType, f.events.items, &.{.modified}));
}

test "file modified" {
    var f = TestFile.init(test_allocator);
    defer f.deinit();

    const file = try std.fs.createFileAbsolute(test_path, .{ .read = true });
    defer std.fs.deleteFileAbsolute(test_path) catch unreachable;

    var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
    defer watcher.deinit();

    try watcher.start();
    try watcher.add(test_path, &f);

    try file.writeAll("test");
    file.close();

    while (f.events.items.len == 0) {}

    try expect(std.mem.eql(FileEventType, f.events.items, &.{.modified}));
}

test "file removed" {
    var f = TestFile.init(test_allocator);
    defer f.deinit();

    var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
    defer watcher.deinit();

    _ = try std.fs.createFileAbsolute(test_path, .{ .read = true });
    errdefer std.fs.deleteFileAbsolute(test_path) catch unreachable;

    try watcher.start();
    try watcher.add(test_path, &f);

    try std.fs.deleteFileAbsolute(test_path);

    while (f.events.items.len == 0) {}

    try expect(std.mem.eql(FileEventType, f.events.items, &.{.deleted}));
}

test "remove watch" {
    var f = TestFile.init(test_allocator);
    defer f.deinit();

    _ = try std.fs.createFileAbsolute(test_path, .{ .read = true });
    defer std.fs.deleteFileAbsolute(test_path) catch unreachable;

    {
        var watcher = try FileWatcher(*TestFile).init(test_allocator, onFileChanged);
        defer watcher.deinit();

        try watcher.start();

        try watcher.add(test_path, &f);
        try watcher.remove(test_path);
    }

    try expect(std.mem.eql(FileEventType, f.events.items, &.{}));
}
