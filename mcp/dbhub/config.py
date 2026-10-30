"""dbhub.toml as DBHub gets it: your [[sources]], written anew, plus a
read-only execute_sql and a search_objects for each.

Reads your dbhub.toml on stdin with a real TOML parser and writes a new file
on stdout from what it parsed: nothing of the original text reaches DBHub,
so no construct there can be read one way here and another way by DBHub's
parser. Only [[sources]] may be there, their values only strings, numbers,
booleans and lists of those. Runs in the agentbox image (mcp/dbhub/mcp.sh),
with python3 -I and no network. Argument: the file's path, for messages.
"""
import re
import sys
import tomllib

PATH = sys.argv[1]
PLAIN = re.compile(r"[A-Za-z0-9_-]+")


def die(msg):
    sys.stderr.write(f"error: {PATH}: {msg}\n")
    sys.exit(1)


def string(s):
    out = []
    for ch in s:
        if ch in '"\\':
            out.append("\\" + ch)
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append(f"\\u{ord(ch):04x}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def value(v, where):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)  # inf and nan are TOML too
    if isinstance(v, str):
        # DBHub replaces ${VAR} in its config with its environment, where
        # the caller token is: such a value would not stay what is written.
        if "${" in v:
            die(f"{where}: '${{' is not supported (DBHub would read it as a variable)")
        return string(v)
    if isinstance(v, list) and not any(isinstance(x, (list, dict)) for x in v):
        return "[" + ", ".join(value(x, where) for x in v) + "]"
    die(f"{where}: only strings, numbers, booleans and lists of them")


try:
    doc = tomllib.loads(sys.stdin.read())
except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
    die(f"not valid TOML: {e}")

other = sorted(k for k in doc if k != "sources")
if other:
    die("only [[sources]] entries may be there (agentbox sets the tools, read-only), "
        f"found: {', '.join(other)}")
sources = doc.get("sources")
if not isinstance(sources, list) or not sources:
    die("no [[sources]] entry")

out = []
ids = []
seen = set()
for n, src in enumerate(sources, 1):
    if not isinstance(src, dict):
        die(f"sources entry {n} is not a table")
    sid = src.get("id")
    if not isinstance(sid, str) or not PLAIN.fullmatch(sid):
        die(f"[[sources]] entry {n} needs an id of letters, digits, _ or -")
    # DBHub names tools execute_sql_<id> with - as _: prod-db and prod_db collide.
    if sid.replace("-", "_") in seen:
        die(f"source id '{sid}' is the same as another once - counts as _")
    seen.add(sid.replace("-", "_"))
    ids.append(sid)
    out.append("[[sources]]")
    for key, v in src.items():
        if not PLAIN.fullmatch(key):
            die(f"source '{sid}': key '{key}' must be letters, digits, _ or -")
        out.append(f"{key} = {value(v, f'source {sid!r}, {key}')}")
    out.append("")

out.append("# Added by agentbox: read-only tools for each source.")
for sid in ids:
    out += ["", "[[tools]]", 'name = "execute_sql"', f"source = {string(sid)}", "readonly = true",
            "", "[[tools]]", 'name = "search_objects"', f"source = {string(sid)}"]
sys.stdout.write("\n".join(out) + "\n")
