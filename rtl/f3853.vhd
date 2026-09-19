--------------------------------------------------------------------------------
-- Fairchild F3853 SMI - interrupt control and timer
--------------------------------------------------------------------------------
-- Reference: MAME machine/f3853.cpp.  Only the parts VideoBrain uses are
-- modelled: the interrupt vector registers, the interrupt control register,
-- the programmable timer and the request flip-flop.  Memory addressing and the
-- priority daisy chain are not present; the machine has a single SMI.
--
-- Ports (F8 I/O space):
--   0C  interrupt vector, high byte
--   0D  interrupt vector, low byte
--   0E  interrupt control (write only)
--   0F  timer (write only)
--
-- The vector bit 7 distinguishes the two sources, as in f3853.h:
--   timer    -> vector AND NOT x"0080"
--   external -> vector OR  x"0080"
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

ENTITY f3853 IS
  GENERIC (
    -- BRCLK ticks per timer count. The SMI is clocked at phi/2 and divides by
    -- 31; the timer is a 31-stage LFSR, so a full pass is 255 counts.
    PRESCALE : positive := 31
    );
  PORT (
    clk      : IN std_logic;
    reset_na : IN std_logic;
    ce       : IN std_logic;   -- SMI clock enable

    io_addr  : IN  uv8;
    io_rd    : IN  std_logic;
    io_wr    : IN  std_logic;
    io_wdata : IN  uv8;
    io_rdata : OUT uv8;
    io_sel   : OUT std_logic;  -- high when io_addr is one of this device's

    ext_int  : IN std_logic;   -- external interrupt, from the UV201

    int_req    : OUT std_logic;
    int_vector : OUT uv16;
    int_ack    : IN  std_logic
    );
END ENTITY f3853;

ARCHITECTURE rtl OF f3853 IS

  SIGNAL vec : uv16 := (OTHERS => '0');

  SIGNAL ext_enable   : std_logic := '0';
  SIGNAL timer_enable : std_logic := '0';

  -- Set by either source, cleared when the CPU acknowledges.
  SIGNAL request : std_logic := '0';
  SIGNAL ext_int_l : std_logic := '0';

  SIGNAL timer_val   : uv8 := x"FF";
  SIGNAL timer_run   : std_logic := '0';
  SIGNAL prescale_ct : natural RANGE 0 TO PRESCALE - 1 := 0;

  SIGNAL sel : std_logic;

BEGIN

  sel    <= '1' WHEN io_addr(7 DOWNTO 2) = "000011" ELSE '0';  -- 0C-0F
  io_sel <= sel;

  -- Only the two vector bytes read back; control and timer are write only.
  io_rdata <= vec(15 DOWNTO 8) WHEN sel = '1' AND io_addr(1 DOWNTO 0) = "00" ELSE
              vec(7 DOWNTO 0)  WHEN sel = '1' AND io_addr(1 DOWNTO 0) = "01" ELSE
              (OTHERS => '0');

  int_req <= request;

  -- External wins when both are enabled, matching int_acknowledge() order.
  int_vector <= vec OR x"0080"  WHEN ext_enable = '1' ELSE
                vec AND x"FF7F";

  PROCESS (clk, reset_na) IS
    VARIABLE new_ext : std_logic;
  BEGIN
    IF reset_na = '0' THEN
      vec          <= (OTHERS => '0');
      ext_enable   <= '0';
      timer_enable <= '0';
      request      <= '0';
      ext_int_l    <= '0';
      timer_val    <= x"FF";
      timer_run    <= '0';
      prescale_ct  <= 0;

    ELSIF rising_edge(clk) THEN

      -- Rising edge of the external line sets the request, when enabled.
      new_ext := ext_int;
      IF ext_int_l = '0' AND new_ext = '1' AND ext_enable = '1' THEN
        request <= '1';
      END IF;
      ext_int_l <= new_ext;

      IF io_wr = '1' AND sel = '1' THEN
        CASE to_integer(io_addr(1 DOWNTO 0)) IS
          WHEN 0 => vec(15 DOWNTO 8) <= io_wdata;
          WHEN 1 => vec(7 DOWNTO 0)  <= io_wdata;
          WHEN 2 =>
            ext_enable   <= to_std_logic(io_wdata(1 DOWNTO 0) = "01");
            timer_enable <= to_std_logic(io_wdata(1 DOWNTO 0) = "11");
          WHEN OTHERS =>
            -- Writing the timer clears any pending request and restarts it.
            request     <= '0';
            timer_val   <= io_wdata;
            timer_run   <= to_std_logic(io_wdata /= x"FF");
            prescale_ct <= 0;
        END CASE;
      END IF;

      IF ce = '1' AND timer_run = '1' THEN
        IF prescale_ct = PRESCALE - 1 THEN
          prescale_ct <= 0;
          IF timer_val = x"00" THEN
            timer_val <= x"FF";
            IF timer_enable = '1' THEN
              request <= '1';
            END IF;
          ELSE
            timer_val <= timer_val - 1;
          END IF;
        ELSE
          prescale_ct <= prescale_ct + 1;
        END IF;
      END IF;

      -- The CPU took the vector; drop the request.
      IF int_ack = '1' THEN
        request <= '0';
      END IF;

    END IF;
  END PROCESS;

END ARCHITECTURE rtl;
