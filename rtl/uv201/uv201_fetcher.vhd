--------------------------------------------------------------------------------
-- VideoBrain UV201 object fetcher
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.uv201_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY uv201_fetcher IS
  PORT (
    clk        : IN  std_logic;
    reset_na   : IN  std_logic;
    brclk_ena  : IN  std_logic;

    line_start : IN  std_logic;
    fifo_clear : IN  std_logic;
    vpos       : IN  unsigned(8 DOWNTO 0);
    video_en   : IN  std_logic;
    list_a     : IN  std_logic;

    -- Global pixel doubling from the command register. X zoom also doubles
    -- the object's start column, as in MAME screen_update().
    x_zoom     : IN  std_logic;
    y_zoom     : IN  std_logic;

    obj_addr   : OUT uv8;
    obj_rdata  : IN  uv8;

    bb_addr    : OUT unsigned(12 DOWNTO 0);
    bb_rdata   : IN  uv8;
    umireq     : OUT std_logic;
    dmareq     : IN  std_logic;

    fifo_writable : IN  std_logic;
    fifo_wr_en    : OUT std_logic;
    fifo_wr_entry : OUT uv201_fifo_entry_t;

    busy       : OUT std_logic
    );
END ENTITY uv201_fetcher;

ARCHITECTURE rtl OF uv201_fetcher IS

  TYPE state_t IS (
    ST_IDLE,
    ST_Y_LO,
    ST_XY_HI,
    ST_DY,
    ST_RP_LO,
    ST_RP_HI,
    ST_DX,
    ST_X,
    ST_DECIDE,
    ST_GAP_PUSH,
    ST_DMA_WAIT,
    ST_DMA_PUSH
    );

  SIGNAL state : state_t := ST_IDLE;
  SIGNAL entry_i : natural RANGE 0 TO 15 := 0;

  SIGNAL y_lo_l   : uv8 := (OTHERS => '0');
  SIGNAL xy_hi_l  : uv8 := (OTHERS => '0');
  SIGNAL dy_l     : uv8 := (OTHERS => '0');
  SIGNAL rp_lo_l  : uv8 := (OTHERS => '0');
  SIGNAL rp_hi_l  : uv8 := (OTHERS => '0');
  SIGNAL dx_l     : uv8 := (OTHERS => '0');
  SIGNAL x_l      : uv8 := (OTHERS => '0');

  SIGNAL ptr_l      : unsigned(12 DOWNTO 0) := (OTHERS => '0');
  SIGNAL bytes_left : natural RANGE 0 TO 31 := 0;
  SIGNAL xcopy_l    : std_logic := '0';
  SIGNAL color_l    : std_logic_vector(4 DOWNTO 0) := (OTHERS => '0');
  SIGNAL xdelta_l   : natural RANGE 0 TO 511 := 0;
  SIGNAL gap_l      : uv8 := (OTHERS => '0');
  SIGNAL dma_data_l : uv8 := (OTHERS => '0');

  FUNCTION obj_bank(base : natural; i : natural) RETURN uv8 IS
  BEGIN
    RETURN to_unsigned(base + i, 8);
  END FUNCTION;

BEGIN

  PROCESS(state, entry_i, list_a, xy_hi_l) IS
    VARIABLE xord_v : natural RANGE 0 TO 15;
  BEGIN
    xord_v := to_integer(xy_hi_l(3 DOWNTO 0));

    CASE state IS
      WHEN ST_Y_LO =>
        IF list_a = '1' THEN
          obj_addr <= obj_bank(REG_Y_LO_A, entry_i);
        ELSE
          obj_addr <= obj_bank(REG_Y_LO_B, entry_i);
        END IF;

      WHEN ST_XY_HI =>
        IF list_a = '1' THEN
          obj_addr <= obj_bank(REG_XY_HI_A, entry_i);
        ELSE
          obj_addr <= obj_bank(REG_XY_HI_B, entry_i);
        END IF;

      WHEN ST_DY =>
        obj_addr <= obj_bank(REG_DY, xord_v);
      WHEN ST_RP_LO =>
        obj_addr <= obj_bank(REG_RP_LO, xord_v);
      WHEN ST_RP_HI =>
        obj_addr <= obj_bank(REG_RP_HI_COLOR, xord_v);
      WHEN ST_DX =>
        obj_addr <= obj_bank(REG_DX_INT_XCOPY, xord_v);
      WHEN ST_X =>
        obj_addr <= obj_bank(REG_X, xord_v);
      WHEN OTHERS =>
        obj_addr <= (OTHERS => '0');
    END CASE;
  END PROCESS;

  bb_addr <= ptr_l;
  umireq <= '1' WHEN state = ST_DMA_WAIT AND fifo_writable = '1' ELSE '0';

  PROCESS(state, gap_l, dma_data_l, color_l, fifo_writable) IS
  BEGIN
    fifo_wr_en <= '0';
    fifo_wr_entry <= UV201_FIFO_ENTRY_ZERO;

    IF state = ST_GAP_PUSH AND fifo_writable = '1' THEN
      fifo_wr_en <= '1';
      fifo_wr_entry.is_gap <= '1';
      fifo_wr_entry.payload <= gap_l;
    ELSIF state = ST_DMA_PUSH AND fifo_writable = '1' THEN
      fifo_wr_en <= '1';
      fifo_wr_entry.payload <= dma_data_l;
      fifo_wr_entry.color <= color_l;
    END IF;
  END PROCESS;

  PROCESS(clk, reset_na) IS
    VARIABLE y_v      : natural RANGE 0 TO 511;
    VARIABLE height_v : natural RANGE 0 TO 64;
    VARIABLE span_v   : natural RANGE 0 TO 510;
    VARIABLE height_t : natural RANGE 0 TO 128;
    VARIABLE y_t      : natural RANGE 0 TO 511;
    VARIABLE xstart_v : natural RANGE 0 TO 510;
    VARIABLE row_v    : natural RANGE 0 TO 511;
    VARIABLE width_v  : natural RANGE 0 TO 32;
    VARIABLE base_v   : unsigned(12 DOWNTO 0);
    VARIABLE offset_v : natural RANGE 0 TO 16383;
  BEGIN
    IF reset_na = '0' THEN
      state <= ST_IDLE;
      entry_i <= 0;
      y_lo_l <= (OTHERS => '0');
      xy_hi_l <= (OTHERS => '0');
      dy_l <= (OTHERS => '0');
      rp_lo_l <= (OTHERS => '0');
      rp_hi_l <= (OTHERS => '0');
      dx_l <= (OTHERS => '0');
      x_l <= (OTHERS => '0');
      ptr_l <= (OTHERS => '0');
      bytes_left <= 0;
      xcopy_l <= '0';
      color_l <= (OTHERS => '0');
      xdelta_l <= 0;
      gap_l <= (OTHERS => '0');
      dma_data_l <= (OTHERS => '0');

    ELSIF rising_edge(clk) THEN
      IF fifo_clear = '1' THEN
        xdelta_l <= 0;
      END IF;

      IF line_start = '1' THEN
        entry_i <= 0;
        xdelta_l <= 0;
        IF video_en = '1' THEN
          state <= ST_Y_LO;
        ELSE
          state <= ST_IDLE;
        END IF;

      ELSIF state = ST_DMA_WAIT AND dmareq = '1' THEN
        dma_data_l <= bb_rdata;
        state <= ST_DMA_PUSH;

      ELSIF brclk_ena = '1' THEN
        CASE state IS
          WHEN ST_IDLE =>
            NULL;

          WHEN ST_Y_LO =>
            y_lo_l <= obj_rdata;
            state <= ST_XY_HI;

          WHEN ST_XY_HI =>
            xy_hi_l <= obj_rdata;
            state <= ST_DY;

          WHEN ST_DY =>
            dy_l <= obj_rdata;

            -- Early Y reject. The pointer, width and column registers are
            -- only needed for an object that is on this scanline, and
            -- fetching them for the other fifteen costs four BRCLK each,
            -- which is enough to run the line out of time. Hardware checks
            -- the start row first.
            height_t := to_integer(obj_rdata(5 DOWNTO 0));
            IF height_t = 0 THEN
              height_t := 64;
            END IF;
            IF y_zoom = '1' THEN
              height_t := height_t * 2;
            END IF;
            y_t := to_integer(xy_hi_l(7) & y_lo_l);

            IF to_integer(vpos) >= y_t AND to_integer(vpos) < y_t + height_t THEN
              state <= ST_RP_LO;
            ELSIF entry_i = 15 THEN
              state <= ST_IDLE;
            ELSE
              entry_i <= entry_i + 1;
              state <= ST_Y_LO;
            END IF;

          WHEN ST_RP_LO =>
            rp_lo_l <= obj_rdata;
            state <= ST_RP_HI;

          WHEN ST_RP_HI =>
            rp_hi_l <= obj_rdata;
            state <= ST_DX;

          WHEN ST_DX =>
            dx_l <= obj_rdata;
            state <= ST_X;

          WHEN ST_X =>
            x_l <= obj_rdata;
            state <= ST_DECIDE;

          WHEN ST_DECIDE =>
            y_v := to_integer(xy_hi_l(7) & y_lo_l);
            -- Measured on hardware by kevtris (group archive, 2013-05-09):
            -- height is six bits, 0 means 64 scanlines, and bits 6/7 do
            -- nothing. Width is five bytes-wide bits, 0 meaning 32 bytes
            -- (256 pixels). MAME differs on both and draws nothing for 0.
            height_v := to_integer(dy_l(5 DOWNTO 0));
            IF height_v = 0 THEN
              height_v := 64;
            END IF;

            width_v := to_integer(dx_l(4 DOWNTO 0));
            IF width_v = 0 THEN
              width_v := 32;
            END IF;

            IF y_zoom = '1' THEN
              span_v := height_v * 2;
            ELSE
              span_v := height_v;
            END IF;

            IF x_zoom = '1' THEN
              xstart_v := to_integer(x_l) * 2;
            ELSE
              xstart_v := to_integer(x_l);
            END IF;

            IF to_integer(vpos) >= y_v AND
               to_integer(vpos) < y_v + span_v AND
               xstart_v >= xdelta_l THEN

              IF y_zoom = '1' THEN
                row_v := (to_integer(vpos) - y_v) / 2;
              ELSE
                row_v := to_integer(vpos) - y_v;
              END IF;
              base_v := rp_hi_l(4 DOWNTO 0) & rp_lo_l;
              IF dx_l(7) = '1' THEN
                offset_v := row_v;
              ELSE
                offset_v := row_v * width_v;
              END IF;

              ptr_l <= to_unsigned(
                (to_integer(base_v) + (offset_v MOD 8192)) MOD 8192, 13);

              bytes_left <= width_v;
              xcopy_l <= dx_l(7);
              color_l <= std_logic_vector(dx_l(6 DOWNTO 5)) &
                         rp_hi_l(5) & rp_hi_l(6) & rp_hi_l(7);

              IF xstart_v > xdelta_l THEN
                gap_l <= to_unsigned(xstart_v - xdelta_l, 8);
                xdelta_l <= xstart_v;
                state <= ST_GAP_PUSH;
              ELSE
                state <= ST_DMA_WAIT;
              END IF;

            ELSIF entry_i = 15 THEN
              state <= ST_IDLE;
            ELSE
              entry_i <= entry_i + 1;
              state <= ST_Y_LO;
            END IF;

          WHEN ST_GAP_PUSH =>
            IF fifo_writable = '1' THEN
              state <= ST_DMA_WAIT;
            END IF;

          WHEN ST_DMA_WAIT =>
            NULL;

          WHEN ST_DMA_PUSH =>
            IF fifo_writable = '1' THEN
              IF x_zoom = '1' THEN
                xdelta_l <= xdelta_l + 16;
              ELSE
                xdelta_l <= xdelta_l + 8;
              END IF;

              IF bytes_left > 1 THEN
                bytes_left <= bytes_left - 1;
                IF xcopy_l = '0' THEN
                  ptr_l <= to_unsigned(
                    (to_integer(ptr_l) + 1) MOD 8192, 13);

                END IF;
                state <= ST_DMA_WAIT;
              ELSIF entry_i = 15 THEN
                bytes_left <= 0;
                state <= ST_IDLE;
              ELSE
                bytes_left <= 0;
                entry_i <= entry_i + 1;
                state <= ST_Y_LO;
              END IF;
            END IF;
        END CASE;
      END IF;
    END IF;
  END PROCESS;

  busy <= to_std_logic(state /= ST_IDLE);

END ARCHITECTURE rtl;
