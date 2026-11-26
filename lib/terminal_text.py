"""The rule for terminal control characters, for lib/toml-reader.py and
lib/toml-writer.py. mcp_shown_into (lib/mcp.sh) has the same rule in bash.

A terminal control character can change the terminal or hide text:

    C0     U+0000 to U+001F
    DEL    U+007F
    C1     U+0080 to U+009F
    bidi   the bidirectional marks: U+061C, U+200E, U+200F, U+202A to
           U+202E, U+2066 to U+2069

A value with such a character is refused. A message shows each one in its
visible form: \\x1b for C0, DEL and C1, <U+202E> for a bidirectional mark.
"""

BIDI = {0x061C, 0x200E, 0x200F, *range(0x202A, 0x202F), *range(0x2066, 0x206A)}


def is_control(c, newline=False):
    """True for a terminal control character. newline: a newline is allowed."""
    o = ord(c)
    if newline and c == "\n":
        return False
    return o < 0x20 or 0x7F <= o <= 0x9F or o in BIDI


def first_control(text, newline=False):
    """The first terminal control character of text, else None."""
    return next((c for c in text if is_control(c, newline)), None)


def shown(text):
    """text with each terminal control character in its visible form, also
    a newline and a tab: the text stays on one line."""
    return "".join((f"\\x{ord(c):02x}" if ord(c) < 0x100 else f"<U+{ord(c):04X}>") if is_control(c) else c for c in text)
