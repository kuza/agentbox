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
    last = max(len(text.splitlines()), 1)
    line = getattr(e, "lineno", None) or (int(m.group(1)) if m and m.group(1) else last)
    # Python 3.14 gives "lineno": at the end of the document, the line after
    # the last newline. Earlier versions name no line there. Both give the
    # last line of the file.
    line = min(line, last)
    error("syntax", line, "not valid TOML: " + (message[: m.start()] if m else message))
    finish()

lines = text.splitlines()



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


def find_line(pattern, default=1):
    for n, s in enumerate(lines, 1):
        if re.match(pattern, s):
            return n
    return default


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


def form_error(key, value):
    """The code and message for a value in a form that is refused, else None."""
    if isinstance(value, float):
        return "float", f"'{key}': a float is not allowed; use quotes"
    if isinstance(value, (datetime.date, datetime.time)):
        return "date", f"'{key}': a date or time is not allowed; use quotes"
    if isinstance(value, dict):
        return "table", f"'{key}': a table is not allowed"
    if isinstance(value, str) and any(ord(c) < 32 or ord(c) == 127 for c in value):
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
        # A setting of a module: each type is good, and an array joins with
        # a comma. settings_load (lib/config.sh) warns about a key that no
        # module has. shortcut: no schema for a module setting in v0.2.0;
        # use the schema of the module manifest in step 2.
        want = {bool: "bool", int: "int", str: "string", list: "list"}[type(value)]
        converted, message = for_bash(key, value, want, ",")
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
