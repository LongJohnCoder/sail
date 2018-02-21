SAIL_SRCS = prelude.sail riscv_types.sail riscv_sys.sail riscv.sail
SAIL_DIR ?= $(realpath ..)

export SAIL_DIR

all: riscv Riscv.thy

check: $(SAIL_SRCS) main.sail
	$(SAIL_DIR)/sail $^

riscv: $(SAIL_SRCS) main.sail
	$(SAIL_DIR)/sail -ocaml -o riscv $^

riscv_duopod_ocaml: prelude.sail riscv_duopod.sail
	$(SAIL_DIR)/sail -ocaml -o $@ $^

riscv_duopod.lem: prelude.sail riscv_duopod.sail
	$(SAIL_DIR)/sail -lem -lem_mwords -lem_lib Riscv_extras -o riscv_duopod $^
Riscv_duopod.thy: riscv_duopod.lem riscv_extras.lem
	lem -isa -outdir . -lib ../src/lem_interp -lib ../src/gen_lib \
		riscv_extras.lem \
		riscv_duopod_types.lem \
		riscv_duopod.lem

riscv_duopod: riscv_duopod_ocaml Riscv_duopod.thy

Riscv.thy: riscv.lem riscv_extras.lem
	lem -isa -outdir . -lib ../src/lem_interp -lib ../src/gen_lib \
		riscv_extras.lem \
		riscv_types.lem \
		riscv.lem

riscv.lem: $(SAIL_SRCS)
	$(SAIL_DIR)/sail -lem -o riscv -lem_mwords -lem_lib Riscv_extras $^

clean:
	-rm -rf riscv _sbuild
	-rm -f riscv.lem riscv_types.lem
	-rm -f Riscv.thy Riscv_types.thy \
		Riscv_extras.thy
	-rm -f Riscv_duopod.thy Riscv_duopod_types.thy riscv_duopod.lem riscv_duopod_types.lem
