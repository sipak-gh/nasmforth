# NASMForth

A minimal [Forth](https://en.wikipedia.org/wiki/Forth_(programming_language)) interpreter in
x86-64 NASM for Linux. It's a single source file, uses no libc, and builds to a ~9 KB binary.

```sh
$ echo '2 3 + dup .s cr * . cr' | ./nasmforth
<2> 5 5 
25 
```

## Build

Requires x86-64 Linux, NASM 2.x, GNU `ld`, and `make`. For source-level debugging in gdb you
need NASM ≥ 2.16, because 2.15 writes broken DWARF line info.

```sh
make                    # build ./nasmforth (use NASM=/path/to/nasm if it isn't on PATH)
make test               # run the tests
make fuzz               # compare 5000 random programs against a Python model
./nasmforth < prog.fs   # or run it with no arguments and type; Ctrl-D exits
```

## Words

| Arithmetic | Stack | Output | Control |
|------------|-------|--------|---------|
| `+ - * / mod` | `dup drop swap over` | `. .s emit cr` | `bye` |

`.` pops and prints the top of the stack, and `.s` prints the whole stack without changing it.
Errors print to stderr, clear the stack, and skip the rest of the line.

## Docs

- [docs/REFERENCE.md](docs/REFERENCE.md): every word, with its stack effect and an example, plus
  input rules and errors.
- [docs/INTERNALS.md](docs/INTERNALS.md): how the interpreter works and how to add a word.
