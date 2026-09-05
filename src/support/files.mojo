"""Native text I/O and workspace path checks."""
from std.io.file import open
from std.os.path import (
    realpath,
    join,
    dirname,
    basename,
    exists,
    lexists,
    isfile,
    isdir,
)


def resolve_path(workspace: String, path: String) raises -> String:
    if path.byte_length() == 0 or path.find("\0") >= 0:
        raise Error("Expected nonempty path without NUL")
    var root = realpath(workspace)
    var target = join(root, path)
    if lexists(target):
        target = realpath(target)
    else:
        # Existing parent required; also resolves parent symlinks before writing.
        target = join(realpath(dirname(target)), basename(target))
    var prefix = root + "/"
    if root == "/":
        prefix = "/"
    if not target.startswith(prefix) or target == root:
        raise Error("Path must stay inside workspace")
    if exists(target) and not isfile(target):
        raise Error("Path must be a regular file")
    return target


def read_text(path: String, maximum: Int = 1048576) raises -> String:
    if not isfile(path):
        raise Error("Expected an existing regular file")
    with open(path, "r") as file:
        var content = file.read(maximum + 1)
        if content.byte_length() > maximum:
            raise Error("File exceeds size limit")
        if content.find("\0") >= 0:
            raise Error("Binary files are not supported")
        return content


def write_text(path: String, content: String, maximum: Int = 1048576) raises:
    if content.byte_length() > maximum or content.find("\0") >= 0:
        raise Error("Expected text without NUL within size limit")
    if not isdir(dirname(path)):
        raise Error("Parent directory must already exist")
    with open(path, "w") as file:
        file.write_all(content.as_bytes())
