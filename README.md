<h1 align="center">Zig-LibreSSL</h1>
<p align="center">
    <a href="LICENSE"><img src="https://badgen.net/github/license/haze/zig-libressl" /></a>
    <a href="https://twitter.com/hhazee"><img src="https://badgen.net/badge/twitter/@hhazee/1DA1F2?icon&label" /></a>
</p>

<p align="center">
   Zig-LibreSSL is an idiomatic zig wrapper around LibreSSL's libTLS for `std.net.Stream`
</p>

## Project status
Zig-LibreSSL is currently a work in progress. I've hand verified that simple message transactions
work, along with use in a homebrewed HTTP client, but there is still much more to test! Please feel
free to open issues for features or bugs that you wish to add or encounter.

## Quickstart Client

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tls_configuration = (TlsConfigurationParams{}).build() catch unreachable;

    var connection = try std.net.tcpConnectToHost(&gpa.allocator, "haz.ee", 443);
    var ssl_connection = try SslStream.wrapClientStream(tls_configuration, connection, "haz.ee");
    defer ssl_connection.deinit();

    var writer = ssl_connection.writer();
    var reader = ssl_connection.reader();

    try writer.writeAll("GET / HTTP/1.1\n\n");

    while (try reader.readUntilDelimiterOrEofAlloc(&gpa.allocator, '\n', std.math.maxInt(usize))) |line| {
        std.debug.print("{s}\n", .{line});
        defer gpa.allocator.free(line);
        if (std.mem.eql(u8, line, "</html>")) break;
    }
}

## TODOS
Please see the todos in `src/main.zig`
