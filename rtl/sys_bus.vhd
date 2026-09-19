--------------------------------------------------------------------------------
-- VideoBrain unified CPU and buffered memory bus
-- CPU map: RES1, UV201, cartridge windows, 1K RAM, RES2.
-- Buffered bus shares RES2/RAM storage with the CPU side.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY sys_bus IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    -- f8_busif side (see f8_busif.vhd ext_* ports)
    ext_addr  : IN  unsigned(13 DOWNTO 0);
    ext_rd    : IN  std_logic;
    ext_wr    : IN  std_logic;
    ext_wdata : IN  uv8;
    ext_rdata : OUT uv8;

    -- UV201 buffered-bus read view.  This shares the same RES2/RAM backing
    -- arrays as the CPU side; buffered_bus.vhd supplies the narrower 8K
    -- decode.  Cartridge data remains a stub until the slot module exists.
    bb_addr  : IN  unsigned(12 DOWNTO 0);
    bb_rdata : OUT uv8;

    -- UV201 status-register inputs, passed straight through to
    -- uv201_regs.vhd (see that entity for why these exist)
    uv_cur_field   : IN std_logic;
    uv_cur_vpos    : IN unsigned(8 DOWNTO 0);
    uv_capture_stb : IN std_logic;
    uv_capture_x   : IN uv8;

    -- UV201 controls and object-RAM fetch port.
    uv_o_x_zm   : OUT std_logic;
    uv_o_frz    : OUT std_logic;
    uv_o_enb    : OUT std_logic;
    uv_o_int    : OUT std_logic;
    uv_o_kbd    : OUT std_logic;
    uv_o_y_zm   : OUT std_logic;
    uv_o_a_b    : OUT std_logic;
    uv_o_yint_ho: OUT std_logic;
    uv_y_int    : OUT uv8;
    uv_final_mod : OUT uv8;
    uv_background: OUT uv8;

    uv_obj_addr  : IN  uv8;
    uv_obj_rdata : OUT uv8;

    -- HPS download port.  dl_index selects the target image:
    -- 0 = RES1, 1 = RES2, 2 = cartridge.  Writes are ignored otherwise.
    dl_addr  : IN unsigned(15 DOWNTO 0);
    dl_data  : IN uv8;
    dl_wr    : IN std_logic;
    dl_index : IN uv8
    );
END ENTITY sys_bus;

ARCHITECTURE rtl OF sys_bus IS

  SIGNAL a_eff : unsigned(13 DOWNTO 0);

  -- RES1: 0000-07FF (2K), zero-wait, not gated by ext_rd/ext_wr - always
  -- driven from address, matching the "RES1 doesn't route through the
  -- arbiter" decision in f8_busif.classify().
  TYPE rom_t IS ARRAY (0 TO 2047) OF uv8;
  SIGNAL res1_rom : rom_t := (OTHERS => (OTHERS => '0'));
  SIGNAL res2_rom : rom_t := (OTHERS => (OTHERS => '0'));

  -- cartridge ROM: 1000-1FFF (4K).  The 0900-0BFF cart-mapped window stays
  -- open bus; it addresses cart-supplied hardware, not this array.
  TYPE cart_t IS ARRAY (0 TO 4095) OF uv8;
  SIGNAL cart_rom : cart_t := (OTHERS => (OTHERS => '0'));

  -- system RAM: 0C00-0FFF (1K)
  TYPE ram_t IS ARRAY (0 TO 1023) OF uv8;
  SIGNAL sys_ram : ram_t := (OTHERS => (OTHERS => '0'));

  SIGNAL uv_reg_addr  : uv8;
  SIGNAL uv_reg_we    : std_logic;
  SIGNAL uv_reg_wdata : uv8;
  SIGNAL uv_reg_rdata : uv8;

  SIGNAL rdata_l : uv8;

  SIGNAL bb_res2_sel   : std_logic;
  SIGNAL bb_res2_addr  : unsigned(10 DOWNTO 0);
  SIGNAL bb_res2_rdata : uv8;
  SIGNAL bb_ram_sel    : std_logic;
  SIGNAL bb_ram_addr   : unsigned(9 DOWNTO 0);
  SIGNAL bb_ram_rdata  : uv8;
  SIGNAL bb_cart_sel   : std_logic;
  SIGNAL bb_cart_addr  : unsigned(11 DOWNTO 0);
  SIGNAL bb_cart_rdata : uv8;
  SIGNAL bb_open_bus   : std_logic;

  SIGNAL dl_res1, dl_res2, dl_cart : std_logic;

BEGIN

  a_eff <= cpu_addr_fold(ext_addr);

  ----------------------------------------------------------------------------
  -- UV201 register file instance
  ----------------------------------------------------------------------------

  u_uv201_regs : ENTITY work.uv201_regs
    PORT MAP (
      clk         => clk,
      reset_na    => reset_na,
      reg_addr    => uv_reg_addr,
      reg_we      => uv_reg_we,
      reg_wdata   => uv_reg_wdata,
      reg_rdata   => uv_reg_rdata,
      cur_field   => uv_cur_field,
      cur_vpos    => uv_cur_vpos,
      capture_stb => uv_capture_stb,
      capture_x   => uv_capture_x,
      o_x_zm      => uv_o_x_zm,
      o_frz       => uv_o_frz,
      o_enb       => uv_o_enb,
      o_int       => uv_o_int,
      o_kbd       => uv_o_kbd,
      o_y_zm      => uv_o_y_zm,
      o_a_b       => uv_o_a_b,
      o_yint_ho   => uv_o_yint_ho,
      y_int       => uv_y_int,
      final_mod   => uv_final_mod,
      background  => uv_background,
      obj_addr    => uv_obj_addr,
      obj_rdata   => uv_obj_rdata
      );

  uv_reg_addr  <= a_eff(7 DOWNTO 0);
  uv_reg_we    <= ext_wr WHEN (a_eff >= to_unsigned(ADDR_UV201_LO, 14) AND
                                a_eff <= to_unsigned(ADDR_UV201_HI, 14))
                  ELSE '0';
  uv_reg_wdata <= ext_wdata;

  ----------------------------------------------------------------------------
  -- RAM write. Read is combinational.
  ----------------------------------------------------------------------------

  PROCESS (clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      NULL;  -- RAM contents undefined on real hardware after reset too
              -- (see doc: signature-byte-guarded clear routine runs at
              -- boot); not resetting the array avoids a large synth-time
              -- reset fan-out for no behavioral benefit.
    ELSIF rising_edge(clk) THEN
      IF ext_wr = '1' AND a_eff >= to_unsigned(ADDR_RAM_LO, 14)
                       AND a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
        sys_ram(to_integer(a_eff - to_unsigned(ADDR_RAM_LO, 14))) <= ext_wdata;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- read mux (combinational)
  ----------------------------------------------------------------------------

  PROCESS (a_eff, res1_rom, res2_rom, cart_rom, sys_ram, uv_reg_rdata) IS
  BEGIN
    IF a_eff <= to_unsigned(ADDR_RES1_HI, 14) THEN
      rdata_l <= res1_rom(to_integer(a_eff));

    ELSIF a_eff <= to_unsigned(ADDR_UV201_HI, 14) THEN
      rdata_l <= uv_reg_rdata;

    ELSIF a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
      rdata_l <= sys_ram(to_integer(a_eff - to_unsigned(ADDR_RAM_LO, 14)));

    ELSIF a_eff <= to_unsigned(ADDR_CART2_HI, 14) THEN
      rdata_l <= cart_rom(to_integer(a_eff - to_unsigned(ADDR_CART2_LO, 14)));

    ELSIF a_eff <= to_unsigned(ADDR_RES2_HI, 14) THEN
      rdata_l <= res2_rom(to_integer(a_eff - to_unsigned(ADDR_RES2_LO, 14)));

    ELSE
      rdata_l <= (OTHERS => '1');  -- unreachable after mirror fold
    END IF;
  END PROCESS;

  ext_rdata <= rdata_l;

  ----------------------------------------------------------------------------
  -- Image download.  Held outside the RAM write process so a download cannot
  -- race a CPU store to the same array.
  ----------------------------------------------------------------------------

  -- One process per array: a single process selecting between them defeats
  -- GHDL's RAM inference and the netlist balloons into unrolled muxes.
  dl_res1 <= dl_wr WHEN dl_index = to_unsigned(0, 8) ELSE '0';
  dl_res2 <= dl_wr WHEN dl_index = to_unsigned(1, 8) ELSE '0';
  dl_cart <= dl_wr WHEN dl_index = to_unsigned(2, 8) ELSE '0';

  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF dl_res1 = '1' THEN
        res1_rom(to_integer(dl_addr(10 DOWNTO 0))) <= dl_data;
      END IF;
    END IF;
  END PROCESS;

  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF dl_res2 = '1' THEN
        res2_rom(to_integer(dl_addr(10 DOWNTO 0))) <= dl_data;
      END IF;
    END IF;
  END PROCESS;

  PROCESS (clk) IS
  BEGIN
    IF rising_edge(clk) THEN
      IF dl_cart = '1' THEN
        cart_rom(to_integer(dl_addr(11 DOWNTO 0))) <= dl_data;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- UV201 buffered-bus view.  RES2 and system RAM are the SAME arrays used
  -- above; this is the architectural point of keeping buffered_bus as a
  -- decoder/mux rather than giving it its own memories.
  ----------------------------------------------------------------------------

  u_buffered_bus : ENTITY work.buffered_bus
    PORT MAP (
      bb_addr     => bb_addr,
      bb_rdata    => bb_rdata,
      res2_sel    => bb_res2_sel,
      res2_addr   => bb_res2_addr,
      res2_rdata  => bb_res2_rdata,
      ram_sel     => bb_ram_sel,
      ram_addr    => bb_ram_addr,
      ram_rdata   => bb_ram_rdata,
      cart_sel    => bb_cart_sel,
      cart_addr   => bb_cart_addr,
      cart_rdata  => bb_cart_rdata,
      open_bus    => bb_open_bus
      );

  bb_res2_rdata <= res2_rom(to_integer(bb_res2_addr));
  bb_ram_rdata  <= sys_ram(to_integer(bb_ram_addr));
  bb_cart_rdata <= cart_rom(to_integer(bb_cart_addr));

END ARCHITECTURE rtl;
