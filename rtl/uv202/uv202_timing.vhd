--------------------------------------------------------------------------------
-- VideoBrain UV202 timing generator
-- 228 BRCLK per line, 263/262-line alternating fields.
-- HBLANK/FIFO edge timing follows docs/videobrain_unwrapped.txt.
-- TODO: verify the exact equalization/vsync half-line seam on hardware.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv202_timing IS
  PORT (
    clk        : IN  std_logic;
    reset_na   : IN  std_logic;
    brclk_ena  : IN  std_logic;   -- from uv202_clkgen

    -- chip-level outputs (match UV202 pin semantics)
    hblank     : OUT std_logic;   -- pin 17, high during hblank
    vblank     : OUT std_logic;   -- pin 18, high for 21 lines/field
    burst      : OUT std_logic;   -- pin 19
    csync      : OUT std_logic;   -- pin 20, composite sync (active high pulses)
    scanline   : OUT std_logic;   -- pin 23, toggles at start of each line (debug)
    field      : OUT std_logic;   -- pin 24, 0=odd 1=even

    -- internal timing taps for uv202_arbiter / uv201_fetcher
    hpos       : OUT unsigned(7 DOWNTO 0);  -- 0-227, cycle within line
    vpos       : OUT unsigned(8 DOWNTO 0);  -- 0-262, line within field
    -- 1-cycle pulse at hpos 0, i.e. the start of the HBLANK tail. vpos has
    -- already advanced, so this is the point to begin fetching the next line:
    -- it leaves the whole 33-cycle tail to fill the FIFO before active video.
    line_start     : OUT std_logic;

    hblank_falling : OUT std_logic;   -- 1-cycle pulse, = "cycle 0" per doc convention
    hblank_rising  : OUT std_logic    -- 1-cycle pulse, FIFO-clear trigger for uv201
    );
END ENTITY uv202_timing;

ARCHITECTURE rtl OF uv202_timing IS

  SIGNAL hpos_l    : unsigned(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL vpos_l     : unsigned(8 DOWNTO 0) := (OTHERS => '0');
  SIGNAL field_l    : std_logic := '0';         -- 0=odd(263 lines), 1=even(262 lines)

  SIGNAL hblank_l   : std_logic := '1';
  SIGNAL vblank_l   : std_logic := '1';
  SIGNAL burst_l    : std_logic := '0';
  SIGNAL csync_l    : std_logic := '0';
  SIGNAL scanline_l : std_logic := '0';

  SIGNAL line_start_l  : std_logic := '0';
  SIGNAL hblank_fall_l : std_logic := '0';
  SIGNAL hblank_rise_l : std_logic := '0';

  -- lines_this_field: 263 for odd, 262 for even
  SIGNAL lines_this_field : unsigned(8 DOWNTO 0);

  -- VBLANK is high for the first 21 lines of each field.
  CONSTANT VBLANK_LINES : natural := 21;

  -- Whole-line approximation for CSYNC classification. The half-line seam
  -- remains a hardware-validation item; HBLANK and field lengths are separate.
  CONSTANT NORMAL_LINES_ODD  : natural := 244;
  CONSTANT NORMAL_LINES_EVEN : natural := 243;

  -- classification of the current line's CSYNC pulse shape
  TYPE line_kind_t IS (LK_VSYNC, LK_EQ, LK_NORMAL);
  SIGNAL line_kind : line_kind_t;

BEGIN

  lines_this_field <= to_unsigned(LINES_ODD_FIELD, 9) WHEN field_l = '0' ELSE
                       to_unsigned(LINES_EVEN_FIELD, 9);

  PROCESS(vpos_l, field_l, lines_this_field)
    VARIABLE post_eq_start : unsigned(8 DOWNTO 0);
  BEGIN
    IF vpos_l < to_unsigned(VSYNC_LINES, 9) THEN
      line_kind <= LK_VSYNC;
    ELSIF vpos_l < to_unsigned(VSYNC_LINES + EQ_LINES_PRE, 9) THEN
      line_kind <= LK_EQ;
    ELSE
      IF field_l = '0' THEN
        post_eq_start := to_unsigned(VSYNC_LINES + EQ_LINES_PRE + NORMAL_LINES_ODD, 9);
      ELSE
        post_eq_start := to_unsigned(VSYNC_LINES + EQ_LINES_PRE + NORMAL_LINES_EVEN, 9);
      END IF;

      IF vpos_l < post_eq_start THEN
        line_kind <= LK_NORMAL;
      ELSE
        line_kind <= LK_EQ;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Main BRCLK-synchronous counter + output generation
  ----------------------------------------------------------------------------

  PROCESS(clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      hpos_l    <= (OTHERS => '0');
      vpos_l    <= (OTHERS => '0');
      field_l   <= '0';
      hblank_l  <= '1';
      vblank_l  <= '1';
      burst_l   <= '0';
      csync_l   <= '0';
      scanline_l <= '0';
      hblank_fall_l <= '0';
      hblank_rise_l <= '0';

    ELSIF rising_edge(clk) THEN
      hblank_fall_l <= '0';
      hblank_rise_l <= '0';
      line_start_l  <= '0';

      IF brclk_ena = '1' THEN

        -- horizontal position advance / line rollover
        IF hpos_l = BRCLKS_PER_LINE-1 THEN
          hpos_l <= (OTHERS => '0');
          line_start_l <= '1';
          scanline_l <= NOT scanline_l;

          IF vpos_l = lines_this_field-1 THEN
            vpos_l  <= (OTHERS => '0');
            field_l <= NOT field_l;
          ELSE
            vpos_l <= vpos_l + 1;
          END IF;
        ELSE
          hpos_l <= hpos_l + 1;
        END IF;

        -- HBLANK is high at output hpos 222..227 and 0..32.
        -- Compare the current count against the cycle before each edge so the
        -- registered flag and hpos advance together.
        IF hpos_l = to_unsigned(HBLANK_START - 1, 8) THEN
          hblank_l <= '1';
          hblank_rise_l <= '1';
        ELSIF hpos_l = to_unsigned(HBLANK_END - 1, 8) THEN
          hblank_l <= '0';
          hblank_fall_l <= '1';
        END IF;

        -- BURST: high cycles BURST_START..BURST_START+BURST_WIDTH-1,
        -- except during the first 9 lines where VBLANK is high (per doc:
        -- "except the first 9 scanlines VBLANK is high" - i.e. vsync+eq)
        IF hpos_l >= to_unsigned(BURST_START, 8) AND
           hpos_l <  to_unsigned(BURST_START + BURST_WIDTH, 8) THEN
          burst_l <= NOT vblank_l;
        ELSE
          burst_l <= '0';
        END IF;

        -- VBLANK: high for first VBLANK_LINES lines of the field
        IF vpos_l < to_unsigned(VBLANK_LINES, 9) THEN
          vblank_l <= '1';
        ELSE
          vblank_l <= '0';
        END IF;

        -- CSYNC: pulse pattern depends on line_kind
        CASE line_kind IS
          WHEN LK_NORMAL =>
            csync_l <= to_std_logic(hpos_l < to_unsigned(CSYNC_WIDTH_NORM, 8));

          WHEN LK_EQ =>
            csync_l <= to_std_logic(
                         hpos_l < to_unsigned(EQ_PULSE_WIDTH, 8)
                       ) OR
                       to_std_logic(
                         hpos_l >= to_unsigned(EQ_PULSE2_START, 8) AND
                         hpos_l <  to_unsigned(EQ_PULSE2_START + EQ_PULSE_WIDTH, 8)
                       );

          WHEN LK_VSYNC =>
            -- CSYNC high for the majority of the line, low (inverted)
            -- pulses of VSYNC_PULSE_WIDTH at the two pulse start points
            csync_l <= NOT (
                         to_std_logic(
                           hpos_l >= to_unsigned(VSYNC_PULSE1_START, 8) AND
                           hpos_l <  to_unsigned(VSYNC_PULSE1_START + VSYNC_PULSE_WIDTH, 8)
                         ) OR
                         to_std_logic(
                           hpos_l >= to_unsigned(VSYNC_PULSE2_START, 8) AND
                           hpos_l <  to_unsigned(VSYNC_PULSE2_START + VSYNC_PULSE_WIDTH, 8)
                         )
                       );
        END CASE;

      END IF;
    END IF;
  END PROCESS;

  hblank   <= hblank_l;
  vblank   <= vblank_l;
  burst    <= burst_l;
  csync    <= csync_l;
  scanline <= scanline_l;
  field    <= field_l;

  hpos <= hpos_l;
  vpos <= vpos_l;
  line_start     <= line_start_l;
  hblank_falling <= hblank_fall_l;
  hblank_rising  <= hblank_rise_l;

END ARCHITECTURE rtl;
