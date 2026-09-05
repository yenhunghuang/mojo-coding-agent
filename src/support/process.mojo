"""Bounded POSIX process runner in Mojo (macOS/Linux).

pipe → fork → child redirects/execs → parent polls/drains → waitpid.
The child uses only libc calls between fork and exec. The parent owns cleanup.
"""
from std.collections import List
from std.ffi import external_call, c_int
from std.memory import Pointer
from std.time import monotonic


@fieldwise_init
struct CommandResult:
    var output: String
    var exit_code: Int
    var timed_out: Bool
    var truncated: Bool


@fieldwise_init
struct PollFD:
    var fd: c_int
    var events: Int16
    var revents: Int16


struct Child:
    var pid: c_int
    var fd: c_int
    var reaped: Bool

    def __init__(out self, pid: c_int, fd: c_int):
        self.pid = pid
        self.fd = fd
        self.reaped = False

    def __deinit__(deinit self):
        _ = external_call["kill", c_int](-self.pid, c_int(9))
        _ = external_call["close", c_int](self.fd)
        if not self.reaped:
            var status = c_int(0)
            _ = external_call["waitpid", c_int](
                self.pid, Pointer(to=status), c_int(0)
            )


def run_command(
    var command: String,
    var workspace: String,
    timeout: Int = 30,
    max_output: Int = 16000,
) raises -> CommandResult:
    if command.find("\0") >= 0 or workspace.find("\0") >= 0:
        raise Error("NUL is not allowed in command or workspace")
    # Prepare all C string storage before forking; lifetimes cover exec.
    var shell = String("/bin/bash")
    var arg0 = String("bash")
    var no_profile = String("--noprofile")
    var no_rc = String("--norc")
    var flag = String("-c")
    var null_path = String("/dev/null")
    var shell_ptr = shell.as_c_string_slice().unsafe_ptr()
    var arg0_ptr = arg0.as_c_string_slice().unsafe_ptr()
    var profile_ptr = no_profile.as_c_string_slice().unsafe_ptr()
    var rc_ptr = no_rc.as_c_string_slice().unsafe_ptr()
    var flag_ptr = flag.as_c_string_slice().unsafe_ptr()
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
    var workspace_ptr = workspace.as_c_string_slice().unsafe_ptr()
    var null_ptr = null_path.as_c_string_slice().unsafe_ptr()
    var pipes = List[c_int](length=2, fill=0)
    if external_call["pipe", c_int](pipes.unsafe_ptr()) != 0:
        raise Error("Cannot create process pipe")
    var pid = external_call["fork", c_int]()
    if pid < 0:
        _ = external_call["close", c_int](pipes[0])
        _ = external_call["close", c_int](pipes[1])
        raise Error("Cannot fork process")
    if pid == 0:
        _ = external_call["close", c_int](pipes[0])
        var ok = external_call["setpgid", c_int](c_int(0), c_int(0)) == 0
        ok = ok and external_call["chdir", c_int](workspace_ptr) == 0
        var stdin_fd = external_call["open", c_int, num_fixed_args=2](
            null_ptr, c_int(0)
        )
        ok = ok and stdin_fd >= 0
        ok = ok and external_call["dup2", c_int](stdin_fd, c_int(0)) >= 0
        ok = ok and external_call["dup2", c_int](pipes[1], c_int(1)) >= 0
        ok = ok and external_call["dup2", c_int](pipes[1], c_int(2)) >= 0
        _ = external_call["close", c_int](stdin_fd)
        _ = external_call["close", c_int](pipes[1])
        if ok:
            _ = external_call["execl", c_int, num_fixed_args=2](
                shell_ptr,
                arg0_ptr,
                profile_ptr,
                rc_ptr,
                flag_ptr,
                command_ptr,
                UInt(0),
            )
        external_call["_exit", NoneType](c_int(127))
    _ = external_call["close", c_int](pipes[1])
    # Both parent and child set the group to avoid a race before timeout cleanup.
    _ = external_call["setpgid", c_int](pid, pid)
    var child = Child(pid, pipes[0])
    var poll_fd = PollFD(pipes[0], 1, 0)
    var buffer = List[UInt8](length=8192, fill=0)
    var captured = List[UInt8]()
    var total = 0
    var status = c_int(0)
    var eof = False
    var timed_out = False
    var deadline = monotonic() + timeout * 1000000000
    while not eof or not child.reaped:
        if monotonic() >= deadline:
            timed_out = True
            break
        if not eof:
            var ready = external_call["poll", c_int](
                Pointer(to=poll_fd), UInt(1), c_int(50)
            )
            if ready > 0:
                var count = external_call["read", Int](
                    Int(child.fd), buffer.unsafe_ptr(), Int(8192)
                )
                if count == 0:
                    eof = True
                elif count > 0:
                    total += Int(count)
                    for i in range(min(Int(count), max_output - len(captured))):
                        captured.append(buffer[i])
        else:
            _ = external_call["poll", c_int](
                Pointer(to=poll_fd), UInt(0), c_int(10)
            )
        if not child.reaped:
            var waited = external_call["waitpid", c_int](
                pid, Pointer(to=status), c_int(1)
            )
            if waited == pid:
                child.reaped = True
            elif waited < 0:
                raise Error("Cannot wait for child process")
    _ = external_call["kill", c_int](-pid, c_int(9))
    if not child.reaped:
        if (
            external_call["waitpid", c_int](pid, Pointer(to=status), c_int(0))
            != pid
        ):
            raise Error("Cannot reap child process")
        child.reaped = True
    var exit_code = Int(status >> 8) & 255
    if status & 127 != 0:
        exit_code = -Int(status & 127)
    return CommandResult(
        String(from_utf8_lossy=captured),
        exit_code,
        timed_out,
        total > max_output,
    )
