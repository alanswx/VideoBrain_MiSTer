--------------------------------------------------------------------------------
-- VideoBrain buffered-bus decoder / read mux
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05, "Buffered Bus".
--
-- The UV201 does not see the CPU's full address space.  Its 13-bit graphics
-- pointer addresses an 8K bus containing only RES2, system RAM, and cartridge
-- ROM.  0800-0BFF is deliberately open during DMA because WACK is not asserted
-- for UV201 fetches; UV201 registers and the cartridge-mapped CPU window are
-- therefore not visible here.
--
-- This module intentionally owns NO storage.  It is only the address decoder
-- and data mux for the UV201 view of memories that will be shared with the CPU
-- side.  That avoids creating a second copy of RES2/RAM/cart merely to get the
-- fetcher started.  The eventual machine-level memory/cart modules provide the
-- three *_rdata inputs below.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY buffered_bus IS
  PORT (
    -- UV201 DMA address, BA0-BA12.
    bb_addr  : IN  unsigned(12 DOWNTO 0);
    bb_rdata : OUT uv8;

    -- RES2 backing store: buffered 0000-07FF -> physical RES2 byte 000-7FF.
    res2_sel   : OUT std_logic;
    res2_addr  : OUT unsigned(10 DOWNTO 0);
    res2_rdata : IN  uv8;

    -- System RAM backing store: buffered 0C00-0FFF -> RAM byte 000-3FF.
    ram_sel   : OUT std_logic;
    ram_addr  : OUT unsigned(9 DOWNTO 0);
    ram_rdata : IN  uv8;

    -- Cartridge graphics view: buffered 1000-1FFF -> cartridge byte 000-FFF.
    cart_sel   : OUT std_logic;
    cart_addr  : OUT unsigned(11 DOWNTO 0);
    cart_rdata : IN  uv8;

    -- High when the selected address is the deliberately unmapped
    -- 0800-0BFF region.  Kept as a debug tap because real hardware returns
    -- electrically undefined/open-bus data here.
    open_bus : OUT std_logic
    );
END ENTITY buffered_bus;

ARCHITECTURE rtl OF buffered_bus IS
  SIGNAL res2_sel_l : std_logic;
  SIGNAL ram_sel_l  : std_logic;
  SIGNAL cart_sel_l : std_logic;
BEGIN

  res2_sel_l <= '1' WHEN bb_addr >= to_unsigned(BBUS_RES2_LO, 13) AND
                           bb_addr <= to_unsigned(BBUS_RES2_HI, 13)
                ELSE '0';

  ram_sel_l <= '1' WHEN bb_addr >= to_unsigned(BBUS_RAM_LO, 13) AND
                          bb_addr <= to_unsigned(BBUS_RAM_HI, 13)
               ELSE '0';

  cart_sel_l <= '1' WHEN bb_addr >= to_unsigned(BBUS_CART_LO, 13) AND
                           bb_addr <= to_unsigned(BBUS_CART_HI, 13)
                ELSE '0';

  res2_addr <= resize(bb_addr - to_unsigned(BBUS_RES2_LO, 13), res2_addr'length);
  ram_addr  <= resize(bb_addr - to_unsigned(BBUS_RAM_LO, 13), ram_addr'length);
  cart_addr <= resize(bb_addr - to_unsigned(BBUS_CART_LO, 13), cart_addr'length);

  PROCESS (res2_sel_l, ram_sel_l, cart_sel_l,
           res2_rdata, ram_rdata, cart_rdata) IS
  BEGIN
    IF res2_sel_l = '1' THEN
      bb_rdata <= res2_rdata;
    ELSIF ram_sel_l = '1' THEN
      bb_rdata <= ram_rdata;
    ELSIF cart_sel_l = '1' THEN
      bb_rdata <= cart_rdata;
    ELSE
      -- Real hardware is genuinely open here.  0xFF is a deterministic
      -- simulation/FPGA placeholder; nothing should rely on this value.
      bb_rdata <= (OTHERS => '1');
    END IF;
  END PROCESS;

  res2_sel <= res2_sel_l;
  ram_sel  <= ram_sel_l;
  cart_sel <= cart_sel_l;
  open_bus <= NOT (res2_sel_l OR ram_sel_l OR cart_sel_l);

END ARCHITECTURE rtl;
