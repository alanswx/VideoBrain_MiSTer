--------------------------------------------------------------------------------
-- VideoBrain UV201 - Y interrupt comparator (MVP)
--------------------------------------------------------------------------------
-- The Y interrupt register supplies the low 8 bits of a 9-bit target and
-- command bit YINT_HO supplies bit 8.  When INT is enabled, matching the
-- target scanline produces an external-interrupt pulse to the F3853/SMI.
--
-- This is intentionally kept separate from uv201_regs.  It makes the timing
-- assumption visible and easy to replace if hardware evidence later shows the
-- compare point differs.  For MVP the compare is sampled at hblank_falling,
-- i.e. the project's BRCLK cycle-0 / start-of-scanline convention.
--
-- MAME suppresses its Y interrupt while FRZ is set; we retain that behavior
-- here.  Exact odd/even-field behavior remains to be verified against hardware,
-- so no field qualification is imposed yet.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

ENTITY uv201_yint IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    brclk_ena      : IN std_logic;
    hblank_falling : IN std_logic;
    cur_vpos       : IN unsigned(8 DOWNTO 0);

    y_int     : IN uv8;
    yint_ho   : IN std_logic;
    cmd_int   : IN std_logic;
    cmd_frz   : IN std_logic;

    irq_pulse : OUT std_logic
    );
END ENTITY uv201_yint;

ARCHITECTURE rtl OF uv201_yint IS
  SIGNAL irq_l : std_logic := '0';
BEGIN

  PROCESS (clk, reset_na) IS
    VARIABLE target_y : unsigned(8 DOWNTO 0);
  BEGIN
    IF reset_na = '0' THEN
      irq_l <= '0';

    ELSIF rising_edge(clk) THEN
      irq_l <= '0';

      -- hblank_falling is a one-clk pulse raised on the clk after the BRCLK
      -- edge, so it must not be qualified with brclk_ena as well.
      IF hblank_falling = '1' THEN
        target_y := unsigned(yint_ho & y_int);

        IF cmd_int = '1' AND cmd_frz = '0' AND cur_vpos = target_y THEN
          irq_l <= '1';
        END IF;
      END IF;
    END IF;
  END PROCESS;

  irq_pulse <= irq_l;

END ARCHITECTURE rtl;
