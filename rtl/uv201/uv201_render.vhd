--------------------------------------------------------------------------------
-- VideoBrain UV201 pixel path
--------------------------------------------------------------------------------
-- Drains the render FIFO into pixels. One entry is consumed per pixel until
-- it is exhausted: a gap entry covers `payload` background pixels, a data
-- entry covers 8 (16 with X zoom). The FIFO is show-ahead, so the head can be
-- used in the same cycle it is popped.
--
-- Colour follows MAME uv201.cpp screen_update(): bytes are MSB first, a 0 bit
-- takes the background register, the 5-bit result is XORed with the final
-- modifier, and the gaps between objects take the background unmodified.
--
-- The palette is initialize_palette(): bit 4 picks the intensity pair and
-- bits 2:0 are blue/green/red. Only two intensity steps are distinct, so a
-- high-intensity black is grey rather than black.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv201_pack.ALL;

ENTITY uv201_render IS
  PORT (
    clk      : IN std_logic;
    reset_na : IN std_logic;

    brclk_ena : IN std_logic;   -- one pixel per BRCLK

    hblank : IN std_logic;
    vblank : IN std_logic;
    hpos   : IN unsigned(7 DOWNTO 0);
    vpos   : IN unsigned(8 DOWNTO 0);

    fifo_valid : IN  std_logic;
    fifo_entry : IN  uv201_fifo_entry_t;
    fifo_pop   : OUT std_logic;

    final_mod  : IN std_logic_vector(7 DOWNTO 0);
    background : IN std_logic_vector(7 DOWNTO 0);
    x_zoom     : IN std_logic;
    video_en   : IN std_logic;

    ce_pix : OUT std_logic;
    idx    : OUT std_logic_vector(4 DOWNTO 0);  -- palette index, for debug
    r      : OUT unsigned(7 DOWNTO 0);
    g      : OUT unsigned(7 DOWNTO 0);
    b      : OUT unsigned(7 DOWNTO 0);
    de     : OUT std_logic;
    hs     : OUT std_logic;
    vs     : OUT std_logic;
    hb     : OUT std_logic;
    vb     : OUT std_logic
    );
END ENTITY uv201_render;

ARCHITECTURE rtl OF uv201_render IS

  SIGNAL shift_reg    : uv8 := (OTHERS => '0');
  SIGNAL shift_cnt    : natural RANGE 0 TO 7 := 0;
  SIGNAL shift_color  : std_logic_vector(4 DOWNTO 0) := (OTHERS => '0');
  SIGNAL shift_active : std_logic := '0';
  SIGNAL gap_cnt      : uv8 := (OTHERS => '0');
  SIGNAL dbl          : std_logic := '0';   -- X zoom: second pixel of a pair

  SIGNAL active     : std_logic;
  SIGNAL need_entry : std_logic;
  SIGNAL fresh_data : std_logic;
  SIGNAL in_object  : std_logic;
  SIGNAL obj_bit    : std_logic;
  SIGNAL obj_color  : std_logic_vector(4 DOWNTO 0);
  SIGNAL idx_c      : std_logic_vector(4 DOWNTO 0);
  SIGNAL obj_idx    : std_logic_vector(4 DOWNTO 0);

  SIGNAL off_l, on_l : uv8;
  SIGNAL r_c, g_c, b_c : uv8;
  SIGNAL show        : std_logic;

  SIGNAL ce_pix_l : std_logic := '0';
  SIGNAL idx_l    : std_logic_vector(4 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_l, g_l, b_l : uv8 := (OTHERS => '0');
  SIGNAL de_l, hs_l, vs_l, hb_l, vb_l : std_logic := '0';

BEGIN

  active     <= NOT hblank AND NOT vblank;
  need_entry <= active AND NOT shift_active AND
                to_std_logic(gap_cnt = 0) AND fifo_valid;

  -- The FIFO only acts on a pop while brclk_ena is high.
  fifo_pop <= need_entry AND brclk_ena;

  PROCESS (clk, reset_na) IS
  BEGIN
    IF reset_na = '0' THEN
      shift_active <= '0';
      shift_cnt    <= 0;
      gap_cnt      <= (OTHERS => '0');
      dbl          <= '0';
      ce_pix_l     <= '0';

    ELSIF rising_edge(clk) THEN
      ce_pix_l <= brclk_ena;

      IF brclk_ena = '1' THEN
        IF active = '0' THEN
          shift_active <= '0';
          shift_cnt    <= 0;
          gap_cnt      <= (OTHERS => '0');
          dbl          <= '0';

        ELSIF shift_active = '1' THEN
          -- With X zoom each bit covers two pixels; advance on the second.
          IF x_zoom = '1' AND dbl = '0' THEN
            dbl <= '1';
          ELSE
            dbl <= '0';
            shift_reg <= shift_reg(6 DOWNTO 0) & '0';
            IF shift_cnt = 0 THEN
              shift_active <= '0';
            ELSE
              shift_cnt <= shift_cnt - 1;
            END IF;
          END IF;

        ELSIF gap_cnt /= 0 THEN
          gap_cnt <= gap_cnt - 1;

        ELSIF fifo_valid = '1' THEN
          IF fifo_entry.is_gap = '1' THEN
            -- This cycle emits the gap's first pixel.
            IF fifo_entry.payload = 0 THEN
              gap_cnt <= (OTHERS => '0');
            ELSE
              gap_cnt <= fifo_entry.payload - 1;
            END IF;
          ELSE
            shift_color  <= fifo_entry.color;
            shift_active <= '1';
            IF x_zoom = '1' THEN
              -- bit 7 shows now and once more; the shift happens then.
              shift_reg <= fifo_entry.payload;
              shift_cnt <= 7;
              dbl       <= '1';
            ELSE
              shift_reg <= fifo_entry.payload(6 DOWNTO 0) & '0';
              shift_cnt <= 6;
              dbl       <= '0';
            END IF;
          END IF;
        END IF;

        -- Latch the pixel this period emitted, plus the sync it belongs to.
        idx_l <= idx_c;
        IF show = '1' THEN
          r_l <= r_c;
          g_l <= g_c;
          b_l <= b_c;
        ELSE
          r_l <= (OTHERS => '0');
          g_l <= (OTHERS => '0');
          b_l <= (OTHERS => '0');
        END IF;
        de_l <= active;
        hb_l <= hblank;
        vb_l <= vblank;
        hs_l <= to_std_logic(hpos < 18);
        vs_l <= to_std_logic(vpos < 3);
      END IF;
    END IF;
  END PROCESS;

  -- Pixel currently being emitted, chosen the same way as the state update.
  fresh_data <= (NOT shift_active) AND to_std_logic(gap_cnt = 0) AND
                fifo_valid AND (NOT fifo_entry.is_gap);
  in_object  <= shift_active OR fresh_data;
  obj_bit    <= shift_reg(7) WHEN shift_active = '1' ELSE fifo_entry.payload(7);
  obj_color  <= shift_color  WHEN shift_active = '1' ELSE fifo_entry.color;

  -- A 0 bit inside an object takes the background, and the whole 5-bit
  -- result is modified. The gaps between objects are not.
  obj_idx <= obj_color WHEN obj_bit = '1' ELSE background(4 DOWNTO 0);
  idx_c   <= (obj_idx XOR final_mod(4 DOWNTO 0)) WHEN in_object = '1'
             ELSE background(4 DOWNTO 0);

  off_l <= x"C0" WHEN idx_c(4) = '1' ELSE x"00";
  on_l  <= x"FF" WHEN idx_c(4) = '1' ELSE x"A0";

  r_c <= on_l WHEN idx_c(0) = '1' ELSE off_l;
  g_c <= on_l WHEN idx_c(1) = '1' ELSE off_l;
  b_c <= on_l WHEN idx_c(2) = '1' ELSE off_l;

  -- COMMAND_ENB clear blanks the screen, as in screen_update().
  show <= active AND video_en;

  ce_pix <= ce_pix_l;
  idx    <= idx_l;
  r      <= r_l;
  g      <= g_l;
  b      <= b_l;
  de     <= de_l;
  hs     <= hs_l;
  vs     <= vs_l;
  hb     <= hb_l;
  vb     <= vb_l;

END ARCHITECTURE rtl;
