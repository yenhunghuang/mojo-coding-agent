"""Offline behavioral tests: real Mojo tools, processes, curl and agent loop."""
from std.collections import List
from std.testing import assert_equal, assert_true, assert_false
from std.tempfile import TemporaryDirectory
from std.os import symlink, unlink
from std.os.path import exists, realpath
from config import Config, parse_args
from support.json import Json, quote
from support.files import read_text, write_text
from support.process import run_command
from support.http import post_json, shell_quote
from client import assistant_message
from agent import run
from tools import tool_result
from mock_server import MockServer


def config_for(workspace: String) -> Config:
    var config = Config()
    config.workspace = workspace
    config.model = "test/model"
    config.api_key = "offline-test-key"
    config.prompt = "Make and test a file"
    return config^


def ok(result: Json) raises -> Json:
    assert_equal(result.get("ok").raw, "true", result.raw)
    return result.get("result")


def fails(name: String, args: String, config: Config) raises:
    assert_equal(tool_result(name, args, config).get("ok").raw, "false")


def test_json() raises:
    var sample = Json.parse(
        '{"text":"\\ud83d\\udd25\\n中文","a":[true,null,-1.25e+2]}'
    )
    assert_equal(sample.get("text").string(), "🔥\n中文")
    assert_equal(len(sample.get("a").items()), 3)
    assert_equal(Json.parse(quote('\0\b\n\r\t\\"🔥')).string(), '\0\b\n\r\t\\"🔥')
    var invalid: List[String] = [
        "",
        "[1,]",
        "01",
        "1.",
        "true false",
        '{"a":1,"a":2}',
        '"\\ud800"',
        '"\\udc00"',
        '"\\x"',
        '{"x":}',
    ]
    for text in invalid:
        var raised = False
        try:
            _ = Json.parse(text)
        except:
            raised = True
        assert_true(raised, text)
    var nested = String("0")
    for _ in range(66):
        nested = "[" + nested + "]"
    var raised = False
    try:
        _ = Json.parse(nested)
    except:
        raised = True
    assert_true(raised)


def test_files() raises:
    with TemporaryDirectory() as temp:
        var config = config_for(temp)
        _ = ok(
            tool_result(
                "write", '{"path":"a","content":"一二\\nthree\\nfour\\n"}', config
            )
        )
        var result = ok(
            tool_result("read", '{"path":"a","start_line":2,"limit":1}', config)
        )
        assert_equal(result.get("output").string(), "2: three\n")
        assert_equal(result.get("total_lines").integer(), 3)
        assert_equal(result.get("truncated").raw, "true")
        result = ok(tool_result("read", '{"path":"a","max_output":4}', config))
        assert_equal(result.get("output").string(), "1: 一")
        assert_equal(result.get("truncated").raw, "true")
        assert_equal(
            ok(tool_result("read", '{"path":"a","start_line":100}', config))
            .get("output")
            .string(),
            "",
        )
        _ = ok(
            tool_result(
                "edit",
                '{"path":"a","old_text":"three","new_text":"new"}',
                config,
            )
        )
        assert_equal(read_text(temp + "/a"), "一二\nnew\nfour\n")
        _ = ok(
            tool_result(
                "edit", '{"path":"a","old_text":"new","new_text":""}', config
            )
        )
        assert_equal(read_text(temp + "/a"), "一二\n\nfour\n")
        _ = ok(
            tool_result(
                "edit", '{"path":"a","old_text":"一二","new_text":"你好"}', config
            )
        )
        assert_equal(read_text(temp + "/a"), "你好\n\nfour\n")
        var contents: List[String] = ["", "x", "x\n", "\n", "x\n\n"]
        var counts: List[Int] = [0, 1, 1, 1, 2]
        for i in range(len(contents)):
            write_text(temp + "/a", contents[i])
            assert_equal(
                ok(tool_result("read", '{"path":"a"}', config))
                .get("total_lines")
                .integer(),
                counts[i],
            )
        write_text(temp + "/a", "a\r\nb\r\n")
        _ = ok(
            tool_result(
                "edit", '{"path":"a","old_text":"b","new_text":"c"}', config
            )
        )
        assert_equal(read_text(temp + "/a"), "a\r\nc\r\n")


def test_validation() raises:
    with TemporaryDirectory() as temp:
        var config = config_for(temp)
        write_text(temp + "/a", "aaa")
        fails("edit", '{"path":"a","old_text":"aa","new_text":"x"}', config)
        fails("edit", '{"path":"a","old_text":"z","new_text":"x"}', config)
        fails("edit", '{"path":"a","old_text":"","new_text":"x"}', config)
        assert_equal(read_text(temp + "/a"), "aaa")
        fails("read", '{"path":"a","limit":true}', config)
        fails("read", '{"path":"a","limit":null}', config)
        fails("read", '{"path":"a","start_line":0}', config)
        fails("read", '{"path":"a","max_output":100001}', config)
        fails("read", '{"path":"missing"}', config)
        fails("read", '{"path":"."}', config)
        fails("read", "[]", config)
        fails("read", "{", config)
        fails("write", '{"path":"../escape","content":"x"}', config)
        fails("write", '{"path":"no/parent","content":"x"}', config)
        fails("write", '{"path":"a","content":5}', config)
        fails("write", '{"path":"a","content":"\\u0000"}', config)
        fails("bash", '{"command":"true","timeout":0}', config)
        fails("missing", "{}", config)
        assert_equal(read_text(temp + "/a"), "aaa")
        with TemporaryDirectory() as outside:
            symlink(outside, temp + "/link")
            fails("write", '{"path":"link/a","content":"x"}', config)
            unlink(temp + "/link")
        config.enabled = ["read"]
        fails("write", '{"path":"a","content":"x"}', config)
        var big = String("x")
        for _ in range(21):
            var copy = big
            big += copy
        var args = Json("{}")
        args.add("path", Json.text("a"))
        args.add("content", Json.text(big))
        config.enabled = ["write", "read"]
        fails("write", args.raw, config)
        write_text(temp + "/big", big, 4 * 1024 * 1024)
        fails("read", '{"path":"big"}', config)
        _ = run_command(
            "printf '\\377' > invalid; printf 'a\\0b' > binary", temp
        )
        fails("read", '{"path":"invalid"}', config)
        fails("read", '{"path":"binary"}', config)


def test_process() raises:
    with TemporaryDirectory() as temp:
        var r = run_command("printf hello; printf error >&2; exit 7", temp)
        assert_equal(r.output, "helloerror")
        assert_equal(r.exit_code, 7)
        assert_false(r.timed_out)
        assert_equal(run_command("pwd", temp).output.strip(), realpath(temp))
        var limited = run_command("yes x | head -c 200000", temp, 5, 50)
        assert_equal(limited.output.byte_length(), 50)
        assert_true(limited.truncated)
        var timeout = run_command("(sleep 2; touch escaped) & wait", temp, 1)
        assert_true(timeout.timed_out)
        assert_equal(timeout.exit_code, -9)
        _ = run_command("sleep 2", temp)
        assert_false(exists(temp + "/escaped"))
        var no_pipe = run_command("exec 1>&- 2>&-; sleep 10", temp, 1)
        assert_true(no_pipe.timed_out)
        assert_equal(run_command("read x; echo eof", temp).output, "eof\n")


def call(id: String, name: String, arguments: String) -> Json:
    var function = Json("{}")
    function.add("name", Json.text(name))
    function.add("arguments", Json.text(arguments))
    var result = Json("{}")
    result.add("id", Json.text(id))
    result.add("type", Json.text("function"))
    result.add("function", function)
    return result^


def reply(
    calls: Json, content: String = "", finish: String = "tool_calls"
) -> String:
    var message = Json("{}")
    message.add("role", Json.text("assistant"))
    message.add("content", Json.text(content))
    message.add("tool_calls", calls)
    var choice = Json("{}")
    choice.add("message", message)
    choice.add("finish_reason", Json.text(finish))
    var choices = Json("[]")
    choices.append(choice)
    var response = Json("{}")
    response.add("choices", choices)
    return response.raw


def one_call(id: String, name: String, args: String) -> Json:
    var calls = Json("[]")
    calls.append(call(id, name, args))
    return calls^


def test_loop() raises:
    with TemporaryDirectory() as temp:
        var second = one_call("b", "read", '{"path":"a"}')
        second.append(
            call("c", "edit", '{"path":"a","old_text":"old","new_text":"new"}')
        )
        var replies: List[String] = [
            reply(one_call("a", "write", '{"path":"a","content":"old"}')),
            reply(second),
            reply(
                one_call(
                    "d",
                    "bash",
                    '{"command":"test "$(cat a)" = new && echo passed"}',
                )
            ),
            reply(Json("[]"), "Finished", "stop"),
        ]
        var server = MockServer(replies, temp)
        var config = config_for(temp)
        config.base_url = server.url()
        var schemas = Json.parse(read_text("src/tools.json"))
        assert_equal(run(config, schemas), "Finished")
        assert_equal(read_text(temp + "/a"), "new")
        var wire = read_text(temp + "/request3.txt")
        assert_true(wire.startswith("POST /v1/chat/completions HTTP/1.1"))
        assert_true(wire.find("Authorization: Bearer offline-test-key") >= 0)
        var split = wire.find("\r\n\r\n") + 4
        var body = Json.parse(String(wire[byte=split:]))
        assert_equal(body.get("model").string(), "test/model")
        assert_equal(len(body.get("tools").items()), 4)
        var messages = body.get("messages").items()
        var ids: List[String] = ["a", "b", "c", "d"]
        var seen = 0
        for message in messages:
            if message.get("role").string() == "tool":
                assert_equal(message.get("tool_call_id").string(), ids[seen])
                _ = ok(Json.parse(message.get("content").string()))
                seen += 1
        assert_equal(seen, 4)
        assert_true(wire.find("passed") >= 0)


def test_recovery_and_limits() raises:
    with TemporaryDirectory() as temp:
        var replies: List[String] = [
            reply(one_call("a", "write", '{"path":"a","content":"x"}')),
            reply(Json("[]"), "Recovered", "stop"),
        ]
        var server = MockServer(replies, temp)
        var config = config_for(temp)
        config.enabled = ["read"]
        config.base_url = server.url()
        assert_equal(run(config, Json("[]")), "Recovered")
        assert_false(exists(temp + "/a"))
        assert_true(read_text(temp + "/request1.txt").find("not enabled") >= 0)
    with TemporaryDirectory() as temp:
        var replies: List[String] = [
            reply(one_call("a", "read", "{")),
            reply(one_call("b", "read", "{")),
        ]
        var server = MockServer(replies, temp)
        var config = config_for(temp)
        config.base_url = server.url()
        config.max_turns = 2
        var raised = False
        try:
            _ = run(config, Json("[]"))
        except error:
            raised = String(error).find("Turn limit") >= 0
        assert_true(raised)
        assert_true(exists(temp + "/request1.txt"))
    with TemporaryDirectory() as temp:
        var replies: List[String] = ['{"error":"private-server-body"}']
        var server = MockServer(replies, temp, 401)
        var raised = False
        try:
            _ = post_json(server.url(), "", "{}")
        except error:
            raised = String(error).find("curl exit 22") >= 0
            assert_true(String(error).find("private-server-body") < 0)
        assert_true(raised)


def test_compiled_cli() raises:
    with TemporaryDirectory() as temp:
        var replies: List[String] = [reply(Json("[]"), "CLI works", "stop")]
        var server = MockServer(replies, temp)
        var executable = shell_quote(realpath("build/mojo-agent"))
        var command = (
            "OPENAI_API_KEY=offline-test-key "
            + executable
            + " --model test --tools read --base-url "
            + shell_quote(server.url())
            + " 'hello'"
        )
        var result = run_command(command, temp)
        assert_equal(result.exit_code, 0, result.output)
        assert_true(result.output.find("CLI works") >= 0)
        var wire = read_text(temp + "/request0.txt")
        var split = wire.find("\r\n\r\n") + 4
        var body = Json.parse(String(wire[byte=split:]))
        var schemas = body.get("tools").items()
        assert_equal(len(schemas), 1)
        assert_equal(schemas[0].get("function").get("name").string(), "read")
        var invalid = run_command(executable + " --max-turns 0 hello", temp)
        assert_equal(invalid.exit_code, 1)
        assert_true(invalid.output.find("max-turns") >= 0)


def test_response_validation() raises:
    var calls = one_call("a", "write", '{"path":"a","content":"x"}')
    var invalid: List[String] = [
        reply(calls, "", "length"),
        '{"choices":[]}',
        reply(Json("[]"), "partial", "length"),
    ]
    calls.append(call("a", "write", "{}"))
    invalid.append(reply(calls))
    for text in invalid:
        var raised = False
        try:
            _ = assistant_message(Json.parse(text))
        except:
            raised = True
        assert_true(raised)
    var args: List[String] = ["--model", "test", "--tools", "read", "hello"]
    var config = parse_args(args)
    assert_true(config.allows("read"))
    assert_false(config.allows("write"))


def main() raises:
    test_json()
    print("PASS JSON syntax, Unicode, duplicate keys and depth")
    test_files()
    print("PASS read, write, edit, Unicode and CRLF")
    test_validation()
    print("PASS argument, ambiguity, path and file limits")
    test_process()
    print("PASS process output, exit code, timeout and child cleanup")
    test_loop()
    print("PASS real HTTP four-tool loop and message history")
    test_recovery_and_limits()
    print("PASS recovery, turn limit and HTTP failure")
    test_compiled_cli()
    print("PASS compiled CLI, schema discovery and teaching subset")
    test_response_validation()
    print("PASS model response and CLI validation")
