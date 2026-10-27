# NASMForth Internals

A guide to [`nasmforth.asm`](../nasmforth.asm). It's a static ELF64 binary that uses three
syscalls (`read`, `write`, `exit`) and no libc.

## Flow

```
stdin → getc → read_token → find_word ─┬─ found → depth check → call handler
                                       └─ else  → parse_number → dpush
any error → abort: reset rsp and stack, skip rest of line, back to interpret
```

## Registers

| Register | Role                                         |
|----------|----------------------------------------------|
| `r15`    | Data stack pointer: next free cell, grows up |
| `r14`    | Read position in `inbuf`                     |
| `r13`    | Bytes valid in `inbuf`                       |

Routines may clobber `rax rcx rdx rsi rdi r8–r11`, the System V caller-saved registers
(which include the ones `syscall` clobbers). They preserve `rbx` and `r12`.

The top of the stack is `[r15 - 8]`, the next item is `[r15 - 16]`, and the depth is
`(r15 - dstack) / 8`. The helpers `dpush`, `dpop` and `depth` wrap these.

## Dictionary

A static table built with `defword "name", handler, min_depth`. Each entry is 32 bytes:

| Offset | Field                         |
|--------|-------------------------------|
| 0      | Name length                   |
| 1      | Name (≤ 15 bytes, zero-padded)|
| 16     | Handler address               |
| 24     | Minimum stack depth           |

`find_word` searches the table linearly. The interpreter checks the depth before calling the
handler, so handlers never check for underflow. Pushes go through `dpush`, which checks for
overflow.

## Input and output

- `getc` reads stdin in 4 KiB chunks. Once `read` returns ≤ 0 it sets `at_eof` and stops
  making syscalls.
- `read_token` sets `at_eol` when a token ends at a newline, so `abort` knows whether there's
  still part of a line to discard.
- `parse_number` signals failure with the carry flag.
- Output is unbuffered, one `write` per call. `print_num` negates a negative value and then
  divides as unsigned, so `INT64_MIN` still prints correctly.

## Adding a word

```nasm
; ( a -- -a )
w_negate:
    neg qword [r15 - CELL]
    ret
```

Then add `defword "negate", w_negate, 1` to the table, a row in [REFERENCE.md](REFERENCE.md),
a test, and a case in the fuzzer's model.

## Testing and debugging

`make test` runs `tests/run.sh`, which pipes each input to `./nasmforth` and compares stdout and
stderr exactly:

```bash
check "name" "input" "expected stdout" ["expected stderr"]
```

`make fuzz` runs `tests/fuzz.py`, which sends random programs through both `./nasmforth` and a
Python model and compares the results byte for byte. On a mismatch it prints the seed, so you can
reproduce it with `tests/fuzz.py COUNT SEED`. A new word needs a matching case in the model.

The binary keeps DWARF symbols, so you can use `gdb ./nasmforth` and then
`break w_dots`, `run < prog.fs`, `x/4gd &dstack`. Stepping through source lines with `next` or
`list` needs NASM ≥ 2.16. With NASM 2.15 you can still break on symbols and use `stepi`.
