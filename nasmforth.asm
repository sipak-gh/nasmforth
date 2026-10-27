; ===========================================================================
; NASMForth - a minimal Forth interpreter. x86-64 Linux, no libc.
;
; Reads whitespace-separated tokens from stdin. Words are executed; anything
; else is parsed as a decimal integer and pushed onto the data stack.
;
; Global registers (owned by the interpreter):
;   r15  data stack pointer: next free cell, grows upward
;   r14  read position in inbuf
;   r13  bytes valid in inbuf
;
; Routines may clobber rax, rcx, rdx, rsi, rdi, r8-r11 unless noted;
; rbx and r12 are preserved.
; ===========================================================================

bits 64
default rel

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_EXIT    60

%define STDIN       0
%define STDOUT      1
%define STDERR      2

%define CELL        8           ; bytes per stack cell
%define STACK_CELLS 256         ; data stack capacity
%define TOKEN_MAX   64          ; longest token stored in full
%define INBUF_SIZE  4096        ; stdin read buffer
%define NUMBUF_SIZE 24          ; fits "-9223372036854775808"

; ---------------------------------------------------------------------------
; Dictionary: a static table of 32-byte entries, searched linearly.
;   +0   db  name length
;   +1   db  name, zero-padded
;   +16  dq  handler address
;   +24  dq  minimum stack depth (checked before the handler is called)
; ---------------------------------------------------------------------------

%define NAME_MAX      15
%define ENTRY_HANDLER 16
%define ENTRY_DEPTH   24
%define ENTRY_SIZE    32

; defword "name", handler, depth
%macro defword 3
%%start:
    db %%name_end - %%name
%%name:
    db %1
%%name_end:
%if (%%name_end - %%name) > NAME_MAX
    %error "word name too long"
%endif
    times ENTRY_HANDLER - (%%name_end - %%start) db 0
    dq %2
    dq %3
%endmacro

section .rodata

dict:
    defword "+",    w_add,  2
    defword "-",    w_sub,  2
    defword "*",    w_mul,  2
    defword "/",    w_div,  2
    defword "mod",  w_mod,  2
    defword "dup",  w_dup,  1
    defword "drop", w_drop, 1
    defword "swap", w_swap, 2
    defword "over", w_over, 2
    defword ".",    w_dot,  1
    defword ".s",   w_dots, 0
    defword "emit", w_emit, 1
    defword "cr",   w_cr,   0
    defword "bye",  w_bye,  0
dict_end:

msg_unknown:        db "error: unknown word: "
msg_unknown_len     equ $ - msg_unknown
newline:            db 10

; ---------------------------------------------------------------------------
; Mutable state
; ---------------------------------------------------------------------------

section .bss

dstack:     resq STACK_CELLS
dstack_end:
inbuf:      resb INBUF_SIZE
token:      resb TOKEN_MAX
numbuf:     resb NUMBUF_SIZE
charbuf:    resb 1
at_eol:     resb 1              ; 1 if the last token ended a line (or input)
at_eof:     resb 1              ; 1 once stdin is exhausted
rsp0:       resq 1              ; initial rsp, restored on abort

section .text
global _start

; ---------------------------------------------------------------------------
; Entry point and outer interpreter
; ---------------------------------------------------------------------------

_start:
    mov [rsp0], rsp
    lea r15, [dstack]
    xor r14, r14
    xor r13, r13
    mov byte [at_eol], 1

interpret:
    call read_token             ; rcx = token length
    test rcx, rcx
    jz w_bye                    ; end of input

    call find_word              ; rax = entry or 0
    test rax, rax
    jz .number

    mov rbx, rax                ; top level: nothing to preserve in rbx
    call depth
    cmp rax, [rbx + ENTRY_DEPTH]
    jb err_underflow
    call [rbx + ENTRY_HANDLER]
    jmp interpret

.number:
    call parse_number           ; rax = value, CF set if not a number
    jc err_unknown
    call dpush
    jmp interpret

; ---------------------------------------------------------------------------
; Data stack helpers
; ---------------------------------------------------------------------------

; dpush: push rax. Aborts on overflow.
dpush:
    lea rdx, [dstack_end]
    cmp r15, rdx
    jae err_overflow
    mov [r15], rax
    add r15, CELL
    ret

; dpop: pop into rax. Caller must ensure the stack isn't empty.
dpop:
    sub r15, CELL
    mov rax, [r15]
    ret

; depth: rax = number of cells on the stack.
depth:
    mov rax, r15
    lea rdx, [dstack]
    sub rax, rdx
    shr rax, 3
    ret

; ---------------------------------------------------------------------------
; Input
; ---------------------------------------------------------------------------

; getc: eax = next byte from stdin, or -1 at end of input.
; Read errors are treated as end of input.
getc:
    cmp r14, r13
    jb .have
    cmp byte [at_eof], 0
    jne .eof
    mov eax, SYS_READ
    mov edi, STDIN
    lea rsi, [inbuf]
    mov edx, INBUF_SIZE
    syscall
    test rax, rax
    jle .hit_eof
    xor r14, r14
    mov r13, rax
.have:
    lea rdx, [inbuf]
    movzx eax, byte [rdx + r14]
    inc r14
    ret
.hit_eof:
    mov byte [at_eof], 1
.eof:
    mov eax, -1
    ret

; read_token: skip whitespace and read the next token into `token`.
; Any byte <= ' ' counts as whitespace.
; Out: rcx = token length, 0 at end of input. A token longer than TOKEN_MAX
;      reports its full length but only its first TOKEN_MAX bytes are stored.
read_token:
    push rbx
    xor ebx, ebx                ; rbx = length so far
.skip:
    call getc
    cmp eax, -1
    je .done
    cmp eax, ' '
    jbe .skip
.store:
    cmp rbx, TOKEN_MAX
    jae .next
    lea rdx, [token]
    mov [rdx + rbx], al
.next:
    inc rbx
    call getc
    cmp eax, -1
    je .end_of_input
    cmp eax, ' '
    ja .store
    cmp eax, 10
    sete [at_eol]
    jmp .done
.end_of_input:
    mov byte [at_eol], 1
.done:
    mov rcx, rbx
    pop rbx
    ret

; skip_line: discard the rest of the current input line.
skip_line:
    cmp byte [at_eol], 0
    jne .done
.loop:
    call getc
    cmp eax, -1
    je .done
    cmp eax, 10
    jne .loop
.done:
    mov byte [at_eol], 1
    ret

; find_word: look up `token` (length rcx) in the dictionary.
; Out: rax = entry address, or 0 if not found. Preserves rcx.
find_word:
    cmp rcx, NAME_MAX
    ja .not_found
    lea rax, [dict]
    lea r8, [dict_end]
.loop:
    cmp rax, r8
    jae .not_found
    movzx edx, byte [rax]
    cmp rdx, rcx
    jne .next
    lea rsi, [rax + 1]
    lea rdi, [token]
    push rcx
    repe cmpsb
    pop rcx
    je .found
.next:
    add rax, ENTRY_SIZE
    jmp .loop
.not_found:
    xor eax, eax
.found:
    ret

; parse_number: parse `token` (length rcx) as a signed decimal integer:
; an optional '-' followed by one or more digits. Overflow wraps mod 2^64.
; Out: rax = value; CF clear on success, set on failure. Preserves rcx.
parse_number:
    cmp rcx, TOKEN_MAX
    ja .fail
    lea rsi, [token]
    mov rdx, rcx                ; rdx = bytes left
    xor eax, eax
    xor r8d, r8d                ; r8 = 1 if negative
    cmp byte [rsi], '-'
    jne .digit
    cmp rdx, 1
    je .fail
    mov r8d, 1
    inc rsi
    dec rdx
.digit:
    movzx r9d, byte [rsi]
    sub r9d, '0'
    cmp r9d, 9                  ; unsigned: also rejects bytes below '0'
    ja .fail
    imul rax, rax, 10
    add rax, r9
    inc rsi
    dec rdx
    jnz .digit
    test r8d, r8d
    jz .ok
    neg rax
.ok:
    clc
    ret
.fail:
    stc
    ret

; ---------------------------------------------------------------------------
; Output (unbuffered: every call is one write syscall)
; ---------------------------------------------------------------------------

; write_out / write_err: write rdx bytes at rsi to stdout / stderr.
write_out:
    mov edi, STDOUT
    jmp write_fd
write_err:
    mov edi, STDERR
write_fd:
    mov eax, SYS_WRITE
    syscall
    ret

; put_char: write the byte in al to stdout.
put_char:
    mov [charbuf], al
    lea rsi, [charbuf]
    mov edx, 1
    jmp write_out

; print_num: write rax to stdout as a signed decimal integer.
; Digits are generated right-to-left into numbuf.
print_num:
    lea rdi, [numbuf + NUMBUF_SIZE]
    mov rsi, rdi
    mov r8, rax                 ; keep the sign
    test rax, rax
    jns .digit
    neg rax                     ; INT64_MIN stays 2^63, which is right unsigned
.digit:
    mov ecx, 10
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digit
    test r8, r8
    jns .write
    dec rsi
    mov byte [rsi], '-'
.write:
    mov rdx, rdi
    sub rdx, rsi
    jmp write_out

; ---------------------------------------------------------------------------
; Errors: print a message to stderr, then abort - clear the data stack,
; discard the rest of the line, and resume. Safe to jump to from any call
; depth since rsp is reset.
; ---------------------------------------------------------------------------

; deferror label, "message": defines a routine that reports the message.
%macro deferror 2
[section .rodata]
%%msg: db %2, 10
%%len equ $ - %%msg
__SECT__
%1:
    lea rsi, [%%msg]
    mov edx, %%len
    jmp err_report
%endmacro

deferror err_underflow, "error: stack underflow"
deferror err_overflow,  "error: stack overflow"
deferror err_divzero,   "error: division by zero"

; err_unknown: rcx = length of the offending token.
err_unknown:
    push rcx
    lea rsi, [msg_unknown]
    mov edx, msg_unknown_len
    call write_err
    pop rdx
    cmp rdx, TOKEN_MAX
    jbe .print
    mov edx, TOKEN_MAX          ; only TOKEN_MAX bytes were stored
.print:
    lea rsi, [token]
    call write_err
    lea rsi, [newline]
    mov edx, 1
    call write_err
    jmp abort

err_report:
    call write_err
abort:
    mov rsp, [rsp0]
    lea r15, [dstack]
    call skip_line
    jmp interpret

; ---------------------------------------------------------------------------
; Words. Stack effects are ( before -- after ), rightmost = top.
; Top of stack is [r15 - CELL], next is [r15 - 2*CELL].
; User docs: docs/REFERENCE.md
; ---------------------------------------------------------------------------

; ( a b -- a+b )
w_add:
    call dpop
    add [r15 - CELL], rax
    ret

; ( a b -- a-b )
w_sub:
    call dpop
    sub [r15 - CELL], rax
    ret

; ( a b -- a*b )
w_mul:
    call dpop
    imul rax, [r15 - CELL]
    mov [r15 - CELL], rax
    ret

; divide: ( a b -- a ) and rax = a / b, rdx = a mod b, truncated toward
; zero like C. Aborts if b is zero.
divide:
    mov rcx, [r15 - CELL]
    test rcx, rcx
    jz err_divzero
    sub r15, CELL
    mov rax, [r15 - CELL]
    cmp rcx, -1
    je .by_minus_one            ; idiv faults on INT64_MIN / -1
    cqo
    idiv rcx
    ret
.by_minus_one:
    neg rax
    xor edx, edx
    ret

; ( a b -- a/b )
w_div:
    call divide
    mov [r15 - CELL], rax
    ret

; ( a b -- a%b )
w_mod:
    call divide
    mov [r15 - CELL], rdx
    ret

; ( a -- a a )
w_dup:
    mov rax, [r15 - CELL]
    jmp dpush

; ( a -- )
w_drop:
    sub r15, CELL
    ret

; ( a b -- b a )
w_swap:
    mov rax, [r15 - CELL]
    mov rdx, [r15 - 2*CELL]
    mov [r15 - CELL], rdx
    mov [r15 - 2*CELL], rax
    ret

; ( a b -- a b a )
w_over:
    mov rax, [r15 - 2*CELL]
    jmp dpush

; ( n -- )  print n followed by a space
w_dot:
    call dpop
    call print_num
    mov al, ' '
    jmp put_char

; ( -- )  print the stack without changing it, as "<depth> a b c "
w_dots:
    push rbx
    mov al, '<'
    call put_char
    call depth
    call print_num
    mov al, '>'
    call put_char
    mov al, ' '
    call put_char
    lea rbx, [dstack]           ; rbx walks from bottom to top
.loop:
    cmp rbx, r15
    jae .done
    mov rax, [rbx]
    call print_num
    mov al, ' '
    call put_char
    add rbx, CELL
    jmp .loop
.done:
    pop rbx
    ret

; ( c -- )  print the character with code c (low byte)
w_emit:
    call dpop
    jmp put_char

; ( -- )  print a newline
w_cr:
    mov al, 10
    jmp put_char

; ( -- )  exit with status 0
w_bye:
    mov eax, SYS_EXIT
    xor edi, edi
    syscall
