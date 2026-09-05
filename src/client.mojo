"""OpenAI-compatible request and complete-response validation."""
from std.collections import List
from config import Config
from support.json import Json
from support.http import post_json


def request_body(config: Config, messages: Json, schemas: Json) -> Json:
    var body = Json("{}")
    body.add("model", Json.text(config.model))
    body.add("messages", messages)
    body.add("tools", schemas)
    body.add("stream", Json("false"))
    return body^


def assistant_message(response: Json) raises -> Json:
    var choices = response.get("choices").items()
    if len(choices) == 0:
        raise Error("Model returned no choices")
    var choice = choices[0].copy()
    var message = choice.get("message")
    if message.get("role").string() != "assistant":
        raise Error("Expected assistant message")
    var calls = message.get("tool_calls")
    if not calls.is_null() and len(calls.items()) > 0:
        if choice.get("finish_reason").string() != "tool_calls":
            raise Error("Incomplete tool response; no tools executed")
        var items = calls.items()
        if len(items) > 16:
            raise Error("Too many tool calls (maximum 16)")
        var ids = List[String]()
        for call in items:
            if call.get("type").string() != "function":
                raise Error("Expected function tool call")
            var id = call.get("id").string()
            if id.byte_length() == 0:
                raise Error("Missing tool call ID")
            for previous in ids:
                if previous == id:
                    raise Error("Duplicate tool call ID")
            ids.append(id^)
            _ = call.get("function").get("name").string()
            _ = call.get("function").get("arguments").string()
    else:
        if choice.get("finish_reason").string() != "stop":
            raise Error("Model stopped before completing the task")
        if message.get("content").string().byte_length() == 0:
            raise Error("Model returned no final text")
    return message^


def complete(config: Config, messages: Json, schemas: Json) raises -> Json:
    var body = request_body(config, messages, schemas)
    return assistant_message(
        Json.parse(post_json(config.base_url, config.api_key, body.raw))
    )
