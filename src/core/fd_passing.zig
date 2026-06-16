const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const io = @import("io.zig");
const protocol = @import("../protocol/mod.zig");

// Local reimplementation of the small `sys/socket.h` CMSG_* macro subset we
// need for SCM_RIGHTS. `struct msghdr` has a msg_control pointer to a raw byte
// buffer; that buffer contains one or more `struct cmsghdr` records plus their
// payload bytes and padding. Zig 0.15's libc surface does not expose a
// portable cmsghdr path for every target we support here, but the kernel ABI
// still requires the same header/data/padding layout as CMSG_DATA, CMSG_LEN,
// and CMSG_SPACE. Darwin's cmsghdr is 12-byte/4-aligned; Linux is typically
// 16-byte/8-aligned.
//
// The definitions below deliberately mirror the C macros instead of inventing
// a sessh-specific encoding. Ancillary data is interpreted by the kernel, so
// these sizes and alignments must match the platform socket ABI exactly.
const CmsgLen = @FieldType(c.msghdr, "controllen");

// Local ABI mirror of `struct cmsghdr` from `sys/socket.h`. This is not
// `struct msghdr`; it is the header stored inside msghdr.msg_control.
const CmsgHdr = extern struct {
    len: CmsgLen,
    level: c_int,
    type: c_int,
};

// CMSG_SPACE(sizeof(fd)): total control-buffer capacity for one descriptor,
// including cmsghdr, descriptor payload, and trailing alignment padding.
const fd_control_space = cmsgSpace(@sizeOf(c.fd_t));

// CMSG_LEN(sizeof(fd)): value written into cmsghdr.cmsg_len for one descriptor.
// This includes the header and descriptor payload, but not trailing padding.
const fd_control_len = cmsgLen(@sizeOf(c.fd_t));

// CMSG_DATA(cmsg) expressed as an offset from the start of cmsghdr.
const cmsg_data_offset = cmsgAlign(@sizeOf(CmsgHdr));

// SCM_RIGHTS is the ancillary-data type used by Unix-domain sockets to pass
// open file descriptions. Darwin and Linux use 1; illumos/Solaris differ.
const scm_rights = switch (builtin.os.tag) {
    .solaris, .illumos => 0x1010,
    else => 1,
};

pub fn BufferWithFdProgress(comptime Slice: type) type {
    return struct {
        // Byte buffer and fd state for a single logical transfer. On send,
        // `fd` starts as the descriptor that still needs to be sent. On
        // receive, `fd` is filled when SCM_RIGHTS data arrives. In both
        // directions, this object owns any descriptor currently stored in
        // `fd`; use takeFd to transfer ownership out. `offset` is the number of
        // buffer bytes already sent/received.
        buffer: Slice = &.{},
        fd: ?c.fd_t = null,
        offset: usize = 0,

        const Self = @This();

        pub fn init(buffer: Slice, fd: ?c.fd_t) Self {
            return .{
                .buffer = buffer,
                .fd = fd,
            };
        }

        pub fn remaining(self: *const Self) Slice {
            return self.buffer[self.offset..];
        }

        pub fn complete(self: *const Self) bool {
            return self.offset >= self.buffer.len;
        }

        pub fn takeFd(self: *Self) ?c.fd_t {
            const fd = self.fd;
            self.fd = null;
            return fd;
        }

        pub fn deinit(self: *Self) void {
            if (self.fd) |fd| {
                _ = c.close(fd);
                self.fd = null;
            }
        }
    };
}

pub const SendBufferWithFdProgress = BufferWithFdProgress([]const u8);
pub const RecvBufferWithFdProgress = BufferWithFdProgress([]u8);

pub fn ByteProgress(comptime Slice: type) type {
    return struct {
        buffer: Slice = &.{},
        offset: usize = 0,

        const Self = @This();

        pub fn init(buffer: Slice) Self {
            return .{ .buffer = buffer };
        }

        pub fn remaining(self: *const Self) Slice {
            return self.buffer[self.offset..];
        }

        pub fn complete(self: *const Self) bool {
            return self.offset >= self.buffer.len;
        }
    };
}

pub const SendByteProgress = ByteProgress([]const u8);
pub const RecvByteProgress = ByteProgress([]u8);

pub const BufferProgressStatus = enum {
    blocked,
    progress,
    complete,
    eof,
};

pub const OwnedFrameWithFd = struct {
    frame: protocol.OwnedFrame,
    fd: ?c.fd_t = null,

    pub fn takeFd(self: *OwnedFrameWithFd) ?c.fd_t {
        const fd = self.fd;
        self.fd = null;
        return fd;
    }

    pub fn deinit(self: *OwnedFrameWithFd, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
        if (self.fd) |fd| {
            _ = c.close(fd);
            self.fd = null;
        }
        self.* = undefined;
    }
};

pub const FrameReadStatus = union(enum) {
    blocked,
    progress,
    frame: OwnedFrameWithFd,
    eof,
    truncated_frame,
};

pub const FrameReader = struct {
    allocator: std.mem.Allocator,
    header_storage: [protocol.frame_header_len]u8 = undefined,
    header_progress: RecvByteProgress = .{},
    message_progress: RecvBufferWithFdProgress = .{},
    decoded_frame: ?protocol.OwnedFrame = null,
    attached_progress: RecvByteProgress = .{},

    pub fn init(allocator: std.mem.Allocator) FrameReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameReader) void {
        self.reset();
        self.* = undefined;
    }

    pub fn readReady(self: *FrameReader, fd: c.fd_t) !FrameReadStatus {
        self.ensureHeaderProgress();
        if (!self.header_progress.complete()) {
            switch (try readByteProgress(fd, &self.header_progress)) {
                .blocked => return .blocked,
                .eof => return if (self.header_progress.offset == 0) .eof else .truncated_frame,
                .progress => return .progress,
                .complete => {},
            }
        }

        if (self.message_progress.buffer.len == 0) {
            const message_len = protocol.messageLenFromHeader(&self.header_storage);
            if (message_len == 0) return error.UnknownFrame;
            self.message_progress = RecvBufferWithFdProgress.init(
                try self.allocator.alloc(u8, message_len),
                null,
            );
        }

        if (!self.message_progress.complete()) {
            switch (try recvBufferWithFdProgress(fd, &self.message_progress)) {
                .blocked => return .blocked,
                .eof => return .truncated_frame,
                .progress => return .progress,
                .complete => {},
            }
        }

        if (self.decoded_frame == null) {
            var decoded = try protocol.decodeMessageEnvelopeAlloc(self.allocator, self.message_progress.buffer);
            errdefer decoded.frame.deinit(self.allocator);
            if (decoded.attached_bytes_len == 0) {
                const frame = OwnedFrameWithFd{
                    .frame = decoded.frame,
                    .fd = self.message_progress.takeFd(),
                };
                self.resetFrameStorageOnly();
                return .{ .frame = frame };
            }

            var frame = decoded.frame;
            frame.attached_bytes = try self.allocator.alloc(u8, decoded.attached_bytes_len);
            self.attached_progress = RecvByteProgress.init(frame.attached_bytes);
            self.decoded_frame = frame;
        }

        if (!self.attached_progress.complete()) {
            switch (try readByteProgress(fd, &self.attached_progress)) {
                .blocked => return .blocked,
                .eof => return .truncated_frame,
                .progress => return .progress,
                .complete => {},
            }
        }

        const result = OwnedFrameWithFd{
            .frame = self.decoded_frame.?,
            .fd = self.message_progress.takeFd(),
        };
        self.decoded_frame = null;
        self.resetFrameStorageOnly();
        return .{ .frame = result };
    }

    fn reset(self: *FrameReader) void {
        self.resetFrameStorageOnly();
        if (self.decoded_frame) |*frame| {
            frame.deinit(self.allocator);
            self.decoded_frame = null;
        }
    }

    fn resetFrameStorageOnly(self: *FrameReader) void {
        self.header_progress = .{};
        self.message_progress.deinit();
        self.allocator.free(self.message_progress.buffer);
        self.message_progress = .{};
        self.attached_progress = .{};
    }

    fn ensureHeaderProgress(self: *FrameReader) void {
        if (self.header_progress.buffer.len == 0) {
            self.header_progress = RecvByteProgress.init(self.header_storage[0..]);
        }
    }
};

pub const FrameWriteWithFdProgress = struct {
    header_progress: SendByteProgress,
    message_progress: SendBufferWithFdProgress,
    attached_progress: SendByteProgress,

    pub fn init(frame_bytes: []const u8, fd: c.fd_t) !FrameWriteWithFdProgress {
        if (frame_bytes.len < protocol.frame_header_len) return error.TruncatedFrame;
        var header: [protocol.frame_header_len]u8 = undefined;
        @memcpy(&header, frame_bytes[0..protocol.frame_header_len]);
        const message_len = protocol.messageLenFromHeader(&header);
        const message_start = protocol.frame_header_len;
        const attached_start = message_start + message_len;
        if (attached_start > frame_bytes.len) return error.TruncatedFrame;
        return .{
            .header_progress = SendByteProgress.init(frame_bytes[0..protocol.frame_header_len]),
            .message_progress = SendBufferWithFdProgress.init(frame_bytes[message_start..attached_start], fd),
            .attached_progress = SendByteProgress.init(frame_bytes[attached_start..]),
        };
    }

    pub fn deinit(self: *FrameWriteWithFdProgress) void {
        self.message_progress.deinit();
        self.* = undefined;
    }

    pub fn writeReady(self: *FrameWriteWithFdProgress, fd: c.fd_t) !BufferProgressStatus {
        if (!self.header_progress.complete()) {
            switch (try writeByteProgress(fd, &self.header_progress)) {
                .blocked => return .blocked,
                .progress => return .progress,
                .complete => {},
                .eof => unreachable,
            }
        }

        if (!self.message_progress.complete()) {
            switch (try sendBufferWithFdProgress(fd, &self.message_progress)) {
                .blocked => return .blocked,
                .progress => return .progress,
                .complete => {},
                .eof => unreachable,
            }
        }

        if (!self.attached_progress.complete()) {
            switch (try writeByteProgress(fd, &self.attached_progress)) {
                .blocked => return .blocked,
                .progress => return .progress,
                .complete => {},
                .eof => unreachable,
            }
        }

        return .complete;
    }
};

fn readByteProgress(fd: c.fd_t, progress: *RecvByteProgress) !BufferProgressStatus {
    if (progress.complete()) return .complete;

    while (true) {
        const remaining = progress.remaining();
        const n = c.recv(fd, remaining.ptr, remaining.len, c.MSG.DONTWAIT);
        if (n > 0) {
            const received: usize = @intCast(n);
            io.noteRead(fd, remaining[0..received]);
            progress.offset += received;
            return if (progress.complete()) .complete else .progress;
        }
        if (n == 0) return .eof;
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return .blocked,
            else => return error.RecvFailed,
        }
    }
}

fn writeByteProgress(fd: c.fd_t, progress: *SendByteProgress) !BufferProgressStatus {
    if (progress.complete()) return .complete;

    const written = sendBytes(fd, progress.remaining()) catch |err| switch (err) {
        error.WouldBlock => return .blocked,
        else => return err,
    };
    progress.offset += written;
    return if (progress.complete()) .complete else .progress;
}

/// Advances a send buffer that has at most one fd associated with it.
///
/// Contract:
/// - `progress.buffer` must be non-empty if `progress.fd != null`. Unix stream
///   sockets attach ancillary data to ordinary bytes; without at least one byte
///   there is no useful receive point for the fd.
/// - If `progress.fd != null`, the next successful step sends exactly one
///   descriptor with the non-empty byte prefix accepted by sendmsg, then clears
///   `progress.fd` and closes the local fd stored there. Later steps send
///   remaining bytes as ordinary stream data.
/// - SCM_RIGHTS itself duplicates the underlying open file description into
///   the receiver; it does not close the sender's fd number. This progress
///   object owns that sender fd and closes it after sendmsg accepts the
///   descriptor.
/// - `blocked` means no bytes were accepted and, if an fd was pending, no
///   descriptor was sent.
/// - Other errors mean the failed syscall accepted no additional bytes and, if
///   an fd was pending for that syscall, did not send it. They should still be
///   treated as socket-fatal by callers that cannot otherwise recover the
///   higher-level message being sent.
pub fn sendBufferWithFdProgress(sock_fd: c.fd_t, progress: *SendBufferWithFdProgress) !BufferProgressStatus {
    if (progress.complete()) return .complete;

    const remaining = progress.remaining();
    const sent = if (progress.fd) |passed_fd| sent: {
        const n = sendFdPrefix(sock_fd, remaining, passed_fd) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        _ = c.close(passed_fd);
        progress.fd = null;
        break :sent n;
    } else sent: {
        const n = sendBytes(sock_fd, remaining) catch |err| switch (err) {
            error.WouldBlock => return .blocked,
            else => return err,
        };
        break :sent n;
    };

    progress.offset += sent;
    return if (progress.complete()) .complete else .progress;
}

fn sendFdPrefix(sock_fd: c.fd_t, bytes: []const u8, passed_fd: c.fd_t) !usize {
    // SCM_RIGHTS does not send an integer fd value. The kernel duplicates the
    // underlying open file description into the receiver and reports the new fd
    // number as ancillary data on recvmsg.
    if (bytes.len == 0) return error.EmptyFdPayload;

    var iov: c.iovec_const = .{
        .base = bytes.ptr,
        .len = bytes.len,
    };
    var control: [fd_control_space]u8 align(@alignOf(CmsgHdr)) = undefined;
    @memset(&control, 0);

    // `control` is the raw ancillary-data byte buffer passed through
    // msghdr.msg_control. It is sized as CMSG_SPACE(sizeof(fd)): exactly enough
    // room for one cmsghdr, one fd payload, and any trailing padding required
    // by the platform ABI. The trailing padding belongs to msg_controllen
    // capacity, not cmsghdr.len.
    const header = std.mem.bytesAsValue(CmsgHdr, control[0..@sizeOf(CmsgHdr)]);
    header.* = .{
        .len = @intCast(fd_control_len),
        .level = c.SOL.SOCKET,
        .type = scm_rights,
    };
    std.mem.bytesAsValue(c.fd_t, control[cmsg_data_offset..][0..@sizeOf(c.fd_t)]).* = passed_fd;

    var msg: c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1].ptr,
        .iovlen = 1,
        .control = control[0..].ptr,
        .controllen = @intCast(control.len),
        .flags = 0,
    };

    while (true) {
        const n = c.sendmsg(sock_fd, &msg, c.MSG.DONTWAIT);
        if (n >= 0) {
            const sent: usize = @intCast(n);
            if (sent == 0) return error.WriteFailed;
            io.noteWrite(sock_fd, bytes[0..sent]);
            return sent;
        }
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            .INVAL => return error.InvalidSendmsg,
            .MSGSIZE => return error.FdPayloadTooLarge,
            .NOTSOCK => return error.NotSocket,
            .PIPE => return error.BrokenPipe,
            else => return error.SendmsgFailed,
        }
    }
}

fn sendBytes(sock_fd: c.fd_t, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;

    while (true) {
        const n = c.send(sock_fd, bytes.ptr, bytes.len, c.MSG.DONTWAIT);
        if (n > 0) {
            const sent: usize = @intCast(n);
            io.noteWrite(sock_fd, bytes[0..sent]);
            return sent;
        }
        if (n == 0) return error.WriteFailed;
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            .NOTSOCK => return error.NotSocket,
            .PIPE => return error.BrokenPipe,
            else => return error.SendFailed,
        }
    }
}

/// Advances a receive buffer and captures at most one fd associated with the
/// bytes received into that buffer.
///
/// Contract:
/// - On success, returned stream bytes and returned descriptors are kept
///   together: this function never advances `progress.offset` unless every
///   SCM_RIGHTS descriptor associated with those bytes is represented by
///   `progress.fd`.
/// - The successful API shape intentionally supports only zero or one
///   descriptor per buffer. If the bytes carry more than one descriptor, the
///   call fails with `error.MultipleFileDescriptors`.
/// - `progress.offset` is advanced by the number of bytes received.
/// - `progress.fd == null` means no completed receive step has carried
///   SCM_RIGHTS data for this buffer.
/// - `progress.fd != null` means descriptor ownership has transferred to the
///   caller, which must either close it or pass ownership onward.
/// - The fd can arrive with any non-empty read from the stream. It is attached
///   to the bytes consumed by this particular recvmsg call, not to any
///   higher-level message boundary.
/// - `blocked` means no bytes or descriptors were consumed.
/// - `eof` means the stream ended before this step received more bytes.
/// - Malformed, truncated, or multi-fd control data is rejected. recvmsg may
///   already have advanced the stream before reporting such a problem, so the
///   caller must treat those errors as fatal to the socket. Any descriptors
///   already installed into this process from rejected control data are closed
///   before the error is returned.
pub fn recvBufferWithFdProgress(sock_fd: c.fd_t, progress: *RecvBufferWithFdProgress) !BufferProgressStatus {
    // recvmsg returns stream bytes and, if this read crosses an SCM_RIGHTS
    // control message, any fd installed into this process. The byte buffer can
    // be smaller than the sender's payload; callers must therefore be prepared
    // to receive the fd before they have read the full higher-level message.
    if (progress.complete()) return .complete;
    const buf = progress.remaining();

    var iov: c.iovec = .{
        .base = buf.ptr,
        .len = buf.len,
    };
    var control: [fd_control_space]u8 align(@alignOf(CmsgHdr)) = undefined;
    @memset(&control, 0);
    var msg: c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1].ptr,
        .iovlen = 1,
        .control = control[0..].ptr,
        .controllen = @intCast(control.len),
        .flags = 0,
    };

    while (true) {
        const n = c.recvmsg(sock_fd, &msg, c.MSG.DONTWAIT);
        if (n > 0) {
            const received_control = control[0..@intCast(msg.controllen)];
            if ((msg.flags & c.MSG.CTRUNC) != 0) {
                // MSG_CTRUNC means our control buffer was too small. Some
                // kernels may still have installed descriptors from the
                // non-truncated prefix, so close anything parseable before
                // reporting failure.
                closeReceivedFdsFromControl(received_control);
                progress.deinit();
                return error.ControlMessageTruncated;
            }
            const fd = receivedFdFromControl(received_control) catch |err| {
                progress.deinit();
                return err;
            };
            if (fd) |received_fd| {
                if (progress.fd) |old_fd| {
                    _ = c.close(old_fd);
                    _ = c.close(received_fd);
                    progress.fd = null;
                    return error.MultipleFileDescriptors;
                }
                progress.fd = received_fd;
            }
            const received_len: usize = @intCast(n);
            io.noteRead(sock_fd, buf[0..received_len]);
            progress.offset += received_len;
            return if (progress.complete()) .complete else .progress;
        }
        if (n == 0) return .eof;
        switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return .blocked,
            else => return error.RecvmsgFailed,
        }
    }
}

fn receivedFdFromControl(control: []u8) !?c.fd_t {
    var offset: usize = 0;
    var received_fd: ?c.fd_t = null;
    errdefer {
        if (received_fd) |fd| _ = c.close(fd);
    }
    while (offset + @sizeOf(CmsgHdr) <= control.len) {
        const header = std.mem.bytesAsValue(CmsgHdr, control[offset..][0..@sizeOf(CmsgHdr)]);
        const len: usize = @intCast(header.len);
        if (len < @sizeOf(CmsgHdr) or offset + len > control.len) return error.InvalidControlMessage;
        if (header.level == c.SOL.SOCKET and header.type == scm_rights) {
            const data = control[offset + cmsg_data_offset .. offset + len];
            if (data.len != @sizeOf(c.fd_t)) {
                // We intentionally accept exactly one descriptor per sessh
                // request. A larger SCM_RIGHTS payload may still contain live
                // descriptors already installed into this process, so reject
                // it only after closing them.
                closeReceivedFdsFromData(data);
                return error.MultipleFileDescriptors;
            }
            const fd = std.mem.bytesAsValue(c.fd_t, data[0..@sizeOf(c.fd_t)]).*;
            if (received_fd) |old_fd| {
                // Multiple SCM_RIGHTS control messages are just as invalid as
                // multiple fds in one message. Neither descriptor belongs to
                // the caller because the request is ambiguous.
                _ = c.close(old_fd);
                _ = c.close(fd);
                return error.MultipleFileDescriptors;
            }
            received_fd = fd;
        }
        offset += cmsgAlign(len);
    }
    return received_fd;
}

fn closeReceivedFdsFromControl(control: []const u8) void {
    // Best-effort cleanup for receive-side error paths. Once recvmsg returns,
    // any descriptors present in SCM_RIGHTS data are owned by this process even
    // if the overall message is malformed.
    var offset: usize = 0;
    while (offset + @sizeOf(CmsgHdr) <= control.len) {
        const header = std.mem.bytesAsValue(CmsgHdr, control[offset..][0..@sizeOf(CmsgHdr)]);
        const len: usize = @intCast(header.len);
        if (len < @sizeOf(CmsgHdr) or offset + len > control.len) return;
        if (header.level == c.SOL.SOCKET and header.type == scm_rights) {
            closeReceivedFdsFromData(control[offset + cmsg_data_offset .. offset + len]);
        }
        offset += cmsgAlign(len);
    }
}

fn closeReceivedFdsFromData(data: []const u8) void {
    var offset: usize = 0;
    while (offset + @sizeOf(c.fd_t) <= data.len) : (offset += @sizeOf(c.fd_t)) {
        const fd = std.mem.bytesAsValue(c.fd_t, data[offset..][0..@sizeOf(c.fd_t)]).*;
        _ = c.close(fd);
    }
}

// CMSG_ALIGN(len): round up to the alignment used for cmsghdr records on this
// target. This is what separates one control message from the next.
fn cmsgAlign(len: usize) usize {
    const alignment = @alignOf(CmsgHdr);
    return (len + alignment - 1) & ~@as(usize, alignment - 1);
}

// CMSG_LEN(payload_len): header plus payload, without the final padding that
// may be needed before another cmsghdr.
fn cmsgLen(payload_len: usize) usize {
    return cmsg_data_offset + payload_len;
}

// CMSG_SPACE(payload_len): how much control-buffer storage is required for a
// cmsghdr carrying payload_len bytes, including final padding.
fn cmsgSpace(payload_len: usize) usize {
    return cmsg_data_offset + cmsgAlign(payload_len);
}

test "sendBufferWithFdProgress transfers a usable descriptor" {
    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer _ = c.close(control[0]);
    defer _ = c.close(control[1]);

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    var send_progress = SendBufferWithFdProgress.init("fd-ready", raw[0]);
    defer send_progress.deinit();
    while (true) {
        switch (try sendBufferWithFdProgress(control[0], &send_progress)) {
            .blocked => continue,
            .progress => continue,
            .complete => break,
            .eof => unreachable,
        }
    }

    var buf: [32]u8 = undefined;
    var recv_progress = RecvBufferWithFdProgress.init(&buf, null);
    defer recv_progress.deinit();
    while (true) {
        switch (try recvBufferWithFdProgress(control[1], &recv_progress)) {
            .blocked => continue,
            .progress, .complete => break,
            .eof => return error.UnexpectedEndOfStream,
        }
    }
    try std.testing.expectEqualStrings("fd-ready", buf[0..recv_progress.offset]);
    const received_fd = recv_progress.takeFd() orelse return error.MissingFileDescriptor;
    defer _ = c.close(received_fd);

    try io.writeAll(received_fd, "raw-bytes");
    var raw_buf: [32]u8 = undefined;
    const n = c.read(raw[1], &raw_buf, raw_buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("raw-bytes", raw_buf[0..@intCast(n)]);
}

test "FrameReader keeps an fd attached to a partial frame" {
    const payload = try protocol.encodePayload(std.testing.allocator, protocol.pb.ClientDaemonItem{
        .payload = .{ .log_request = .{} },
    });
    defer std.testing.allocator.free(payload);
    const frame_bytes = try protocol.encodeFrame(std.testing.allocator, .client_daemon, payload);
    defer std.testing.allocator.free(frame_bytes);

    var control: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &control) != 0) return error.SocketPairFailed;
    defer _ = c.close(control[0]);
    defer _ = c.close(control[1]);

    var raw: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &raw) != 0) return error.SocketPairFailed;
    defer _ = c.close(raw[1]);

    var send_progress = try FrameWriteWithFdProgress.init(frame_bytes, raw[0]);
    defer send_progress.deinit();
    while (true) {
        switch (try send_progress.writeReady(control[0])) {
            .blocked => continue,
            .progress => continue,
            .complete => break,
            .eof => unreachable,
        }
    }

    var reader = FrameReader.init(std.testing.allocator);
    defer reader.deinit();
    var received_fd: ?c.fd_t = null;
    while (true) {
        switch (try reader.readReady(control[1])) {
            .blocked, .progress => continue,
            .eof, .truncated_frame => return error.UnexpectedEndOfStream,
            .frame => |frame_value| {
                var frame = frame_value;
                defer frame.deinit(std.testing.allocator);
                try std.testing.expectEqual(protocol.MessageType.client_daemon, frame.frame.message_type);
                received_fd = frame.takeFd();
                break;
            },
        }
    }
    const fd = received_fd orelse return error.MissingFileDescriptor;
    defer _ = c.close(fd);
    try io.writeAll(fd, "through-fd");
    var raw_buf: [32]u8 = undefined;
    const n = c.read(raw[1], &raw_buf, raw_buf.len);
    if (n < 0) return error.ReadFailed;
    try std.testing.expectEqualStrings("through-fd", raw_buf[0..@intCast(n)]);
}
