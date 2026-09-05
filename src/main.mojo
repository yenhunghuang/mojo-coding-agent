"""CLI → configuration → agent. Everything runs in Mojo."""
from std.collections import List
from std.sys import argv
from std.ffi import external_call, c_int
from std.os.path import dirname, join
from config import parse_args
from support.json import Json
from support.files import read_text
from agent import run


def main():
    try:
        var raw = argv()
        var args = List[String]()
        for i in range(1, len(raw)):
            if raw[i] == "--help" or raw[i] == "-h":
                print(
                    "Usage: pixi run start [options] 'prompt'\n\n--workspace"
                    " PATH   Working directory (default .)\n--tools NAMES     "
                    " read,write,edit,bash (or teaching subset)\n--model MODEL "
                    "     Or OPENAI_MODEL\n--base-url URL     Or"
                    " OPENAI_BASE_URL (default"
                    " http://localhost:8080/v1)\n--max-turns N      Model"
                    " requests, 1..100 (default 20)\n\nOPENAI_API_KEY supplies"
                    " an optional Bearer token. bash is not a sandbox."
                )
                return
            args.append(String(raw[i]))
        var config = parse_args(args)
        # Pixi's start task runs this source; built binaries keep tools.json nearby.
        var all_tools = Json.parse(
            read_text(join(dirname(String(raw[0])), "tools.json"))
        )
        var schemas = Json("[]")
        for tool in all_tools.items():
            if config.allows(tool.get("function").get("name").string()):
                schemas.append(tool)
        print(run(config, schemas))
    except error:
        print("Error:", error)
        external_call["exit", NoneType](c_int(1))
