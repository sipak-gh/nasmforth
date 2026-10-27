NASM ?= nasm
LD   ?= ld

# Static, libc-free ELF binary. -g -F dwarf keeps symbols for gdb.
nasmforth: nasmforth.o
	$(LD) -o $@ $<

nasmforth.o: nasmforth.asm
	$(NASM) -f elf64 -g -F dwarf -o $@ $<

test: nasmforth
	./tests/run.sh

fuzz: nasmforth
	./tests/fuzz.py

clean:
	rm -f nasmforth nasmforth.o

.PHONY: test fuzz clean
