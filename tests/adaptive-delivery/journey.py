#!/usr/bin/env python3
"""Independent user journey over an exact producer record and consumer contract."""
import argparse
import json
from pathlib import Path


def check(record, contract):
    if record["version"] != contract["version"]:
        raise ValueError("producer and consumer schema versions differ")
    value = record
    for key in contract["path"]:
        value = value[key]
    if value != "hello":
        raise ValueError("combined journey did not produce hello")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer", type=Path, required=True)
    parser.add_argument("--consumer", type=Path, required=True)
    args = parser.parse_args()
    try:
        check(json.loads(args.producer.read_text()), json.loads(args.consumer.read_text()))
    except (ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"journey failed: {error}\n")
    print("combined journey passed: hello")


if __name__ == "__main__":
    main()
