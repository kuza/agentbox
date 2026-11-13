"""The TOML reader of agentbox. lib/toml.sh runs it; see there.

    python3 -I toml-reader.py <schema file> <kind> <file>

Writes records to stdout, each as five fields that end with a NUL:
the type (value or error), the key or the error code, the line,
the end line, and the value for bash or the message. Exit 0: the file is
good. Exit 4: the file is bad, and the records tell why. Any other exit
status is a failure of the reader.
"""
import datetime
import re
import sys
import tomllib

KEY_LINE = re.compile(r"\s*([A-Za-z0-9_-]+)\s*=")
SYNTAX_LINE = re.compile(r"\s*\(at line (\d+), column \d+\)$|\s*\(at end of document\)$")

schema_path, kind, path = sys.argv[1:4]
with open(schema_path, "rb") as f:
    schema = tomllib.load(f)
records = []
bad = False


def record(rtype, key, line, endline, text):
    records.append("\0".join([rtype, key, str(line), str(endline), text]) + "\0")


def error(code, line, message):
    global bad
    bad = True
    record("error", code, line, line, message)


def finish():
    # A bad file gives its errors only, no values.
    # UTF-8 out, whatever the locale is.
    sys.stdout.buffer.write("".join(r for r in records if not bad or r.startswith("error\0")).encode())
    sys.exit(4 if bad else 0)


def split_lines(t):
    """The lines as TOML counts them: split at "\n" only (a "\r" before it
    goes). str.splitlines also splits at U+2028 and U+0085, which TOML
    allows in a comment or a string."""
    out = [x.removesuffix("\r") for x in t.split("\n")]
    if out and out[-1] == "":
        out.pop()
    return out


with open(path, "rb") as f:
    raw = f.read()
try:
    text = raw.decode()
    data = tomllib.loads(text)
except UnicodeDecodeError as e:
    error("syntax", raw[: e.start].count(b"\n") + 1, "not valid UTF-8")
    finish()
except tomllib.TOMLDecodeError as e:
    message = str(e)
    m = SYNTAX_LINE.search(message)
    last = max(len(split_lines(text)), 1)
    line = getattr(e, "lineno", None) or (int(m.group(1)) if m and m.group(1) else last)
    # Python 3.14 gives "lineno": at the end of the document, the line after
    # the last newline. Earlier versions name no line there. Both give the
    # last line of the file.
    line = min(line, last)
    error("syntax", line, "not valid TOML: " + (message[: m.start()] if m else message))
    finish()

lines = split_lines(text)


def find_line(pattern, default=1):
    for n, s in enumerate(lines, 1):
        if re.match(pattern, s):
            return n
    return default


def starts_statement(n):
    """True when line n starts a key or a header. The text before such a
    line is complete TOML; a line in a multi-line array is not."""
    try:
        tomllib.loads("\n".join(lines[: n - 1]))
        return True
    except tomllib.TOMLDecodeError:
        return False


def key_line(key, before):
    """The line of a top-level key (key =, "key" =, key.x =) before line
    'before', else 0."""
    k = re.escape(key)
    for n, s in enumerate(lines[: before - 1], 1):
        if re.match(rf"""\s*(?:{k}|"{k}"|'{k}')\s*[.=]""", s) and starts_statement(n):
            return n
    return 0


# A key with "newest" (the format of a manifest) is read first: a newer
# file can have keys that this schema does not know.
for key, rules in schema.items():
    value = data.get(key)
    if "newest" in rules and type(value) is int and value > rules["newest"]:
        error("newer-format", key_line(key, len(lines) + 1) or 1, f"'{key}' is {value}: this file needs a newer agentbox")
        finish()


def opens_multi_line(s):
    """The quotes that open a multi-line string on line s, else None.
    Single-line strings and the comment are skipped, so a \"\"\" inside them
    does not count."""
    i = 0
    while i < len(s):
        c = s[i]
        if c == "#":
            return None
        if s.startswith('"""', i) or s.startswith("'''", i):
            return s[i : i + 3]
        if c == '"':
            i += 1
            while i < len(s) and s[i] != '"':
                i += 2 if s[i] == "\\" else 1
        elif c == "'":
            i = s.find("'", i + 1)
            if i < 0:
                return None
        i += 1
    return None


# A line of a multi-line string can look like a key: refused first. The
# lines up to the closing quotes are skipped.
closing = None
for n, s in enumerate(lines, 1):
    if closing:
        if closing in s:
            closing = None
        continue
    closing = opens_multi_line(s)
    if closing:
        error("multi-line-string", n, "a multi-line string is not allowed")
        if closing in s[s.index(closing) + 3 :]:
            closing = None
if bad:
    finish()


# The line of each key: a scan for a bare key at the start of a line,
# checked against the keys that tomllib gives. A value ends before the
# next key, without the empty lines and comments in between.
starts = {}
for n, s in enumerate(lines, 1):
    m = KEY_LINE.match(s)
    if m and m.group(1) in data and m.group(1) not in starts:
        starts[m.group(1)] = n
ends = {}
for key, start in starts.items():
    end = min([s for s in starts.values() if s > start], default=len(lines) + 1) - 1
    while end > start and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith("#")):
        end -= 1
    ends[key] = end


def form_error(key, value, newline=False):
    """The code and message for a value in a form that is refused, else None.
    newline: a newline in a string is allowed."""
    if isinstance(value, float):
        return "float", f"'{key}': a float is not allowed; use quotes"
    if isinstance(value, (datetime.date, datetime.time)):
        return "date", f"'{key}': a date or time is not allowed; use quotes"
    if isinstance(value, dict):
        return "table", f"'{key}': a table is not allowed"
    if isinstance(value, str) and any((ord(c) < 32 and not (newline and c == "\n")) or ord(c) == 127 for c in value):
        return "control-character", f"'{key}': a control character in a value is not allowed"
    if isinstance(value, list):
        for item in value:
            found = form_error(key, item)
            if found:
                return found
    return None


def for_bash(key, value, want, join=" "):
    """The value as bash gets it, or an error message for a wrong type."""
    is_int = isinstance(value, int) and not isinstance(value, bool)
    if want == "any":
        want = {bool: "bool", int: "int", str: "string", list: "list"}[type(value)]
        join = ","
    if want == "string" and isinstance(value, str):
        return value, None
    if want == "int" and is_int:
        return str(value), None
    if want == "bool" and isinstance(value, bool):
        return "1" if value else "0", None
    if want == "list" and isinstance(value, list):
        items = []
        for item in value:
            if isinstance(item, bool) or not isinstance(item, (str, int)):
                return None, f"'{key}': an item of the list must be a string or an integer"
            item = str(item)
            if not item:
                return None, f"'{key}': an item of the list cannot be empty"
            if " " in item or "," in item:
                return None, f"'{key}': an item of the list cannot hold a space or a comma"
            items.append(item)
        return join.join(items), None
    names = {"string": "a string", "int": "an integer", "bool": "true or false", "list": "a list"}
    return None, f"'{key}' must be {names[want]}"


# The manifest has nested tables. The flat path of a value is its keys
# with a dot between them. An array of tables counts from 0
# (servers.0.name). A table has the line of its header ([settings.X],
# [[servers]]), else the line of its key. A value in a table has the line
# of its table. An inline table in an array can be on any line of the
# array: it has line 0, and the message gives the path only.
headers = {}  # the flat path of a table and a dot ("servers.0.") -> the line of its header
arrays = {}  # the flat path of an array of tables -> its last index


def header_line(path, default):
    return min((n for p, n in headers.items() if p.startswith(path + ".")), default=default)


def walk(table, rules, prefix, line):
    """Checks a table of a manifest against its rules, and writes a record
    for each value. line: the line for a value in this table."""
    for key, value in table.items():
        path = prefix + key
        rule = rules.get(key, rules.get("*"))
        want = rule and rule["type"]
        at = key_line(key, first_header) if not prefix else line
        if isinstance(value, (dict, list)):
            at = header_line(path, at)
        if "." in key:
            error("dot-in-key", at, f"'{path}': a key with a dot is not allowed")
        elif not rule:
            error("unknown-key", at, f"unknown key '{path}'")
        elif rule is rules.get("*") and not re.fullmatch(rule["names"], key):
            error("bad-name", at, f"'{path}': the name must match {rule['names']}")
        elif want == "table":
            if not isinstance(value, dict):
                error("type", at, f"'{path}' must be a table")
                continue
            if "*" in rule["keys"]:
                record("value", path, at, at, " ".join(value))
            walk(value, rule["keys"], path + ".", at)
        elif want == "array-of-tables":
            if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
                error("type", at, f"'{path}' must be an array of tables")
                continue
            record("value", path + ".#", at, at, str(len(value)))
            for i, item in enumerate(value):
                walk(item, rule["keys"], f"{path}.{i}.", header_line(f"{path}.{i}", line))
        else:
            found = form_error(path, value, rule.get("newline"))
            if found:
                error(found[0], at, found[1])
                continue
            converted, message = for_bash(path, value, want)
            if message:
                error("type", at, message)
                continue
            if rule.get("items") and not all(re.fullmatch(rule["items"], str(i)) for i in value):
                error("bad-name", at, f"'{path}': each item must match {rule['items']}")
                continue
            record("value", path, at, at, converted)
    for key, rule in rules.items():
        if rule.get("required") and key not in table:
            error("missing-key", line if prefix else 1, f"the key '{prefix + key}' is missing")


if kind == "manifest":
    for n, s in enumerate(lines, 1):
        if not s.lstrip().startswith("[") or not starts_statement(n):
            continue
        try:
            node = tomllib.loads(s)
        except tomllib.TOMLDecodeError:
            continue
        path = ""
        while isinstance(node, dict) and len(node) == 1:
            key, node = next(iter(node.items()))
            path += key
            if isinstance(node, list):
                arrays[path] = arrays.get(path, -1) + 1
                node = node[0]
            if path in arrays:
                path += f".{arrays[path]}"
            path += "."
        headers[path] = n
    first_header = min(headers.values(), default=len(lines) + 1)
    walk(data, schema, "", 0)
    finish()

for key, value in data.items():
    line = starts.get(key)
    if "." in key:
        error("dot-in-key", find_line(r"""\s*["'][^"']*\.""", line or 1), "a key with a dot is not allowed")
        continue
    header = find_line(rf"\s*\[+\s*{re.escape(key)}\s*[\].]", 0)
    if line is None and header:
        # A table header: [x], [x.y] or [[x]].
        error("table", header, f"'{key}': a table is not allowed")
        continue
    if line is None and isinstance(value, dict):
        # A dotted key: "a.b = 1" makes a table "a".
        error("dot-in-key", find_line(rf"\s*{re.escape(key)}\s*\."), "a key with a dot is not allowed")
        continue
    if line is None:
        error("quoted-key", find_line(rf"""\s*["']{re.escape(key)}["']\s*="""), "a key in quotes is not allowed")
        continue
    found = form_error(key, value)
    if found:
        error(found[0], line, found[1])
        continue
    if key in schema:
        converted, message = for_bash(key, value, schema[key]["type"])
    elif kind == "config":
        # A setting of a module has no type: each type is good, and an
        # array joins with a comma. The checks in module.toml validate the
        # value. settings_load (lib/config.sh) warns about a key that no
        # module has.
        converted, message = for_bash(key, value, "any")
    else:
        error("unknown-key", line, f"unknown key '{key}'")
        continue
    if message:
        error("type", line, message)
        continue
    record("value", key, line, ends[key], converted)

for key, rules in schema.items():
    if rules.get("required") and key not in data:
        error("missing-key", 1, f"the key '{key}' is missing")

finish()
