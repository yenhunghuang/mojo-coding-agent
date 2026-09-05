"""HTTPS via curl; Mojo owns payloads, limits, process lifetime, and errors."""
from std.tempfile import TemporaryDirectory
from support.files import write_text
from support.process import run_command


def shell_quote(value: String) -> String:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def curl_quote(value: String) raises -> String:
    if value.find("\n") >= 0 or value.find("\r") >= 0 or value.find("\0") >= 0:
        raise Error("Invalid newline or NUL in HTTP configuration")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def post_json(base_url: String, api_key: String, body: String) raises -> String:
    if not base_url.startswith("http://") and not base_url.startswith(
        "https://"
    ):
        raise Error("Base URL must use http:// or https://")
    var url = String(base_url.rstrip("/")) + "/chat/completions"
    # Private temporary directory keeps credentials out of argv and shell history.
    with TemporaryDirectory() as temp:
        var request = temp + "/request.json"
        var settings = temp + "/curl.conf"
        write_text(request, body, 16 * 1024 * 1024)
        var config = (
            "url = "
            + curl_quote(url)
            + '\nheader = "Content-Type: application/json"\n'
        )
        if api_key.byte_length() > 0:
            config += (
                "header = "
                + curl_quote("Authorization: Bearer " + api_key)
                + "\n"
            )
        config += "data-binary = " + curl_quote("@" + request) + "\n"
        write_text(settings, config)
        var command = (
            "exec curl --disable --silent --show-error --fail --max-time 120"
            " --max-filesize 4194304 --proto '=http,https' --request POST"
            " --config "
            + shell_quote(settings)
        )
        var response = run_command(command, temp, 125, 4194304)
        if response.timed_out:
            raise Error("Model request timed out")
        if response.exit_code != 0:
            raise Error(
                "Model request failed (curl exit "
                + String(response.exit_code)
                + "); check endpoint, model and credentials"
            )
        if response.truncated:
            raise Error("Model response exceeds 4 MiB")
        return response.output
    raise Error("HTTP request interrupted during temporary-file cleanup")
