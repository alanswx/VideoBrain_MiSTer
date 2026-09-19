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

    -- F8 ports 0 and 1 live inside the CPU, so this hangs off its port pins
    -- rather than the external I/O bus. f8_cpu already inverts them, so these
    -- are the active-low pin values.
    port_a_n    : IN  uv8;   -- po_a_n: column latch, and sound data in bits 1:0
    port_b_n    : IN  uv8;   -- po_b_n: sound clock, accessories, joystick enable
    port_b_in_n : OUT uv8;   -- pi_b_n: keyboard rows and fire buttons

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
    VARIABLE port_a_v : uv8;
    VARIABLE port_b_v : uv8;
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

      port_a_v := NOT port_a_n;
      port_b_v := NOT port_b_n;

      key_latch_l <= port_a_v;

      -- Rising edge of the sound clock latches the 2-bit DAC code.
      IF sound_clk_l = '0' AND port_b_v(4) = '1' THEN
        audio_code_l <= std_logic_vector(port_a_v(1 DOWNTO 0));
        audio_stb_l  <= '1';
      END IF;

      sound_clk_l    <= port_b_v(4);
      accessory_p5_l <= port_b_v(5);
      accessory_p1_l <= port_b_v(6);
      joy_enable_l   <= NOT port_b_v(7);
    END IF;
  END PROCESS;

  PROCESS (key_latch_l, kbd_matrix, joy_fire, uv_kbd) IS
    VARIABLE rows : std_logic_vector(3 DOWNTO 0);
  BEGIN
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

    port_b_in_n <= NOT unsigned("0000" & rows);
  END PROCESS;

  key_latch    <= key_latch_l;
  joy_enable   <= joy_enable_l;
  accessory_p5 <= accessory_p5_l;
  accessory_p1 <= accessory_p1_l;
  audio_code   <= audio_code_l;
  audio_stb    <= audio_stb_l;

END ARCHITECTURE rtl;
