--------------------------------------------------------------------------------
-- VideoBrain UV202 - shared types and constants
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05
--            MAME src/mame/vidbrain/{vidbrain.cpp,uv201.cpp,uv201.h}
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

PACKAGE uv202_pack IS

  ----------------------------------------------------------------------------
  -- Clock relationships
  --
  -- MCLK    : 14.318181 MHz crystal on UV202 Xin/Xout (=NTSC colorburst x4)
  -- BRCLK   : MCLK / 4   = 3.579545 MHz  (also = COLCLK, feeds LM1889)
  -- CPUCLK  : externally generated 2.0 MHz (NOT derived from UV202's broken
  --           /7 output - see doc). We generate our own clean CPU enable
  --           and DO NOT reproduce the UV202 CPUCLK bug.
  --
  -- All internal UV202/UV201 timing in this core is expressed in BRCLK
  -- units, matching kevtris's cycle-count tables.
  ----------------------------------------------------------------------------

  CONSTANT MCLK_HZ  : natural := 14_318_181;
  CONSTANT BRCLK_DIV : natural := 4;   -- MCLK -> BRCLK

  ----------------------------------------------------------------------------
  -- Scanline timing (all units = BRCLK cycles, cycle 0 = HBLANK falling edge)
  ----------------------------------------------------------------------------

  CONSTANT BRCLKS_PER_LINE   : natural := 228;

  -- Normal scanline
  CONSTANT CSYNC_WIDTH_NORM  : natural := 18;   -- cycles 0-17
  CONSTANT BURST_START       : natural := 21;
  CONSTANT BURST_WIDTH       : natural := 9;    -- cycles 21-29
  CONSTANT HBLANK_END        : natural := 33;   -- HBLANK cycles 222-227,0-32 (39 total)
  CONSTANT HBLANK_START      : natural := 222;
  CONSTANT VISAREA_WIDTH     : natural := 189;  -- 228 - 39

  -- Equalization-pulse scanlines (vblank region)
  CONSTANT EQ_PULSE_WIDTH    : natural := 9;    -- cycles 0-8 and 114-122
  CONSTANT EQ_PULSE2_START   : natural := 114;

  -- Vsync scanlines (vblank region) - CSYNC high most of line, low pulses:
  CONSTANT VSYNC_PULSE_WIDTH : natural := 18;   -- cycles 105-113 and 219-227
  CONSTANT VSYNC_PULSE1_START: natural := 105;
  CONSTANT VSYNC_PULSE2_START: natural := 219;

  -- Field structure (see doc "Frame timing")
  --   odd  field: 263 lines = 3 vsync + 3 eq + 244 normal + 2.5 eq
  --   even field: 262 lines = 3 vsync + 3 eq + 243.5 normal + 3 eq
  CONSTANT LINES_ODD_FIELD   : natural := 263;
  CONSTANT LINES_EVEN_FIELD  : natural := 262;
  CONSTANT VSYNC_LINES       : natural := 3;
  CONSTANT EQ_LINES_PRE      : natural := 3;    -- eq lines immediately after vsync

  ----------------------------------------------------------------------------
  -- CPU-side address map (see doc "Address Space" / MAME vidbrain_mem)
  -- All ranges below 0x4000; CPU only drives 14 address bits (BA0-BA13 seen
  -- externally as A0-A13), so 4000-FFFF mirror 0000-3FFF three more times.
  ----------------------------------------------------------------------------

  CONSTANT ADDR_RES1_LO   : natural := 16#0000#;  -- RES1 ROM, 2K, 0 wait
  CONSTANT ADDR_RES1_HI   : natural := 16#07FF#;

  -- UV201 regs, 6-10 BRCLK wait. The 256-byte page is mirrored four times
  -- across 0800-0BFF: A8 and A9 are undecoded, and UV202 pin 37 is named
  -- /800-BFF. Register selection is a_eff(7 DOWNTO 0).
  CONSTANT ADDR_UV201_LO  : natural := 16#0800#;
  CONSTANT ADDR_UV201_HI  : natural := 16#0BFF#;

  CONSTANT ADDR_RAM_LO    : natural := 16#0C00#;  -- system RAM, 1K (8x 2102), 4-6 BRCLK
  CONSTANT ADDR_RAM_HI    : natural := 16#0FFF#;

  CONSTANT ADDR_CART2_LO  : natural := 16#1000#;  -- cartridge ROM, 4-6 BRCLK
  CONSTANT ADDR_CART2_HI  : natural := 16#1FFF#;

  CONSTANT ADDR_RES2_LO   : natural := 16#2000#;  -- RES2 ROM, 2K
  CONSTANT ADDR_RES2_HI   : natural := 16#27FF#;

  -- 2800-3FFF mirror 0800-1FFF (ASIC/cart/RAM/cart mirror)

  ----------------------------------------------------------------------------
  -- Buffered-bus address map (what the UV201 actually sees during DMA,
  -- 8K deep, BA0-BA12 only - BA13 exists but only routes to cartridge conn.)
  ----------------------------------------------------------------------------

  CONSTANT BBUS_RES2_LO   : natural := 16#0000#;  -- RES2 ROM mirror, 2K
  CONSTANT BBUS_RES2_HI   : natural := 16#07FF#;
  -- 0800-0BFF open bus (UV201 regs / cart-mapped are NOT visible here -
  --   WACK does not assert during DMA, see doc)
  CONSTANT BBUS_RAM_LO    : natural := 16#0C00#;  -- system RAM, 1K
  CONSTANT BBUS_RAM_HI    : natural := 16#0FFF#;
  CONSTANT BBUS_CART_LO   : natural := 16#1000#;  -- cartridge ROM, 4K
  CONSTANT BBUS_CART_HI   : natural := 16#1FFF#;

  ----------------------------------------------------------------------------
  -- UV201 register offsets (0x00-0x8F = object RAM, 0xF0-0xFB = ctl/status)
  -- Confirmed against MAME src/mame/vidbrain/uv201.cpp
  ----------------------------------------------------------------------------

  CONSTANT REG_RP_LO         : natural := 16#00#;  -- 00-0F pointer LSB
  CONSTANT REG_RP_HI_COLOR   : natural := 16#10#;  -- 10-1F pointer MSB + color
  CONSTANT REG_DX_INT_XCOPY  : natural := 16#20#;  -- 20-2F width/intensity/xcopy
  CONSTANT REG_DY            : natural := 16#30#;  -- 30-3F height
  CONSTANT REG_X             : natural := 16#40#;  -- 40-4F X position
  CONSTANT REG_Y_LO_A        : natural := 16#50#;  -- 50-5F Y LSB, list A
  CONSTANT REG_Y_LO_B        : natural := 16#60#;  -- 60-6F Y LSB, list B
  CONSTANT REG_XY_HI_A       : natural := 16#70#;  -- 70-7F Y MSB + Xorder, list A
  CONSTANT REG_XY_HI_B       : natural := 16#80#;  -- 80-8F Y MSB + Xorder, list B

  CONSTANT REG_Y_INTERRUPT   : natural := 16#F0#;  -- write only
  CONSTANT REG_FINAL_MOD     : natural := 16#F2#;  -- write only
  CONSTANT REG_BACKGROUND    : natural := 16#F5#;  -- write only
  CONSTANT REG_COMMAND       : natural := 16#F7#;  -- write only

  CONSTANT REG_X_FREEZE      : natural := 16#F8#;  -- read only
  CONSTANT REG_Y_FREEZE_LO   : natural := 16#F9#;  -- read only
  CONSTANT REG_Y_FREEZE_HI   : natural := 16#FA#;  -- read only
  CONSTANT REG_CURRENT_Y_LO  : natural := 16#FB#;  -- read only

  -- command register bits (0xF7)
  CONSTANT CMD_X_ZM      : natural := 0;  -- X zoom (double width)
  CONSTANT CMD_FRZ       : natural := 1;  -- freeze X/Y on ext int
  CONSTANT CMD_ENB       : natural := 2;  -- video enable
  CONSTANT CMD_INT       : natural := 3;  -- Y-interrupt enable
  CONSTANT CMD_KBD       : natural := 4;  -- keypad column 8 select (general output)
  CONSTANT CMD_Y_ZM      : natural := 5;  -- Y zoom (double height)
  CONSTANT CMD_A_B       : natural := 6;  -- object list select, 1=A 0=B
  CONSTANT CMD_YINT_HO   : natural := 7;  -- Y-interrupt register high order bit

  ----------------------------------------------------------------------------
  -- Wait-state arbiter types
  --
  -- Access classes per the truth table in "Wait States" section of the doc:
  --   UMIREQ0  CPUREQ0  CPUREQ1  /800-BFF
  -- UV201 Wr      x        1        0         0
  -- RAM   Wr      x        1        0         1
  -- UV201 Rd      x        0        1         0
  -- RAM   Rd      x        1        1         1
  -- Cart  Rd      x        1        1         1
  -- DMA   Rd      1        0        0         0
  ----------------------------------------------------------------------------

  TYPE bus_access_t IS (
    ACC_NONE,        -- idle, AND: RES1 (0000-07FF) specifically - the doc
                      -- lists RES1 as the one genuinely 0-wait CPU region,
                      -- so it is the only region that legitimately bypasses
                      -- uv202_arbiter's wait-stating path entirely.
    ACC_UV201_RD,
    ACC_UV201_WR,
    ACC_RAM_RD,
    ACC_RAM_WR,
    ACC_CART_RD,
    ACC_CART_WR,
    ACC_RES2,         -- RES2 timing class; same arbiter body as RAM/cart
    ACC_DMA0_RD,      -- primary UV201 DMA fetch
    ACC_DMA1_RD       -- secondary UV201 DMA fetch
  );

  ----------------------------------------------------------------------------
  -- CPU address mirror fold: 2800-3FFF mirrors 0800-1FFF exactly (see doc
  -- "Address Space"). This is shared between f8_busif.classify() (decides
  -- the wait class) and sys_bus (decides which physical device answers the
  -- access) so the two can't drift out of sync with each other. RES2
  -- (2000-27FF) is NOT a mirror target of anything else in 0000-3FFF, so it
  -- is left untouched by this fold.
  ----------------------------------------------------------------------------

  FUNCTION cpu_addr_fold(a : unsigned(13 DOWNTO 0)) RETURN unsigned;

  -- Base wait components in BRCLKs. ST_SETUP is the setup penalty;
  -- WAIT_CPU_RDWR and WAIT_DMA_BODY are body lengths.
  CONSTANT WAIT_SETUP_PENALTY   : natural := 1;  -- 1 BRCLK setup before any access
  CONSTANT WAIT_CPU_RDWR        : natural := 3;  -- plain RAM/cart access body
  CONSTANT WAIT_DMA_BODY        : natural := 3;  -- one DMA fetch body

  TYPE arr_uv8 IS ARRAY (natural RANGE <>) OF uv8;

END PACKAGE uv202_pack;

PACKAGE BODY uv202_pack IS

  FUNCTION cpu_addr_fold(a : unsigned(13 DOWNTO 0)) RETURN unsigned IS
  BEGIN
    IF a >= to_unsigned(16#2800#, 14) THEN
      RETURN a - to_unsigned(16#2000#, 14);
    ELSE
      RETURN a;
    END IF;
  END FUNCTION;

END PACKAGE BODY uv202_pack;
