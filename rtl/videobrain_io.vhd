--------------------------------------------------------------------------------
-- VideoBrain F8 I/O ports 00/01: keyboard, sound, joystick enable
--------------------------------------------------------------------------------
-- Reference: MAME vidbrain.cpp keyboard_w(), keyboard_r(), sound_w(), checked
-- against the VideoBrain keyboard/joystick wiring notes retained in docs/.
--
-- Port 00 write:
--   bits 0..7 = keyboard column latch; bits 0..1 also hold 2-bit sound data.
-- Port 01 read:
--   bits 0..3 = OR of selected keyboard rows and joystick fire buttons.
-- Port 01 write:
--   bit 4 = sound clock; rising edge latches port-00 bits 1..0 to the DAC.
--   bits 5/6 = accessory outputs; bit 7 = active-low joystick enable.
--
-- The ninth keyboard column is selected by UV201 command bit KBD.  MAME's
-- kbd_r() returns that bit directly, and the machine reads column 8 when it is
-- LOW; uv_kbd therefore follows that same active-low selection convention.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

ENTITY videobrain_io IS
  PORT (
    clk      : IN  std_logic;
    reset_na : IN  std_logic;

    io_addr  : IN  uv8;
    io_rd    : IN  std_logic;
    io_wr    : IN  std_logic;
    io_wdata : IN  uv8;
    io_rdata : OUT uv8;

    -- Keyboard matrix, 9 columns x 4 rows, flattened by column:
    --   col0 = bits 3..0, col1 = bits 7..4, ... col8 = bits 35..32.
    -- Inputs are active high, matching the logical level used by MAME.
    kbd_matrix : IN std_logic_vector(35 DOWNTO 0);
    joy_fire   : IN std_logic_vector(3 DOWNTO 0);
    uv_kbd     : IN std_logic;

    -- Current port-00 latch and decoded control outputs.
    key_latch     : OUT uv8;
    joy_enable    : OUT std_logic;
    accessory_p5  : OUT std_logic;
    accessory_p1  : OUT std_logic;

    -- 2-bit R-2R DAC code. audio_stb pulses for one clk on the rising edge
    -- of the port-01 sound-clock bit, exactly when hardware clocks the latch.
    audio_code : OUT std_logic_vector(1 DOWNTO 0);
    audio_stb  : OUT std_logic
    );
END ENTITY videobrain_io;

ARCHITECTURE rtl OF videobrain_io IS
  SIGNAL key_latch_l : uv8 := (OTHERS => '0');
  SIGNAL sound_clk_l : std_logic := '0';
  SIGNAL joy_enable_l : std_logic := '1';
  SIGNAL accessory_p5_l : std_logic := '0';
  SIGNAL accessory_p1_l : std_logic := '0';
  SIGNAL audio_code_l : std_logic_vector(1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL audio_stb_l : std_logic := '0';
BEGIN

  PROCESS (clk, reset_na) IS
    VARIABLE new_sound_clk : std_logic;
  BEGIN
    IF reset_na = '0' THEN
      key_latch_l    <= (OTHERS => '0');
      sound_clk_l    <= '0';
      joy_enable_l   <= '1';
      accessory_p5_l <= '0';
      accessory_p1_l <= '0';
      audio_code_l   <= (OTHERS => '0');
      audio_stb_l    <= '0';

    ELSIF rising_edge(clk) THEN
      audio_stb_l <= '0';

      IF io_wr = '1' THEN
        IF unsigned(io_addr) = to_unsigned(16#00#, 8) THEN
          key_latch_l <= io_wdata;

        ELSIF unsigned(io_addr) = to_unsigned(16#01#, 8) THEN
          new_sound_clk := io_wdata(4);

          IF sound_clk_l = '0' AND new_sound_clk = '1' THEN
            audio_code_l <= std_logic_vector(key_latch_l(1 DOWNTO 0));
            audio_stb_l  <= '1';
          END IF;

          sound_clk_l    <= new_sound_clk;
          accessory_p5_l <= io_wdata(5);
          accessory_p1_l <= io_wdata(6);
          joy_enable_l   <= NOT io_wdata(7);
        END IF;
      END IF;
    END IF;
  END PROCESS;

  PROCESS (io_addr, io_rd, key_latch_l, kbd_matrix, joy_fire, uv_kbd) IS
    VARIABLE rows : std_logic_vector(3 DOWNTO 0);
  BEGIN
    io_rdata <= (OTHERS => '1');
    rows := joy_fire;

    FOR col IN 0 TO 7 LOOP
      IF key_latch_l(col) = '1' THEN
        FOR row IN 0 TO 3 LOOP
          rows(row) := rows(row) OR kbd_matrix(col * 4 + row);
        END LOOP;
      END IF;
    END LOOP;

    -- UV201 KBD = 0 selects the ninth column.
    IF uv_kbd = '0' THEN
      FOR row IN 0 TO 3 LOOP
        rows(row) := rows(row) OR kbd_matrix(32 + row);
      END LOOP;
    END IF;

    IF io_rd = '1' AND unsigned(io_addr) = to_unsigned(16#01#, 8) THEN
      io_rdata <= unsigned("0000" & rows);
    END IF;
  END PROCESS;

  key_latch    <= key_latch_l;
  joy_enable   <= joy_enable_l;
  accessory_p5 <= accessory_p5_l;
  accessory_p1 <= accessory_p1_l;
  audio_code   <= audio_code_l;
  audio_stb    <= audio_stb_l;

END ARCHITECTURE rtl;
