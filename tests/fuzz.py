#!/usr/bin/env python3
"""Differential fuzzer: runs random programs through ./nasmforth and compares
stdout and stderr byte for byte against a Python model of the interpreter.

Usage: tests/fuzz.py [COUNT] [SEED]   (or `make fuzz`)
"""
import os
import random
import subprocess
import sys

DEPTH = {"+": 2, "-": 2, "*": 2, "/": 2, "mod": 2, "dup": 1, "drop": 1, "swap": 2,
         "over": 2, ".": 1, ".s": 0, "emit": 1, "cr": 0, "bye": 0}
STACK_CELLS = 256
TOKEN_MAX = 64


class Abort(Exception):
    pass


def wrap(x):
    """Wrap to a signed 64-bit integer."""
    x &= (1 << 64) - 1
    return x - (1 << 64) if x >> 63 else x


def model(src: bytes):
    """Reference implementation: returns (stdout, stderr)."""
    out, err, st = bytearray(), bytearray(), []

    def push(v):
        if len(st) >= STACK_CELLS:
            raise Abort("stack overflow")
        st.append(v)

    for line in src.split(b"\n"):
        try:
            for tok in bytes(c if c > 32 else 32 for c in line).split():
                t = tok.decode("latin-1")
                if t not in DEPTH:
                    digits = t[1:] if t.startswith("-") and len(t) > 1 else t
                    if len(tok) > TOKEN_MAX or not (digits.isascii() and digits.isdigit()):
                        raise Abort("unknown word: " + t[:TOKEN_MAX])
                    push(wrap(int(t)))
                    continue
                if len(st) < DEPTH[t]:
                    raise Abort("stack underflow")
                if t in ("/", "mod"):
                    a, b = st[-2], st[-1]
                    if b == 0:
                        raise Abort("division by zero")
                    q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
                    st[-2:] = [wrap(q if t == "/" else a - b * q)]
                elif t in ("+", "-", "*"):
                    b = st.pop()
                    st[-1] = wrap({"+": st[-1] + b, "-": st[-1] - b, "*": st[-1] * b}[t])
                elif t == "dup":  push(st[-1])
                elif t == "over": push(st[-2])
                elif t == "drop": st.pop()
                elif t == "swap": st[-1], st[-2] = st[-2], st[-1]
                elif t == ".":    out += b"%d " % st.pop()
                elif t == ".s":   out += b"<%d> " % len(st) + b"".join(b"%d " % v for v in st)
                elif t == "emit": out.append(st.pop() & 0xFF)
                elif t == "cr":   out += b"\n"
                elif t == "bye":  return bytes(out), bytes(err)
        except Abort as e:
            err += b"error: " + e.args[0].encode("latin-1") + b"\n"
            st.clear()
    return bytes(out), bytes(err)


def rand_token(r):
    k = r.random()
    if k < 0.45:
        return r.choice([w for w in DEPTH if w != "bye"])
    if k < 0.80:
        return str(r.randint(-20, 300))
    if k < 0.88:
        return str(r.choice([0, 1, -1, 2**63 - 1, -2**63, 2**64 + 5, -2**70]))
    if k < 0.93:
        return r.choice(["foo", "DUP", "+5", "0x1", "-", "--1", "1-", "x" * r.randint(60, 80)])
    if k < 0.96:
        return "bye"
    return "1 " * r.randint(250, 260)  # near the stack limit


def rand_program(r):
    seps = [" ", " ", " ", "\n", "\t", "\r\n", " \x01 "]
    return "".join(rand_token(r) + r.choice(seps) for _ in range(r.randint(0, 60))).encode()


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 32)
    os.chdir(os.path.join(os.path.dirname(__file__), ".."))
    r = random.Random(seed)
    for i in range(count):
        src = rand_program(r)
        got = subprocess.run(["./nasmforth"], input=src, capture_output=True)
        want = model(src)
        if (got.stdout, got.stderr) != want or got.returncode != 0:
            print(f"MISMATCH (seed {seed}, case {i}, exit {got.returncode})\n"
                  f"  input: {src!r}\n  got:   {(got.stdout, got.stderr)!r}\n  want:  {want!r}")
            sys.exit(1)
    print(f"{count} random programs matched (seed {seed})")


if __name__ == "__main__":
    main()
