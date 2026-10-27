# NASMForth Reference

Stack effects are written `( before -- after )`, with the top of the stack on the right.
Examples show input → exact stdout.

## Words

### Arithmetic

Signed 64-bit integers; overflow wraps.

| Word  | Stack            | Description                                  | Example               |
|-------|------------------|----------------------------------------------|-----------------------|
| `+`   | `( a b -- a+b )` | Add                                          | `2 3 + .` → `5 `      |
| `-`   | `( a b -- a-b )` | Subtract                                     | `10 3 - .` → `7 `     |
| `*`   | `( a b -- a*b )` | Multiply                                     | `6 7 * .` → `42 `     |
| `/`   | `( a b -- a/b )` | Divide, rounding toward zero                 | `-7 2 / .` → `-3 `    |
| `mod` | `( a b -- a%b )` | Remainder, same sign as `a`                  | `-7 2 mod .` → `-1 `  |

`/` and `mod` fail with *division by zero* if `b` is 0.

### Stack

| Word   | Stack              | Description           | Example                     |
|--------|--------------------|-----------------------|-----------------------------|
| `dup`  | `( a -- a a )`     | Copy top              | `5 dup * .` → `25 `         |
| `drop` | `( a -- )`         | Discard top           | `1 2 drop .` → `1 `         |
| `swap` | `( a b -- b a )`   | Exchange top two      | `1 2 swap .s` → `<2> 2 1 `  |
| `over` | `( a b -- a b a )` | Copy second to top    | `1 2 over .s` → `<3> 1 2 1 `|

`dup` and `over` fail with *stack overflow* if the stack is full.

### Output

| Word   | Stack      | Description                                              | Example                      |
|--------|------------|----------------------------------------------------------|------------------------------|
| `.`    | `( n -- )` | Pop and print `n` followed by a space                    | `1 2 . .` → `2 1 `           |
| `.s`   | `( -- )`   | Print the stack without changing it: `<depth>` then items bottom to top | `1 2 3 .s` → `<3> 1 2 3 ` |
| `emit` | `( c -- )` | Pop and print the byte `c`                               | `72 emit 105 emit` → `Hi`    |
| `cr`   | `( -- )`   | Print a newline                                          | `1 . cr` → `1 ⏎`             |

`.s` uses the same format as gforth's, which makes it handy for debugging.

### Control

| Word  | Stack    | Description          | Example               |
|-------|----------|----------------------|-----------------------|
| `bye` | `( -- )` | Exit with status 0   | `1 . bye 2 .` → `1 `  |

## Input

- Reads stdin until end of input or `bye`. The exit status is always 0.
- Tokens are separated by whitespace (any byte ≤ 32).
- Word names are case-sensitive.
- Any token that isn't a word must be a number: `-?[0-9]+`, decimal only. For example `42`,
  `-7` and `007` are numbers, but `+5`, `0x10` and `12abc` are unknown words.

## Errors

An error prints a message to stderr, clears the stack, skips the rest of the line, and
continues. This is Forth's `ABORT`.

| Message                        | Cause                                          |
|--------------------------------|------------------------------------------------|
| `error: unknown word: <token>` | Token is neither a word nor a number           |
| `error: stack underflow`       | Too few items for a word (checked before it runs) |
| `error: stack overflow`        | Push past 256 cells                            |
| `error: division by zero`      | `/` or `mod` with `b` = 0                      |

```
1 2 foo 3      → stderr: error: unknown word: foo   (3 is skipped)
.s             → <0>
```

## Limits

- Stack: 256 cells of 64 bits.
- Tokens: only the first 64 bytes are stored, so longer tokens are always unknown words.

## Differences from standard Forth

- No `:` definitions, control flow, variables, memory access, or comments.
- No `ok` prompt.
- Word lookup is case-sensitive.
- `/` rounds toward zero. gforth rounds down, so `-7 2 /` gives `-4` there.
