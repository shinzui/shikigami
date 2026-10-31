"""Strict, deliberately bounded reader for hand-owned Haskell type declarations.

The compiler remains the authority for validity and declaration inventory. This
reader supplies source-level constructor coordinates (without GHC's unpacking
coercions). Unknown forms fail closed rather than silently reducing coverage.
"""
import re


class DeclarationError(ValueError):
    pass


def uncomment(text):
    """Remove nested comments/pragmas, preserving layout and string literals."""
    output, i, depth = [], 0, 0
    while i < len(text):
        if depth:
            if text.startswith("{-", i):
                depth += 1
                i += 2
            elif text.startswith("-}", i):
                depth -= 1
                i += 2
                output.append(" ")
            else:
                output.append("\n" if text[i] == "\n" else " ")
                i += 1
        elif text.startswith("{-", i):
            depth = 1
            i += 2
            output.append(" ")
        elif text.startswith("--", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif text[i] == '"':
            end = i + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == '"':
                    end += 1
                    break
                else:
                    end += 1
            else:
                raise DeclarationError("unterminated string")
            output.append(text[i:end])
            i = end
        else:
            output.append(text[i])
            i += 1
    if depth:
        raise DeclarationError("unterminated comment")
    return "".join(output)


def split_top(text, separator):
    """Split a type only outside parentheses, records, lists and strings."""
    stack, quoted, escaped, start, result, i = [], False, False, 0, [], 0
    while i < len(text):
        c = text[i]
        if quoted:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
        elif c in "([{":
            stack.append(c)
        elif c in ")]}":
            if not stack or stack.pop() != {")": "(", "]": "[", "}": "{"}[c]:
                raise DeclarationError("unbalanced type delimiters")
        elif not stack and text.startswith(separator, i):
            result.append(text[start:i].strip())
            i += len(separator)
            start = i
            continue
        i += 1
    if stack or quoted:
        raise DeclarationError("unbalanced type delimiters/string")
    result.append(text[start:].strip())
    return result


def compact(text):
    return re.sub(r"\s+", " ", text).strip()


def record_members(constructor, body):
    result, selectors = [], []
    for part in split_top(body, ","):
        pieces = split_top(part, "::")
        if len(pieces) == 1:
            selectors.append(pieces[0])
            continue
        if len(pieces) != 2 or not pieces[1]:
            raise DeclarationError("unsupported record signature: " + part)
        selectors.append(pieces[0])
        for field in selectors:
            if not re.fullmatch(r"[a-z_][\w']*", field):
                raise DeclarationError("unsupported record selector: " + field)
            result.append({"member": constructor + "." + field, "type": compact(pieces[1])})
        selectors = []
    if selectors:
        raise DeclarationError("record selectors without a type")
    return result


def positional_types(text):
    # In an H98 constructor every argument is an atomic type. Applications and
    # function types must be parenthesized. Preserve strictness on that atom.
    result, position = [], 0
    text = text.strip()
    while position < len(text):
        start = position
        if text[position] in "!~":
            position += 1
            while position < len(text) and text[position].isspace():
                position += 1
        if position == len(text):
            raise DeclarationError("strictness marker without type")
        if text[position] in "([":
            opener = text[position]
            closer = ")" if opener == "(" else "]"
            depth, quoted, escaped = 0, False, False
            while position < len(text):
                c = text[position]
                if quoted:
                    if escaped:
                        escaped = False
                    elif c == "\\":
                        escaped = True
                    elif c == '"':
                        quoted = False
                elif c == '"':
                    quoted = True
                elif c == opener:
                    depth += 1
                elif c == closer:
                    depth -= 1
                    if depth == 0:
                        position += 1
                        break
                position += 1
            else:
                raise DeclarationError("unclosed positional type")
        else:
            match = re.match(r"(?:[A-Za-z_][\w']*\.)*[A-Za-z_][\w']*", text[position:])
            if not match:
                raise DeclarationError("unsupported positional type: " + text[position:])
            position += match.end()
        result.append(compact(text[start:position]))
        if position < len(text) and not text[position].isspace():
            raise DeclarationError("unsupported argument boundary: " + text[position:])
        while position < len(text) and text[position].isspace():
            position += 1
    return result


def constructor_members(text, gadt=False):
    text = text.strip()
    match = re.match(r"([A-Z][\w']*)\b", text)
    if not match:
        raise DeclarationError("unsupported constructor: " + text)
    constructor, rest = match[1], text[match.end():].strip()
    if gadt:
        if not rest.startswith("::"):
            raise DeclarationError("missing GADT constructor signature: " + text)
        rest = rest[2:].strip()
        rest = re.sub(r"^forall\s+[^.]+\.\s*", "", rest)
        rest = split_top(rest, "=>")[-1]
        arguments = split_top(rest, "->")[:-1]
        if arguments and arguments[0].startswith("{"):
            if len(arguments) != 1 or not arguments[0].endswith("}"):
                raise DeclarationError("unsupported GADT record: " + text)
            return record_members(constructor, arguments[0][1:-1])
    elif rest.startswith("{"):
        if not rest.endswith("}"):
            raise DeclarationError("unsupported record constructor: " + text)
        return record_members(constructor, rest[1:-1]) if rest[1:-1].strip() else []
    else:
        arguments = positional_types(rest)
    return [{"member": f"{constructor}.#{index}", "type": compact(value)}
            for index, value in enumerate(arguments, 1)]


def source_declarations(text, source_path="<input>"):
    try:
        clean = uncomment(text)
        result = []
        # Top-level declaration blocks end at the next nonindented item. This
        # includes standalone deriving/instances/functions, which are not types.
        blocks = re.split(r"(?m)(?=^\S)", clean)
        for block in blocks:
            match = re.match(r"(data|newtype|type)\s+([A-Z][\w']*)\b", block)
            if not match:
                if (re.match(r"(?:data|newtype|type)\s", block) and
                        not re.match(r"type\s+(?:instance|role)\b", block)):
                    raise DeclarationError("unsupported declaration: " + compact(block)[:160])
                continue
            kind, name = match[1], match[2]
            rest = block[match.end():]
            if kind == "type" and "=" not in rest:
                continue  # Standalone kind signature; definition is reviewed.
            rest = re.split(r"\bderiving\b", rest, maxsplit=1)[0].strip()
            if kind == "type":
                pieces = split_top(rest, "=")
                if len(pieces) != 2 or not pieces[1]:
                    raise DeclarationError("unsupported alias: " + name)
                members = []
            elif re.search(r"\bwhere\b", rest):
                header, body = re.split(r"\bwhere\b", rest, maxsplit=1)
                if "=" in header:
                    raise DeclarationError("unsupported GADT header: " + name)
                signatures = re.split(r"(?m)^\s*(?=[A-Z][\w']*\s*::)", body)
                members = []
                for signature in signatures:
                    if signature.strip():
                        members.extend(constructor_members(signature, gadt=True))
            elif "=" in rest:
                pieces = split_top(rest, "=")
                if len(pieces) != 2:
                    raise DeclarationError("unsupported declaration equation: " + name)
                members = []
                for constructor in split_top(pieces[1], "|"):
                    members.extend(constructor_members(constructor))
            elif not rest:
                members = []  # Empty datatype.
            else:
                raise DeclarationError("unsupported declaration body: " + name)
            keys = [m["member"] for m in members]
            if len(set(keys)) != len(keys):
                raise DeclarationError("duplicate constructor member in " + name)
            result.append({"name": name, "kind": "alias" if kind == "type" else kind,
                           "sourceDeclaration": block.strip(), "members": members})
        return sorted(result, key=lambda item: item["name"])
    except DeclarationError as exc:
        raise DeclarationError(f"{source_path}: {exc}") from exc
