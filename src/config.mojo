"""Small explicit CLI parser; no runtime or parser framework."""
from std.collections import List
from std.os import getenv
from std.os.path import realpath, isdir
from support.json import Json


struct Config(Copyable, Movable):
    var prompt: String
    var workspace: String
    var base_url: String
    var model: String
    var api_key: String
    var enabled: List[String]
    var max_turns: Int

    def __init__(out self):
        self.prompt = ""
        self.workspace = "."
        self.base_url = getenv("OPENAI_BASE_URL", "http://localhost:8080/v1")
        self.model = getenv("OPENAI_MODEL")
        self.api_key = getenv("OPENAI_API_KEY")
        self.enabled = ["read", "write", "edit", "bash"]
        self.max_turns = 20

    def allows(self, name: String) -> Bool:
        for enabled in self.enabled:
            if enabled == name:
                return True
        return False


def parse_args(args: List[String]) raises -> Config:
    var config = Config()
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg.startswith("--"):
            if i + 1 >= len(args):
                raise Error("Missing value for " + arg)
            i += 1
            var value = args[i]
            if arg == "--workspace":
                config.workspace = value
            elif arg == "--base-url":
                config.base_url = value
            elif arg == "--model":
                config.model = value
            elif arg == "--max-turns":
                config.max_turns = Json.parse(value).integer()
                if config.max_turns < 1 or config.max_turns > 100:
                    raise Error("--max-turns must be 1..100")
            elif arg == "--tools":
                config.enabled = List[String]()
                for part in value.split(","):
                    var item = String(part)
                    if (
                        item != "read"
                        and item != "write"
                        and item != "edit"
                        and item != "bash"
                    ):
                        raise Error("--tools accepts read,write,edit,bash")
                    if not config.allows(String(item)):
                        config.enabled.append(String(item))
            else:
                raise Error("Unknown option: " + arg)
        else:
            if config.prompt.byte_length() > 0:
                raise Error("Quote the prompt as one shell argument")
            config.prompt = arg
        i += 1
    if config.prompt.strip().byte_length() == 0:
        raise Error("Provide a prompt; use --help for usage")
    if config.model.strip().byte_length() == 0:
        raise Error("Set OPENAI_MODEL or --model")
    config.workspace = realpath(config.workspace)
    if not isdir(config.workspace):
        raise Error("--workspace must be a directory")
    return config^
