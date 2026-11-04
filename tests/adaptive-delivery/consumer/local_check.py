"""The initial sample passes locally even though the producer emits version 2."""
import json
from pathlib import Path

contract = json.loads(Path(__file__).with_name("contract.json").read_text())
samples = {1: {"text": "hello"}, 2: {"value": {"text": "hello"}}}
value = samples[contract["version"]]
for key in contract["path"]:
    value = value[key]
assert value == "hello"
print("consumer local check passed")
