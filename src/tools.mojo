"""Four explicit tools: validate → execute → return a JSON result."""
from config import Config
from support.json import Json, boolean
from support.files import resolve_path, read_text, write_text
from support.process import run_command


def text_arg(
    args: Json, key: String, allow_empty: Bool = False
) raises -> String:
    var value = args.get(key).string()
    if not allow_empty and value.byte_length() == 0:
        raise Error("Argument must not be empty: " + key)
    return value


def int_arg(args: Json, key: String, default: Int, maximum: Int) raises -> Int:
    var field = args.get(key, String(default))
    var value = field.integer()
    if value < 1 or value > maximum:
        raise Error("Argument out of range: " + key)
    return value


def read_file(args: Json, path: String) raises -> Json:
    var start = int_arg(args, "start_line", 1, 1000000)
    var limit = int_arg(args, "limit", 200, 10000)
    var maximum = int_arg(args, "max_output", 16000, 100000)
    var content = read_text(path)
    var lines = content.split("\n")
    var count = len(lines)
    if content.byte_length() == 0:
        count = 0
    elif content.endswith("\n"):
        count -= 1
    var output = String()
    var used = 0
    var end = min(count, start - 1 + limit)
    var truncated = end < count
    for i in range(start - 1, end):
        var line = String(i + 1) + ": " + String(lines[i]) + "\n"
        for ch in line.codepoint_slices():
            if used == maximum:
                truncated = True
                break
            output += ch
            used += 1
        if truncated and used == maximum:
            break
    var result = Json("{}")
    result.add("output", Json.text(output))
    result.add("total_lines", Json(String(count)))
    result.add("truncated", boolean(truncated))
    return result^


def edit_file(args: Json, path: String) raises -> Json:
    var old = text_arg(args, "old_text")
    var new = text_arg(args, "new_text", True)
    var content = read_text(path)
    var first = content.find(old)
    if first < 0:
        raise Error("old_text not found; read the file before editing")
    # Find from next byte: overlapping matches (aaa / aa) are ambiguous too.
    if content.find(old, first + 1) >= 0:
        raise Error("old_text is ambiguous; include more surrounding text")
    write_text(path, content.replace(old, new))
    return Json('{"replacements":1}')


def execute(name: String, args: Json, config: Config) raises -> Json:
    if not config.allows(name):
        raise Error("Tool is not enabled: " + name)
    # get() also enforces that arguments are a JSON object.
    if name == "bash":
        var command = text_arg(args, "command")
        var timeout = int_arg(args, "timeout", 30, 300)
        var maximum = int_arg(args, "max_output", 16000, 100000)
        var command_result = run_command(
            command, config.workspace, timeout, maximum
        )
        var result = Json("{}")
        result.add("output", Json.text(command_result.output))
        result.add("exit_code", Json(String(command_result.exit_code)))
        result.add("timed_out", boolean(command_result.timed_out))
        result.add("truncated", boolean(command_result.truncated))
        return result^
    var path = resolve_path(config.workspace, text_arg(args, "path"))
    if name == "read":
        return read_file(args, path)
    if name == "write":
        var content = text_arg(args, "content", True)
        write_text(path, content)
        var result = Json("{}")
        result.add("bytes_written", Json(String(content.byte_length())))
        return result^
    if name == "edit":
        return edit_file(args, path)
    raise Error("Unknown tool: " + name)


def tool_result(name: String, arguments: String, config: Config) -> Json:
    var result = Json("{}")
    try:
        result.add("result", execute(name, Json.parse(arguments), config))
        result.add("ok", boolean(True))
    except error:
        result.add("ok", boolean(False))
        result.add("error", Json.text(String(error)))
    return result^
