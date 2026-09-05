"""Tiny loopback HTTP fixture, written in Mojo. Not a production HTTP server."""
from std.collections import List
from std.ffi import external_call, c_int
from std.memory import Pointer
from std.sys import CompilationTarget
from support.files import write_text


def serve(
    listener: c_int, replies: List[String], directory: String, status: Int
) raises:
    for index in range(len(replies)):
        var fd = external_call["accept", c_int](listener, UInt(0), UInt(0))
        if fd < 0:
            raise Error("Mock accept failed")
        var data = List[UInt8]()
        var buffer = List[UInt8](length=8192, fill=0)
        var expected = -1
        var header_end = -1
        while True:
            var count = external_call["recv", Int](
                fd, buffer.unsafe_ptr(), Int(8192), c_int(0)
            )
            if count <= 0 or len(data) > 4 * 1024 * 1024:
                raise Error("Mock request incomplete or too large")
            for i in range(count):
                data.append(buffer[i])
            var partial = String(from_utf8_lossy=data)
            if header_end < 0:
                header_end = partial.find("\r\n\r\n")
                if header_end >= 0:
                    var header = String(partial[byte=0:header_end])
                    expected = 0
                    for line in header.split("\r\n"):
                        var text = String(line)
                        if text.lower().startswith("content-length:"):
                            var digits = String(text[byte=15:]).strip()
                            for byte in digits.as_bytes():
                                expected = expected * 10 + Int(byte) - 48
            if header_end >= 0 and len(data) >= header_end + 4 + expected:
                break
        write_text(
            directory + "/request" + String(index) + ".txt",
            String(from_utf8=data),
            4 * 1024 * 1024,
        )
        var reply = replies[index]
        var wire = (
            "HTTP/1.1 "
            + String(status)
            + " Test\r\nContent-Type: application/json\r\nConnection:"
            " close\r\nContent-Length: "
            + String(reply.byte_length())
            + "\r\n\r\n"
            + reply
        )
        var bytes = wire.as_bytes()
        var sent = 0
        while sent < len(bytes):
            var count = external_call["send", Int](
                fd,
                bytes.unsafe_ptr().unsafe_offset(sent),
                len(bytes) - sent,
                c_int(0),
            )
            if count <= 0:
                raise Error("Mock send failed")
            sent += count
        _ = external_call["close", c_int](fd)


struct MockServer:
    var pid: c_int
    var port: Int

    def __init__(
        out self, replies: List[String], directory: String, status: Int = 200
    ) raises:
        var listener = external_call["socket", c_int](
            c_int(2), c_int(1), c_int(0)
        )
        if listener < 0:
            raise Error("Mock socket failed")
        var address = List[UInt8](length=16, fill=0)
        comptime if CompilationTarget.is_macos():
            address[0] = 16
            address[1] = 2
        else:
            address[0] = 2
        address[4] = 127
        address[7] = 1
        if (
            external_call["bind", c_int](
                listener, address.unsafe_ptr(), UInt32(16)
            )
            != 0
            or external_call["listen", c_int](listener, c_int(8)) != 0
        ):
            _ = external_call["close", c_int](listener)
            raise Error("Mock bind/listen failed")
        var length = UInt32(16)
        if (
            external_call["getsockname", c_int](
                listener, address.unsafe_ptr(), Pointer(to=length)
            )
            != 0
        ):
            _ = external_call["close", c_int](listener)
            raise Error("Mock port lookup failed")
        self.port = Int(address[2]) * 256 + Int(address[3])
        self.pid = external_call["fork", c_int]()
        if self.pid == 0:
            try:
                serve(listener, replies, directory, status)
                external_call["_exit", NoneType](c_int(0))
            except:
                external_call["_exit", NoneType](c_int(1))
        _ = external_call["close", c_int](listener)
        if self.pid < 0:
            raise Error("Mock fork failed")

    def __deinit__(deinit self):
        _ = external_call["kill", c_int](self.pid, c_int(9))
        var status = c_int(0)
        _ = external_call["waitpid", c_int](
            self.pid, Pointer(to=status), c_int(0)
        )

    def url(self) -> String:
        return "http://127.0.0.1:" + String(self.port) + "/v1/"
