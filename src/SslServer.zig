const std = @import("std");
const root = @import("main.zig");
const tls = root.tls;
const TlsConfiguration = root.tls_config.TlsConfiguration;

const Self = @This();

tcp_server: std.net.StreamServer,
tls_configuration: TlsConfiguration,
tls_context: *tls.tls,

const WrapError = error{ OutOfMemory, BadTlsConfiguration };

pub fn wrap(tls_configuration: TlsConfiguration, tcp_server: std.net.StreamServer) WrapError!Self {
    var maybe_tls_context = tls.tls_server();
    if (maybe_tls_context == null) return error.OutOfMemory;
    errdefer root.out.warn("{s}", .{tls.tls_error(maybe_tls_context.?)});

    var tls_context = maybe_tls_context.?;
    if (tls.tls_configure(tls_context, tls_configuration.config) == -1)
        return error.BadTlsConfiguration;

    return Self{
        .tcp_server = tcp_server,
        .tls_configuration = tls_configuration,
        .tls_context = tls_context,
    };
}

pub fn accept(self: *Self) !root.SslStream {
    var connection = try self.tcp_server.accept();
    errdefer connection.stream.close();

    if (tls.tls_accept_socket(self.tls_context, @ptrCast([*c]?*tls.tls, &self.tls_context), connection.stream.handle) == -1)
        return error.TlsAcceptSocket;

    return root.SslStream.wrapServerStream(self.tls_configuration, self.tls_context, connection);
}

pub fn deinit(self: *Self) void {
    root.closeTlsContext(self.tls_context) catch |e| {
        root.out.err("Failed to call tls_close: {}", .{e});
    };
    self.tcp_server.deinit();
    self.* = undefined;
}
