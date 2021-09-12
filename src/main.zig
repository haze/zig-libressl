const std = @import("std");
pub const out = std.log.scoped(.libressl);

pub const tls = @cImport({
    @cInclude("tls.h");
});

const tls_config = @import("tls_config.zig");
pub const TlsConfiguration = tls_config.TlsConfiguration;
pub const TlsConfigurationParams = tls_config.TlsConfigurationParams;
pub const SslStream = @import("SslStream.zig");
pub const SslServer = @import("SslServer.zig");

pub fn closeTlsContext(tls_context: *tls.tls) !void {
    var maybe_tls_close: ?c_int = null;
    while (maybe_tls_close == null or maybe_tls_close.? == tls.TLS_WANT_POLLIN or maybe_tls_close.? == tls.TLS_WANT_POLLOUT) : (maybe_tls_close = tls.tls_close(tls_context)) {}
    if (maybe_tls_close.? == -1)
        return error.TlsClose;
}

// TODO(haze): reuse tls session file https://man.openbsd.org/tls_config_set_session_id.3
// TODO(haze): tls noverify https://man.openbsd.org/tls_config_verify.3
// TODO(haze): investigate tls_client/tls_server NULL return as OOM
// TODO(haze): tls_context reporting (tls version, issuer, expiry, etc)

// TODO(haze): incorporate into event loop
// TODO(haze): better error parsing
// TODO(haze): tls keypair/oscp add
// TODO(haze): debug annotations

test "server & client" {
    const message = "bruh moment";
    var params = TlsConfigurationParams{
        .ca = .{ .memory = @embedFile("../test/CA/root.pem") },
        .cert = .{ .memory = @embedFile("../test/CA/server.crt") },
        .key = .{ .memory = @embedFile("../test/CA/server.key") },
    };
    const conf = try params.build();

    var stream_server = std.net.StreamServer.init(.{});
    try stream_server.listen(std.net.Address.parseIp("127.0.0.1", 0) catch unreachable);

    var ssl_stream_server = try SslServer.wrap(conf, stream_server);

    const serverFn = struct {
        fn serverFn(server: *SslServer, message_to_send: []const u8) !void {
            defer server.deinit();
            var ssl_connection = try server.accept();
            defer ssl_connection.deinit();

            var writer = ssl_connection.writer();
            try writer.writeAll(message_to_send);
        }
    }.serverFn;

    var thread = try std.Thread.spawn(.{}, serverFn, .{ &ssl_stream_server, message });
    defer thread.join();

    var client = try std.net.tcpConnectToAddress(stream_server.listen_address);
    var ssl_client = try SslStream.wrapClientStream(conf, client, "localhost");

    defer ssl_client.deinit();

    var client_buf: [11]u8 = undefined;
    var client_reader = ssl_client.reader();
    _ = try client_reader.readAll(&client_buf);
    try std.testing.expectEqualStrings(message, &client_buf);
}
