#!/usr/bin/env python3
"""Deployed-package check for the duplicate tool-parameter leniency rule.

Runs against the *installed* ftllm package (site-packages), not the repo
tree, so it proves what the production service actually imports.

Cases:
  1. repeated parameter with an IDENTICAL value  -> valid tool call (stream)
  2. same wire through the stream facade         -> no malformed_tool_block
  3. repeated parameter with CONFLICTING values  -> still rejected

Exit code 0 only when all three pass.
"""
import json
import sys

import ftllm
from ftllm.openai_server.protocal.openai_protocol import ChatCompletionRequest
from ftllm.openai_server.toolcall_parser import FunctionCallParser
from ftllm.openai_server.tool_parsers.qwen3coder_tool_parser import (
    Qwen3CoderToolParser,
)


class _DummyTokenizer:
    def get_vocab(self):
        return {"<tool_call>": 1, "</tool_call>": 2}


def _write_request():
    return ChatCompletionRequest(
        model="dummy",
        messages=[{"role": "user", "content": "write a file"}],
        tools=[{
            "type": "function",
            "function": {
                "name": "write",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "filePath": {"type": "string"},
                        "content": {"type": "string"},
                    },
                    "required": ["filePath", "content"],
                },
            },
        }],
        stream=True,
    )


def _wire_call(name, parameters):
    body = "".join(
        f"\n<parameter={key}>\n{value}\n</parameter>"
        for key, value in parameters
    )
    return f"<tool_call>\n<function={name}>{body}\n</function>\n</tool_call>"


def _merge(calls, parsed):
    for tool_call in (parsed.tool_calls if parsed else None) or []:
        call = calls.setdefault(tool_call.index,
                                {"name": "", "arguments": ""})
        function = tool_call.function
        if function is not None and function.name:
            call["name"] = function.name
        if function is not None and function.arguments:
            call["arguments"] += function.arguments


def _collect_stream(wire, request):
    parser = Qwen3CoderToolParser(_DummyTokenizer())
    calls = {}
    previous = ""
    current = previous + wire
    _merge(calls, parser.extract_tool_calls_streaming(
        previous, current, wire, [], [], [], request))
    _merge(calls, parser.finalize_streaming(request))
    return [calls[index] for index in sorted(calls)], parser


def main():
    print("ftllm package:", ftllm.__file__)
    print("parser module:",
          sys.modules[Qwen3CoderToolParser.__module__].__file__)
    ok = True
    request = _write_request()
    expected = {"filePath": "/tmp/a.cpp", "content": "int main() {}"}

    same = _wire_call("write", [
        ("filePath", "/tmp/a.cpp"),
        ("content", "int main() {}"),
        ("filePath", "/tmp/a.cpp"),
    ])
    differ = _wire_call("write", [
        ("filePath", "/tmp/a.cpp"),
        ("content", "int main() {}"),
        ("filePath", "/tmp/b.cpp"),
    ])

    calls, parser = _collect_stream(same, request)
    error = parser.streaming_parse_error()
    verdict = (error is None and len(calls) == 1
               and calls[0]["name"] == "write"
               and json.loads(calls[0]["arguments"]) == expected)
    print("1) identical-repeat streaming:",
          "PASS" if verdict else f"FAIL calls={calls} error={error!r}")
    ok &= verdict

    facade = FunctionCallParser.from_request(
        request, tool_parser_name="qwen3_coder",
        tokenizer=_DummyTokenizer())
    parsed = facade.parse_stream_chunk(
        previous_text="", current_text=same, delta_text=same,
        previous_token_ids=[], current_token_ids=[], delta_token_ids=[])
    diagnostics = facade.finalize_stream()
    flushed = facade.flush_stream_tool_calls()
    codes = [diagnostic.code for diagnostic in diagnostics]
    delivered = (len(parsed.valid_tool_calls)
                 + len(flushed.valid_tool_calls))
    verdict = "malformed_tool_block" not in codes and delivered == 1
    print("2) identical-repeat stream facade:",
          "PASS" if verdict else f"FAIL codes={codes} delivered={delivered}")
    ok &= verdict

    non_stream = Qwen3CoderToolParser(
        _DummyTokenizer()).extract_tool_calls(differ, request)
    calls, parser = _collect_stream(differ, request)
    error = parser.streaming_parse_error() or ""
    verdict = (not non_stream.tools_called and non_stream.tool_calls == []
               and calls == [] and "repeats parameter" in error)
    print("3) conflicting-repeat rejected:",
          "PASS" if verdict
          else f"FAIL tools_called={non_stream.tools_called} calls={calls} "
               f"error={error!r}")
    ok &= verdict

    print("DEPLOYED_CHECK", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
