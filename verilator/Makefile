#
# Verilator harness for the VideoBrain core.
#
# The RTL is VHDL and Verilator reads only Verilog, so every build starts by
# running the design through "ghdl synth", which emits a Verilog netlist.
# Module and port names survive; internal combinational nodes become nNNNN.
# Registers, RAMs and ROMs keep their names, which is what the debug views
# and state dumps reach for.
#
# Requires: ghdl (VHDL-2008), verilator, sdl2 (graphical target only), zlib.
#

V     = verilator
GHDL  = ghdl
RTL   = ../rtl
GEN   = gen
WORK  = ghdl_work

TOP      = --top-module top
GEN_V    = $(GEN)/videobrain.v
VHD_TOP  = videobrain_core

# Analysis order matters: packages first, then leaves, then the assembly.
VHD_SRC = \
	$(RTL)/f8/base_pack.vhd \
	$(RTL)/f8/f8_pack.vhd \
	$(RTL)/uv201/uv201_pack.vhd \
	$(RTL)/uv202/uv202_pack.vhd \
	$(RTL)/f8/f8_cpu.vhd \
	$(RTL)/uv202/f8_busif.vhd \
	$(RTL)/uv202/uv202_clkgen.vhd \
	$(RTL)/uv202/uv202_timing.vhd \
	$(RTL)/uv202/uv202_arbiter.vhd \
	$(RTL)/uv202/uv202_top.vhd \
	$(RTL)/uv201/uv201_regs.vhd \
	$(RTL)/uv201/uv201_fetcher.vhd \
	$(RTL)/uv201/uv201_fifo.vhd \
	$(RTL)/uv201/uv201_yint.vhd \
	$(RTL)/uv201/uv201_render.vhd \
	$(RTL)/f3853.vhd \
	$(RTL)/buffered_bus.vhd \
	$(RTL)/sys_bus.vhd \
	$(RTL)/videobrain_io.vhd \
	$(RTL)/videobrain_core.vhd

# Modules converted from VHDL to Verilog by hand. Each name listed here is
# deleted from the synthesised netlist and must exist as rtl_v/<name>.v.
# Convert one at a time and diff the headless frame hash against the all-VHDL
# run to check equivalence:
#   make headless && ./obj_dir_headless/Vtop --res1 selftest.rom --frames 8 --frame-log
CONVERTED =

CONVERTED_V = $(patsubst %,rtl_v/%.v,$(CONVERTED))
V_SRC = sim.v $(GEN_V) $(CONVERTED_V)

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	# imgui_impl_sdl.cpp includes <SDL.h>, sim_video.cpp includes <SDL2/SDL.h>;
	# add the parent of SDL2/ so both spellings resolve.
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include
endif

ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
endif

CXXFLAGS += -I../sim/imgui -I../sim/ -O3 -std=c++17
LDFLAGS   = $(LIBS)

V_OPT = -O3 --x-assign fast --x-initial fast --noassert --public-flat-rw \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-ALWNEVER -Wno-DECLFILENAME

EXE = ./obj_dir/Vtop
C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp sim/sim_input.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp sim/imgui/imgui_draw.cpp \
	sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp \
	sim/imgui/ImGuiFileDialog.cpp

HL_DIR = obj_dir_headless
HL_EXE = ./$(HL_DIR)/Vtop
HL_SRC = sim_headless.cpp

all: $(EXE)

headless: $(HL_EXE)

# ---------------------------------------------------------------------------
# VHDL -> Verilog netlist
# ---------------------------------------------------------------------------
$(GEN_V): $(VHD_SRC) $(CONVERTED_V) Makefile
	@mkdir -p $(GEN) $(WORK)
	$(GHDL) -a --std=08 --workdir=$(WORK) -Wno-hide $(VHD_SRC)
	$(GHDL) synth --std=08 --workdir=$(WORK) --out=verilog $(VHD_TOP) > $@.tmp
	@if [ -n "$(CONVERTED)" ]; then python3 strip_modules.py $@.tmp $(CONVERTED); fi
	@mv $@.tmp $@

netlist: $(GEN_V)

# ---------------------------------------------------------------------------
# Headless: no SDL/ImGui, screenshots and state dumps. Used for regressions.
# ---------------------------------------------------------------------------
$(HL_EXE): $(V_SRC) $(HL_SRC) Makefile
	$V -cc $(V_OPT) -exe --Mdir ./$(HL_DIR) $(TOP) \
		-CFLAGS "-O2 -std=c++17" -LDFLAGS "-lz" $(V_SRC) $(HL_SRC)
	$(MAKE) -C $(HL_DIR) -f Vtop.mk

# ---------------------------------------------------------------------------
# Graphical: SDL2 + ImGui
# ---------------------------------------------------------------------------
$(EXE): $(V_SRC) $(C_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --trace --Mdir ./obj_dir \
		$(TOP) -CFLAGS "$(CXXFLAGS)" $(V_SRC) $(C_SRC)
	$(MAKE) -C obj_dir -f Vtop.mk

lint: $(GEN_V)
	$V --lint-only -Wall -Wno-DECLFILENAME -Wno-fatal $(TOP) $(V_SRC)

clean:
	rm -rf obj_dir $(HL_DIR) $(GEN) $(WORK)

.PHONY: all headless netlist lint clean
