#!/usr/bin/env python3
"""Regression guard: single-lane resumed Qwen continuations must be chunked."""
from pathlib import Path

source = Path(__file__).resolve().parents[2] / "src/models/qwen3_5.cpp"
text = source.read_text(encoding="utf-8")
start = text.index("auto scheduledDecodeTokens")
end = text.index("auto getPagedManagerFromCache", start)
body = text[start:end]

# A tool result may add thousands of tokens to a resumed ResponseContext.
# Lane=1 must still clamp that continuation before Qwen35MTPForward.
assert "ctx->preTokens > 0 && tokens > 1" in body, body
assert "useMtpBatchScheduling && ctx->preTokens > 0" not in body, body
assert "tokens = std::min(tokens, mtpBatchDecodeTokens);" in body, body
print("PASS: resumed continuation clamp applies independent of scheduler lanes")
