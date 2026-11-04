"""Producer-local validity intentionally does not establish consumer compatibility."""
import json
from pathlib import Path

record = json.loads(Path(__file__).with_name("record.json").read_text())
assert record["version"] == 2
assert isinstance(record["value"]["text"], str)
print("producer local check passed")
