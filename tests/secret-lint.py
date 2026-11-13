#!/usr/bin/env python3
"""secret-lint: spec 21's static check for secrets in shell scripts. The same file in every changed repo.

Usage: secret-lint.py FILE...    (exit 1 if anything is found, 2 on a usage error)

It reports, for every secret variable (see is_secret):
  unquoted  an unquoted expansion, which bash splits on spaces and globs (ShellCheck's SC2086 at that variable)
  echo      the value given to echo, which reads -n and -e as options: use printf '%s' (rule 1)
  eval      the value in eval, which runs it as code
  sed       the value in a sed command, where & \\ / and the delimiter mean something
  --set     the value in a Helm --set, which splits on , and = and reads { [ \\
A masked expansion, ${NAME:+...}, holds no secret and is never reported. Neither is a test such as [[ -n "$NAME" ]].
Heredoc bodies are skipped: what a heredoc writes is a file format, and each repo's unit tests check those.
A line that ends in '# secret-lint: ok <reason>' is skipped, so every exception says why it's safe.
"""
import json
import re
import subprocess
import sys

SECRET_SEGMENTS = {"pass", "passwd", "password", "pw", "pwd", "secret", "token", "apikey", "passphrase"}
SECRET_SUFFIXES = ("access_key", "secret_key", "api_key", "vision_key")
# A name with one of these parts names something about a secret, not the secret: a path, a flag, a length.
NOT_SECRET_SEGMENTS = {"file", "files", "path", "dir", "url", "ref", "sha256", "cfg", "set", "seen", "len", "count",
                       "flag", "mode", "tmp", "env", "name", "names", "user", "prompt", "check", "rule", "hint", "re",
                       "id", "ids", "var", "vars", "opt", "opts", "arg", "args", "changed", "given", "source", "src",
                       "desc", "refused", "msg", "message", "label", "help"}
EXPANSION = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)(:?[-+=?])?")
OK_MARK = re.compile(r"#\s*secret-lint:\s*ok\b")
HEREDOC = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
TEST_USE = re.compile(r"(-[nz]|[!=]=|=~)\s*\"?$")


def is_secret(name):
    n = name.lower()
    parts = n.split("_")
    if any(p in NOT_SECRET_SEGMENTS for p in parts):
        return False
    return any(p in SECRET_SEGMENTS for p in parts) or n.endswith(SECRET_SUFFIXES)


def code_lines(text):
    """(line number, line) for each line that's shell code: not a comment, not inside a heredoc body."""
    pending = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if pending:
            strip_tabs, word = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == word:
                pending.pop(0)
            i += 1
            continue
        if not line.lstrip().startswith("#"):
            yield i + 1, line
            for m in HEREDOC.finditer(line):
                pending.append((m.group(1) == "-", m.group(3)))
        i += 1


def secret_uses(line, start=0):
    """Secret expansions in line[start:] that carry the value: not masked (${X:+...}) and not a test's operand."""
    for m in EXPANSION.finditer(line, start):
        name, op = m.group(1), m.group(2)
        if not is_secret(name) or op == ":+" or op == "+":
            continue
        if TEST_USE.search(line[:m.start()]):
            continue
        yield m


def unquoted(path, text):
    """SC2086 findings whose variable is a secret."""
    try:
        out = subprocess.run(["shellcheck", "-f", "json1", "-s", "bash", "-i", "SC2086", path],
                             capture_output=True, text=True).stdout
        comments = json.loads(out or "{}").get("comments", [])
    except (OSError, ValueError) as e:
        sys.exit(f"secret-lint: shellcheck failed on {path}: {e}")
    lines = text.split("\n")
    for c in comments:
        line = lines[c["line"] - 1]
        for candidate in (line, line.expandtabs(8)):
            m = EXPANSION.match(candidate, c["column"] - 1)
            if m:
                break
        if not m or not is_secret(m.group(1)) or m.group(2) in (":+", "+") or OK_MARK.search(line):
            continue
        yield c["line"], "unquoted", m.group(1), line


COMMANDS = [("echo", re.compile(r"(?:^|[;&|({)`]|\$\(|\bthen|\bdo|\belse)\s*echo\b")),
            ("eval", re.compile(r"(?:^|[;&|({)`]|\$\(|\bthen|\bdo|\belse)\s*eval\b")),
            ("sed", re.compile(r"\bsed\b")),
            ("--set", re.compile(r"--set(?:-string|-literal)?\b"))]


def command_uses(text):
    for n, line in code_lines(text):
        if OK_MARK.search(line):
            continue
        for kind, rx in COMMANDS:
            for m in rx.finditer(line):
                # Up to the end of that command: the next ; && || or | outside a $( )
                rest = line[m.end():]
                end = re.search(r"(?:;|&&|\|\|?)(?![^(]*\))", rest)
                segment = line[:m.end() + (end.start() if end else len(rest))]
                for u in secret_uses(segment, m.end()):
                    yield n, kind, u.group(1), line
                    break


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    found = 0
    for path in argv:
        text = open(path, encoding="utf-8", errors="replace").read()
        hits = sorted(set(unquoted(path, text)) | set(command_uses(text)))
        for n, kind, name, line in hits:
            print(f"{path}:{n}: {kind} {name}: {line.strip()[:160]}")
            found += 1
    if found:
        print(f"secret-lint: {found} finding(s). Quote the expansion, use printf '%s', or keep the secret out of "
              f"eval, sed and --set. A deliberate exception ends its line with '# secret-lint: ok <reason>'.")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
