"""The writer of the conversion: an old file of agentbox v0.1.x as TOML.
lib/convert.sh runs it; see there.

    python3 -I toml-writer.py <schema file> <form> <old file>

The forms of the old file:

    hosts  one host per line, # starts a comment (an egress group)
    keys   KEY=VALUE lines, as load_config in lib/config.sh reads them

Writes the TOML file to stdout. Each value gets the type of its key in the
schema, not the type that its look suggests. A key that the schema does
not know becomes a comment. The comments of the old file stay. Writes
"<old file>:<line>: <message>" lines to stderr: warnings with exit 0, the
errors with exit 4. Any other exit status is a failure of the writer.
"""
import re
import sys
import tomllib

schema_path, form, path = sys.argv[1:4]
with open(schema_path, "rb") as f:
    schema = tomllib.load(f)
out = []
errors = []


# UTF-8 out, whatever the locale is.
def message(n, text):
    sys.stderr.buffer.write(f"{path}:{n}: {text}\n".encode())


try:
    with open(path, "rb") as f:
        raw = f.read()
except OSError as e:
    message(1, f"cannot read the file: {e.strerror}")
    sys.exit(4)
# Bash splits lines at "\n" only. Bytes that are not UTF-8 become U+FFFD:
# allowed in a comment, refused in a value.
old = [line.removesuffix("\r") for line in raw.decode(errors="replace").split("\n")]
if old and old[-1] == "":
    old.pop()


def comment(text):
    """A comment as TOML allows it: no control character other than a tab."""
    return "".join("?" if (ord(c) < 32 and c != "\t") or ord(c) == 127 else c for c in text)


def string(n, value):
    """A TOML basic string; a control character is an error, as in the reader."""
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        errors.append((n, "a control character in a value is not allowed"))
    if "\ufffd" in value:
        errors.append((n, "not valid UTF-8"))
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def item(n, value):
    """An item of a list, with the rules of the reader."""
    if "," in value:
        errors.append((n, f"'{value}': an item of a list cannot hold a comma"))
    return string(n, value)


def typed(n, key, value):
    """The value in TOML, by the type of the key in the schema."""
    want = schema[key]["type"]
    if want == "list":
        return "[" + ", ".join(item(n, v) for v in re.split(r"[\s,]+", value) if v) + "]"
    if want == "bool" and value in ("0", "1"):
        return "true" if value == "1" else "false"
    if want == "int" and re.fullmatch(r"[0-9]+", value):
        return str(int(value))
    if want == "string":
        return string(n, value)
    errors.append((n, f"'{key}' must be {'0 or 1' if want == 'bool' else 'a number'}, not '{value}'"))
    return '""'


def hosts():
    items = None  # the lines of the array, after the first host
    for n, line in enumerate(old, 1):
        host, sharp, rest = line.partition("#")
        words = host.split()
        if not words:
            if items is None:
                out.append(comment(line.rstrip()))
            else:
                items.append("  " + comment(line.strip()) if line.strip() else "")
            continue
        if len(words) > 1:
            errors.append((n, "one host per line"))
            continue
        if items is None:
            items = []
        items.append(f"  {item(n, words[0])}," + (f"  #{comment(rest)}" if sharp else ""))
    out.append("hosts = [")
    out.extend(items or [])
    out.append("]")


def keys():
    seen = set()
    for n, line in enumerate(old, 1):
        s = line.strip()
        if not s or s.startswith("#"):
            out.append(comment(line.rstrip()))
            continue
        s = s.removeprefix("export ")
        key, eq, value = s.partition("=")
        if not eq or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            # load_config ignores the line, with a warning.
            message(n, "not KEY=VALUE, kept as a comment")
            out.append("# " + comment(s))
            continue
        m = re.fullmatch(r"\"([^\"]*)\"(\s+#.*)?|'([^']*)'(\s+#.*)?", value)
        if m:
            value = m.group(1) if m.group(1) is not None else m.group(3)
            note = m.group(2) or m.group(4) or ""
        else:
            m = re.search(r"\s#", value)
            note = value[m.start() :] if m else ""
            value = value[: m.start()].rstrip() if m else value.rstrip()
        # The key of a setting in the same case; an old key of a
        # description in uppercase becomes lowercase.
        name = key if key in schema else key.lower() if key.isupper() and key.lower() in schema else None
        if name is None or name in seen:
            # load_config takes the first of two equal keys.
            why = "unknown key" if name is None else "second time"
            message(n, f"{why} '{key}', kept as a comment")
            out.append("# " + comment(s))
            continue
        seen.add(name)
        out.append(f"{name} = {typed(n, name, value)}" + ("  " + comment(note.strip()) if note else ""))


{"hosts": hosts, "keys": keys}[form]()
for n, text in errors:
    message(n, text)
if errors:
    sys.exit(4)
sys.stdout.buffer.write(("\n".join(out) + "\n").encode())
