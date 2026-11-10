from __future__ import annotations

import json
import unittest
from unittest.mock import patch

import app
import rag_engine


class CalculatorTests(unittest.TestCase):
    def test_arithmetic(self) -> None:
        self.assertEqual(app.calculator("(25 * 4) + 10")["result"], 110)
        self.assertEqual(app.calculator("2 ** 8")["result"], 256)

    def test_rejects_code_and_extreme_exponents(self) -> None:
        with self.assertRaises(ValueError):
            app.calculator("__import__('os').getcwd()")
        with self.assertRaises(ValueError):
            app.calculator("2 ** 1000")


class ToolBoundaryTests(unittest.TestCase):
    def test_unknown_tool_and_arguments_are_rejected(self) -> None:
        self.assertFalse(app.execute_tool("not_allowed", {})["ok"])
        result = app.execute_tool("calculator", {"expression": "2 + 3", "extra": True})
        self.assertFalse(result["ok"])
        self.assertIn("unexpected argument", result["error"])

    def test_time_uses_iana_timezone(self) -> None:
        result = app.current_time("UTC")
        self.assertEqual(result["timezone"], "UTC")
        self.assertIn("T", result["iso8601"])

    def test_tool_call_accepts_object_or_json_arguments(self) -> None:
        name, arguments = app.parse_tool_call(
            {"function": {"name": "calculator", "arguments": {"expression": "2 + 3"}}}
        )
        self.assertEqual((name, arguments), ("calculator", {"expression": "2 + 3"}))
        name, arguments = app.parse_tool_call(
            {"function": {"name": "calculator", "arguments": '{"expression":"2 + 3"}'}}
        )
        self.assertEqual((name, arguments), ("calculator", {"expression": "2 + 3"}))


class AgentLoopTests(unittest.TestCase):
    def test_no_tool_answer(self) -> None:
        with patch.object(app, "call_ollama", return_value={"role": "assistant", "content": "Hello!"}):
            self.assertEqual(app.run_agent("Hello", show_tool_events=False), "Hello!")

    def test_tool_request_result_and_second_model_call(self) -> None:
        replies = [
            {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {"function": {"name": "calculator", "arguments": {"expression": "2 + 3"}}}
                ],
            },
            {"role": "assistant", "content": "The result is 5."},
        ]
        with patch.object(app, "call_ollama", side_effect=replies) as mocked:
            self.assertEqual(app.run_agent("What is 2 + 3?", show_tool_events=False), "The result is 5.")
        second_messages = mocked.call_args_list[1].args[0]
        tool_message = second_messages[-2]
        self.assertEqual(tool_message["role"], "tool")
        self.assertEqual(tool_message["tool_name"], "calculator")
        self.assertEqual(json.loads(tool_message["content"])["data"]["result"], 5)


class RetrievalTests(unittest.TestCase):
    def test_chunking_validation_and_boundaries(self) -> None:
        chunks = rag_engine.split_into_chunks("one two three four five", 10, 2)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(chunk.strip() == chunk for chunk in chunks))
        with self.assertRaises(ValueError):
            rag_engine.split_into_chunks("text", 10, 10)


if __name__ == "__main__":
    unittest.main()
