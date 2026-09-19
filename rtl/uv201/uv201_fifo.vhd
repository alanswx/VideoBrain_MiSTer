--------------------------------------------------------------------------------
-- VideoBrain UV201 - 10-entry render FIFO
--------------------------------------------------------------------------------
-- Reference: kevtris "Videobrain Unwrapped" V0.05,
--            "The basics of UV201 rendering".
--
-- Documented behavior reproduced here:
--   * depth = 10 entries;
--   * writes are allowed while occupancy is 0..9 on the way up;
--   * when occupancy reaches 10, writes stop;
--   * after becoming full, writes remain stopped at occupancy 9 and resume
--     only after occupancy falls to 8 or less (the documented 10->8
--     hysteresis);
--   * rising HBLANK clears the FIFO immediately.
--
-- Entry interpretation lives in uv201_pack.  The FIFO itself is deliberately
-- ignorant of rendering semantics.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.uv201_pack.ALL;

ENTITY uv201_fifo IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    -- BRCLK-domain enable.  HBLANK clear is honored independently so the
    -- one-cycle clear pulse cannot be lost to an enable mismatch.
    brclk_ena     : IN std_logic;
    hblank_rising : IN std_logic;

    wr_en    : IN  std_logic;
    wr_entry : IN  uv201_fifo_entry_t;
    writable : OUT std_logic;
    full     : OUT std_logic;

    rd_pop   : IN  std_logic;
    rd_valid : OUT std_logic;
    rd_entry : OUT uv201_fifo_entry_t;

    level : OUT unsigned(3 DOWNTO 0)
    );
END ENTITY uv201_fifo;

ARCHITECTURE rtl OF uv201_fifo IS
  TYPE fifo_mem_t IS ARRAY (0 TO UV201_FIFO_DEPTH - 1) OF uv201_fifo_entry_t;
  SIGNAL mem : fifo_mem_t := (OTHERS => UV201_FIFO_ENTRY_ZERO);

  SIGNAL wr_ptr : natural RANGE 0 TO UV201_FIFO_DEPTH - 1 := 0;
  SIGNAL rd_ptr : natural RANGE 0 TO UV201_FIFO_DEPTH - 1 := 0;
  SIGNAL count  : natural RANGE 0 TO UV201_FIFO_DEPTH := 0;

  -- Hysteretic write gate: once full, remains low until <=8 entries.
  SIGNAL writable_l : std_logic := '1';
BEGIN

  PROCESS (clk, reset_na) IS
    VARIABLE do_push    : boolean;
    VARIABLE do_pop     : boolean;
    VARIABLE next_count : natural RANGE 0 TO UV201_FIFO_DEPTH;
  BEGIN
    IF reset_na = '0' THEN
      mem        <= (OTHERS => UV201_FIFO_ENTRY_ZERO);
      wr_ptr     <= 0;
      rd_ptr     <= 0;
      count      <= 0;
      writable_l <= '1';

    ELSIF rising_edge(clk) THEN
      IF hblank_rising = '1' THEN
        -- Pointer/count reset is sufficient functionally.  Zeroing the array
        -- as well mirrors the documented hardware observation and keeps
        -- simulation/debug waveforms deterministic.
        mem        <= (OTHERS => UV201_FIFO_ENTRY_ZERO);
        wr_ptr     <= 0;
        rd_ptr     <= 0;
        count      <= 0;
        writable_l <= '1';

      ELSIF brclk_ena = '1' THEN
        do_push := (wr_en = '1') AND (writable_l = '1') AND
                   (count < UV201_FIFO_DEPTH);
        do_pop  := (rd_pop = '1') AND (count > 0);

        next_count := count;

        IF do_push THEN
          mem(wr_ptr) <= wr_entry;
          IF wr_ptr = UV201_FIFO_DEPTH - 1 THEN
            wr_ptr <= 0;
          ELSE
            wr_ptr <= wr_ptr + 1;
          END IF;
          next_count := next_count + 1;
        END IF;

        IF do_pop THEN
          IF rd_ptr = UV201_FIFO_DEPTH - 1 THEN
            rd_ptr <= 0;
          ELSE
            rd_ptr <= rd_ptr + 1;
          END IF;
          next_count := next_count - 1;
        END IF;

        count <= next_count;

        IF next_count = UV201_FIFO_DEPTH THEN
          writable_l <= '0';
        ELSIF next_count <= 8 THEN
          writable_l <= '1';
        -- At level 9 retain the previous state: writable while filling,
        -- unwritable while draining from full.  That is the documented
        -- hysteresis rather than a simple count<10 test.
        END IF;
      END IF;
    END IF;
  END PROCESS;

  rd_entry <= mem(rd_ptr) WHEN count > 0 ELSE UV201_FIFO_ENTRY_ZERO;
  rd_valid <= '1' WHEN count > 0 ELSE '0';
  writable <= writable_l;
  full     <= '1' WHEN count = UV201_FIFO_DEPTH ELSE '0';
  level    <= to_unsigned(count, level'length);

END ARCHITECTURE rtl;
