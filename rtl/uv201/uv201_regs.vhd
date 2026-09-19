--------------------------------------------------------------------------------
-- VideoBrain UV201 register file
-- UV201 object RAM, control registers, status reads, and freeze capture.
-- Reference: docs/uv201.cpp and docs/videobrain_unwrapped.txt.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv201_regs IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    -- CPU register access. reg_addr is the 0x00-0xFF UV201 offset.
    reg_addr  : IN  uv8;
    reg_we    : IN  std_logic;
    reg_wdata : IN  uv8;
    reg_rdata : OUT uv8;

    -- Live raster position for status reads and freeze capture.
    cur_field : IN  std_logic;             -- 0=odd, 1=even (uv202_timing.field)
    cur_vpos  : IN  unsigned(8 DOWNTO 0);  -- uv202_timing.vpos

    -- Falling EXT INT capture while FRZ is set.
    capture_stb : IN  std_logic;
    capture_x   : IN  uv8;

    -- Decoded command register outputs. o_ avoids clashes with CMD_* constants.
    o_x_zm  : OUT std_logic;  -- X zoom (double width)
    o_frz   : OUT std_logic;  -- freeze enable
    o_enb   : OUT std_logic;  -- video enable
    o_int   : OUT std_logic;  -- Y-interrupt enable
    o_kbd   : OUT std_logic;  -- keypad column 8 select / general output
    o_y_zm  : OUT std_logic;  -- Y zoom (double height)
    o_a_b   : OUT std_logic;  -- object list select, 1=A 0=B

    y_int     : OUT uv8;      -- raw Y-interrupt register (low 8 bits)
    o_yint_ho : OUT std_logic;-- Y-interrupt register high order bit (cmd bit 7)

    -- Renderer controls.
    final_mod  : OUT uv8;
    background : OUT uv8;

    -- Independent combinational object-RAM read port for the fetcher.
    obj_addr  : IN  uv8;
    obj_rdata : OUT uv8
    );
END ENTITY uv201_regs;

ARCHITECTURE rtl OF uv201_regs IS

  -- object RAM: 0x00-0x8F (9 banks x 16 objects, per uv202_pack REG_* map)
  TYPE obj_ram_t IS ARRAY (0 TO 16#8F#) OF uv8;
  SIGNAL obj_ram : obj_ram_t := (OTHERS => (OTHERS => '0'));

  -- write-only control registers
  SIGNAL r_y_int : uv8 := (OTHERS => '0');
  SIGNAL r_fmod  : uv8 := (OTHERS => '0');
  SIGNAL r_bg    : uv8 := (OTHERS => '0');
  SIGNAL r_cmd   : uv8 := (OTHERS => '0');

  -- read-only status registers (written only by the freeze-capture event,
  -- never directly by the CPU - matches MAME, which has no CPU-write case
  -- for REGISTER_X_FREEZE/Y_FREEZE_LOW/Y_FREEZE_HIGH/CURRENT_Y_LOW)
  SIGNAL r_freeze_x : uv8 := (OTHERS => '0');
  SIGNAL r_freeze_y : unsigned(8 DOWNTO 0) := (OTHERS => '0');

  CONSTANT CMD_X_ZM_BIT    : natural := CMD_X_ZM;
  CONSTANT CMD_FRZ_BIT     : natural := CMD_FRZ;
  CONSTANT CMD_ENB_BIT     : natural := CMD_ENB;
  CONSTANT CMD_INT_BIT     : natural := CMD_INT;
  CONSTANT CMD_KBD_BIT     : natural := CMD_KBD;
  CONSTANT CMD_Y_ZM_BIT    : natural := CMD_Y_ZM;
  CONSTANT CMD_A_B_BIT     : natural := CMD_A_B;
  CONSTANT CMD_YINT_HO_BIT : natural := CMD_YINT_HO;

BEGIN

  ------------------------------------------------------------------------
  -- writes + freeze capture
  ------------------------------------------------------------------------
  PROCESS (clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      r_y_int    <= (OTHERS => '0');
      r_fmod     <= (OTHERS => '0');
      r_bg       <= (OTHERS => '0');
      r_cmd      <= (OTHERS => '0');
      r_freeze_x <= (OTHERS => '0');
      r_freeze_y <= (OTHERS => '0');
      obj_ram    <= (OTHERS => (OTHERS => '0'));

    ELSIF rising_edge(clk) THEN

      IF reg_we = '1' THEN
        IF unsigned(reg_addr) = to_unsigned(REG_Y_INTERRUPT, 8) THEN
          r_y_int <= reg_wdata;
        ELSIF unsigned(reg_addr) = to_unsigned(REG_FINAL_MOD, 8) THEN
          r_fmod <= "000" & reg_wdata(4 DOWNTO 0);
        ELSIF unsigned(reg_addr) = to_unsigned(REG_BACKGROUND, 8) THEN
          r_bg <= "000" & reg_wdata(4 DOWNTO 0);
        ELSIF unsigned(reg_addr) = to_unsigned(REG_COMMAND, 8) THEN
          r_cmd <= reg_wdata;
        ELSIF unsigned(reg_addr) <= to_unsigned(16#8F#, 8) THEN
          -- object RAM (0x00-0x8F): writable. Everything else in
          -- 0x90-0xEF is unmapped (open bus, MAME logs and ignores);
          -- 0xF8-0xFB are read-only status regs and CPU writes to them
          -- are silently dropped, matching MAME (no write case exists
          -- for them there either).
          obj_ram(to_integer(unsigned(reg_addr))) <= reg_wdata;
        END IF;
      END IF;

      -- freeze capture: doc / MAME ext_int_w() - falling EXT INT edge while
      -- FRZ is set latches current X (from caller, since X position lives
      -- in the renderer's per-scanline counter, not here) and current Y.
      IF capture_stb = '1' AND r_cmd(CMD_FRZ_BIT) = '1' THEN
        r_freeze_x <= capture_x;
        r_freeze_y <= cur_vpos;
      END IF;

    END IF;
  END PROCESS;

  ------------------------------------------------------------------------
  -- reads (combinational)
  ------------------------------------------------------------------------
  PROCESS (reg_addr, r_freeze_x, r_freeze_y, cur_field, cur_vpos, obj_ram) IS
  BEGIN
    IF unsigned(reg_addr) = to_unsigned(REG_X_FREEZE, 8) THEN
      reg_rdata <= r_freeze_x;

    ELSIF unsigned(reg_addr) = to_unsigned(REG_Y_FREEZE_LO, 8) THEN
      reg_rdata <= r_freeze_y(7 DOWNTO 0);

    ELSIF unsigned(reg_addr) = to_unsigned(REG_Y_FREEZE_HI, 8) THEN
      -- bit 7: odd/even field: bit 1: current-Y counter MSB: bit 0:
      -- Y-freeze MSB. Matches MAME's REGISTER_Y_FREEZE_HIGH packing.
      reg_rdata <= cur_field & unsigned'("00000") & cur_vpos(8) & r_freeze_y(8);

    ELSIF unsigned(reg_addr) = to_unsigned(REG_CURRENT_Y_LO, 8) THEN
      reg_rdata <= cur_vpos(7 DOWNTO 0);

    ELSIF unsigned(reg_addr) <= to_unsigned(16#8F#, 8) THEN
      reg_rdata <= obj_ram(to_integer(unsigned(reg_addr)));

    ELSE
      reg_rdata <= (OTHERS => '1');  -- open bus, matches MAME default 0xff
    END IF;
  END PROCESS;

  obj_rdata <= obj_ram(to_integer(unsigned(obj_addr)))
                 WHEN unsigned(obj_addr) <= to_unsigned(16#8F#, 8)
                 ELSE (OTHERS => '1');

  ------------------------------------------------------------------------
  -- command register bit taps
  ------------------------------------------------------------------------
  o_x_zm    <= r_cmd(CMD_X_ZM_BIT);
  o_frz     <= r_cmd(CMD_FRZ_BIT);
  o_enb     <= r_cmd(CMD_ENB_BIT);
  o_int     <= r_cmd(CMD_INT_BIT);
  o_kbd     <= r_cmd(CMD_KBD_BIT);
  o_y_zm    <= r_cmd(CMD_Y_ZM_BIT);
  o_a_b     <= r_cmd(CMD_A_B_BIT);
  o_yint_ho <= r_cmd(CMD_YINT_HO_BIT);
  y_int     <= r_y_int;
  final_mod <= r_fmod;
  background <= r_bg;

END ARCHITECTURE rtl;
