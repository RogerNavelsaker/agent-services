import json

from headroom.config import (
    DEFAULT_EXCLUDE_TOOLS,
    DEFAULT_VERBATIM_EXCLUDE_TOOLS,
    is_tool_excluded,
)
from headroom.transforms.content_router import ContentRouter, ContentRouterConfig


class CharacterTokenizer:
    def count_text(self, text: str) -> int:
        return len(text)


def recovery_result(tool_name: str, wire_format: str) -> str:
    content = json.dumps(
        [{"id": i, "value": "x" * 20, "active": i % 2 == 0} for i in range(60)],
        indent=2,
    )
    if wire_format == "anthropic":
        messages = [
            {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_rec_1",
                        "name": tool_name,
                        "input": {"handle": "ccr://abc123"},
                    }
                ],
            },
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_rec_1", "content": content}
                ],
            },
        ]
        output = ContentRouter(ContentRouterConfig()).apply(messages, CharacterTokenizer())
        return output.messages[1]["content"][0]["content"]

    messages = [
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_rec_1",
                    "type": "function",
                    "function": {
                        "name": tool_name,
                        "arguments": '{"handle":"ccr://abc123"}',
                    },
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_rec_1", "content": content},
    ]
    output = ContentRouter(ContentRouterConfig()).apply(messages, CharacterTokenizer())
    return output.messages[1]["content"]


def test_recovery_names_are_excluded_from_lossy_and_verbatim_transforms() -> None:
    for name in ("caveman_retrieve", "mcp__caveman__caveman_retrieve"):
        assert is_tool_excluded(name, DEFAULT_EXCLUDE_TOOLS)
        assert is_tool_excluded(name, DEFAULT_VERBATIM_EXCLUDE_TOOLS)


def test_openai_recovery_result_remains_byte_exact() -> None:
    for name in ("caveman_retrieve", "mcp__caveman__caveman_retrieve"):
        content = recovery_result(name, "openai")
        assert content == json.dumps(
            [{"id": i, "value": "x" * 20, "active": i % 2 == 0} for i in range(60)],
            indent=2,
        )


def test_anthropic_recovery_result_remains_byte_exact() -> None:
    for name in ("caveman_retrieve", "mcp__caveman__caveman_retrieve"):
        content = recovery_result(name, "anthropic")
        assert content == json.dumps(
            [{"id": i, "value": "x" * 20, "active": i % 2 == 0} for i in range(60)],
            indent=2,
        )


def test_other_retrieve_tools_are_not_blanket_excluded() -> None:
    assert not is_tool_excluded("memory_retrieve", DEFAULT_EXCLUDE_TOOLS)
    assert not is_tool_excluded("memory_retrieve", DEFAULT_VERBATIM_EXCLUDE_TOOLS)


if __name__ == "__main__":
    for test in (
        test_recovery_names_are_excluded_from_lossy_and_verbatim_transforms,
        test_openai_recovery_result_remains_byte_exact,
        test_anthropic_recovery_result_remains_byte_exact,
        test_other_retrieve_tools_are_not_blanket_excluded,
    ):
        test()
