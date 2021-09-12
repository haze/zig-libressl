const std = @import("std");
const root = @import("main.zig");
const tls = root.tls;

const Self = @This();

tls_configuration: root.TlsConfiguration,
tls_context: *tls.tls,
tcp_stream: std.net.Stream,
address: ?std.net.Address = null,

const WrapError = error{ OutOfMemory, BadTlsConfiguration, TlsConnectSocket, TlsAcceptSocket };

pub fn wrapClientStream(tls_configuration: root.TlsConfiguration, tcp_stream: std.net.Stream, server_name: []const u8) WrapError!Self {
    var maybe_tls_context = tls.tls_client();
    if (maybe_tls_context == null) return error.OutOfMemory;

    var tls_context = maybe_tls_context.?;
    if (tls.tls_configure(tls_context, tls_configuration.config) == -1)
        return error.BadTlsConfiguration;

    if (tls.tls_connect_socket(tls_context, tcp_stream.handle, server_name.ptr) == -1)
        return error.TlsConnectSocket;

    return Self{
        .tls_configuration = tls_configuration,
        .tls_context = tls_context,
        .tcp_stream = tcp_stream,
    };
}

pub fn wrapServerStream(tls_configuration: root.TlsConfiguration, tls_context: *tls.tls, connection: std.net.StreamServer.Connection) WrapError!Self {
    return Self{
        .tls_configuration = tls_configuration,
        .tls_context = tls_context,
        .tcp_stream = connection.stream,
        .address = connection.address,
    };
}

pub fn deinit(self: *Self) void {
    root.closeTlsContext(self.tls_context) catch |e| {
        root.out.err("Failed to call tls_close on client: {} ({s})", .{ e, tls.tls_error(self.tls_context) });
    };
    tls.tls_free(self.tls_context);
    self.tcp_stream.close();
    self.* = undefined;
}

pub const ReadError = error{ReadFailure};
pub const Reader = std.io.Reader(*Self, ReadError, Self.read);
pub fn read(self: *Self, buffer: []u8) ReadError!usize {
    const bytes_read = tls.tls_read(self.tls_context, buffer.ptr, buffer.len);
    if (bytes_read == -1) {
        root.out.warn("err={s}", .{tls.tls_error(self.tls_context)});
        return error.ReadFailure;
    }
    return @intCast(usize, bytes_read);
}
pub fn reader(self: *Self) Reader {
    return Reader{ .context = self };
}

pub const WriteError = error{WriteFailure};
pub const Writer = std.io.Writer(*Self, WriteError, Self.write);
pub fn write(self: *Self, buffer: []const u8) WriteError!usize {
    const bytes_written = tls.tls_write(self.tls_context, buffer.ptr, buffer.len);
    if (bytes_written == -1)
        return error.WriteFailure;
    return @intCast(usize, bytes_written);
}
pub fn writer(self: *Self) Writer {
    return Writer{ .context = self };
}
