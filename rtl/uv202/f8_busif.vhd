--------------------------------------------------------------------------------
-- VideoBrain F8 address/bus interface
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.f8_pack.ALL;
USE work.uv202_pack.ALL;

ENTITY f8_busif IS
  PORT (
    dw       : IN  uv8;
    dr       : OUT uv8;
    dv       : OUT std_logic;

    romc     : IN  uv5;
    tick     : IN  std_logic;
    phase    : IN  uint4;

    clk      : IN  std_logic;
    ce       : IN  std_logic;
    reset_na : IN  std_logic;

    ext_addr  : OUT unsigned(13 DOWNTO 0);
    ext_rd    : OUT std_logic;
    ext_wr    : OUT std_logic;
    ext_wdata : OUT uv8;
    ext_rdata : IN  uv8;

    ext_req   : OUT std_logic;
    ext_class : OUT bus_access_t;
    ext_grant : IN  std_logic;

    -- F8 external I/O ports (4-15). Ports 0/1 are internal to the CPU.
    io_addr  : OUT uv8;
    io_rd    : OUT std_logic;
    io_wr    : OUT std_logic;
    io_wdata : OUT uv8;
    io_rdata : IN  uv8;

    -- Interrupt vector from the F3853, latched on int_ack.
    int_vector : IN  uv16;
    int_ack    : OUT std_logic;

    pc0o      : OUT uv16;
    pc1o      : OUT uv16;
    dc0o      : OUT uv16
    );
END ENTITY f8_busif;

ARCHITECTURE rtl OF f8_busif IS

  -- DC1 exists only to be swapped with DC0 by XDC (ROMC 1D). Nothing else
  -- addresses it, which is why upstream Channel F never needed it.
  SIGNAL dc0, dc1, pc0, pc1 : uv16 := (OTHERS => '0');
  SIGNAL dr_l : uv8 := (OTHERS => '0');
  SIGNAL dv_l : std_logic := '0';

  SIGNAL ext_req_l   : std_logic := '0';
  SIGNAL ext_class_l : bus_access_t := ACC_NONE;
  SIGNAL ext_addr_l  : unsigned(13 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ext_rd_l    : std_logic := '0';
  SIGNAL ext_wr_l    : std_logic := '0';
  SIGNAL ext_wdata_l : uv8 := (OTHERS => '0');
  SIGNAL write_pending : std_logic := '0';

  -- Port number for the next ROMC 1A/1B. IN/OUT aa leave it in dr_l from the
  -- preceding ROMC 03; INS/OUTS n put it on dw during the preceding ROMC 1C.
  SIGNAL port_l : uv8 := (OTHERS => '0');
  SIGNAL io_rd_l, io_wr_l : std_logic := '0';
  SIGNAL io_wdata_l : uv8 := (OTHERS => '0');
  SIGNAL int_ack_l : std_logic := '0';

  FUNCTION classify(a : unsigned(13 DOWNTO 0); is_write : std_logic)
    RETURN bus_access_t IS
    VARIABLE a_eff : unsigned(13 DOWNTO 0) := cpu_addr_fold(a);
    VARIABLE result : bus_access_t;
  BEGIN
    IF a_eff < to_unsigned(ADDR_UV201_LO, 14) THEN
      result := ACC_NONE;
    ELSIF a_eff <= to_unsigned(ADDR_UV201_HI, 14) THEN
      result := ACC_UV201_WR WHEN is_write = '1' ELSE ACC_UV201_RD;
    ELSIF a_eff <= to_unsigned(ADDR_RAM_HI, 14) THEN
      result := ACC_RAM_WR WHEN is_write = '1' ELSE ACC_RAM_RD;
    ELSIF a_eff <= to_unsigned(ADDR_CART2_HI, 14) THEN
      result := ACC_CART_WR WHEN is_write = '1' ELSE ACC_CART_RD;
    ELSIF a_eff <= to_unsigned(ADDR_RES2_HI, 14) THEN
      result := ACC_RES2;
    ELSE
      result := ACC_NONE;
    END IF;
    RETURN result;
  END FUNCTION;

BEGIN

  PROCESS(clk, reset_na) IS
    VARIABLE addr_v : unsigned(13 DOWNTO 0);
    VARIABLE cls_v  : bus_access_t;
  BEGIN
    IF reset_na = '0' THEN
      pc0 <= (OTHERS => '0');
      pc1 <= (OTHERS => '0');
      dc0 <= (OTHERS => '0');
      dc1 <= (OTHERS => '0');
      dr_l <= (OTHERS => '0');
      dv_l <= '0';
      ext_req_l <= '0';
      ext_class_l <= ACC_NONE;
      ext_addr_l <= (OTHERS => '0');
      ext_rd_l <= '0';
      ext_wr_l <= '0';
      ext_wdata_l <= (OTHERS => '0');
      write_pending <= '0';

    ELSIF rising_edge(clk) THEN
      ext_rd_l <= '0';
      ext_wr_l <= '0';
      io_rd_l   <= '0';
      io_wr_l   <= '0';
      int_ack_l <= '0';

      IF write_pending = '1' THEN
        ext_wdata_l <= dw;
      END IF;

      -- Grant is consumed while the CPU is held. Store data is valid by then.
      IF ext_grant = '1' THEN
        ext_req_l <= '0';
        IF write_pending = '1' THEN
          ext_wdata_l <= dw;
          ext_wr_l <= '1';
          write_pending <= '0';
        END IF;
      END IF;

      IF ce = '1' THEN

        IF phase = 2 THEN
          dv_l <= '0';
        END IF;

        CASE romc IS
          WHEN ROMC_00 | ROMC_01 | ROMC_03 | ROMC_0C | ROMC_0E | ROMC_11 =>
            IF phase = 1 THEN
              addr_v := pc0(13 DOWNTO 0);
              cls_v := classify(addr_v, '0');
              ext_addr_l <= addr_v;
              ext_class_l <= cls_v;
              IF cls_v /= ACC_NONE THEN
                ext_req_l <= '1';
              END IF;
            END IF;
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
            END IF;

            IF phase = 6 THEN
              CASE romc IS
                WHEN ROMC_00 =>
                  pc0 <= pc0 + 1;
                -- These four take the byte the addressed device placed on the
                -- bus, latched into dr_l at phase 2.  dw is the CPU's own
                -- output and is only correct for the CPU-sourced ROMC states
                -- (0A, 12, 14-19).
                WHEN ROMC_01 =>
                  pc0 <= pc0 + sext(dr_l, 16);
                WHEN ROMC_03 =>
                  pc0 <= pc0 + 1;
                  port_l <= dr_l;   -- IN/OUT aa: the immediate is the port
                WHEN ROMC_0C =>
                  pc0(7 DOWNTO 0) <= dr_l;
                WHEN ROMC_0E =>
                  dc0(7 DOWNTO 0) <= dr_l;
                WHEN ROMC_11 =>
                  dc0(15 DOWNTO 8) <= dr_l;
                WHEN OTHERS =>
                  NULL;
              END CASE;
            END IF;

          WHEN ROMC_02 =>
            IF phase = 1 THEN
              addr_v := dc0(13 DOWNTO 0);
              cls_v := classify(addr_v, '0');
              ext_addr_l <= addr_v;
              ext_class_l <= cls_v;
              IF cls_v /= ACC_NONE THEN
                ext_req_l <= '1';
              END IF;
            END IF;
            IF phase = 2 THEN
              dr_l <= ext_rdata;
              dv_l <= '1';
              ext_rd_l <= '1';
            END IF;
            IF phase = 6 THEN
              dc0 <= dc0 + 1;
            END IF;

          WHEN ROMC_04 =>
            IF phase = 6 THEN
              pc0 <= pc1;
            END IF;

          WHEN ROMC_05 =>
            IF phase = 4 THEN
              addr_v := dc0(13 DOWNTO 0);
              cls_v := classify(addr_v, '1');
              ext_addr_l <= addr_v;
              ext_class_l <= cls_v;
              IF cls_v /= ACC_NONE THEN
                ext_req_l <= '1';
                write_pending <= '1';
              ELSE
                write_pending <= '0';
              END IF;
            END IF;
            IF phase = 6 THEN
              dc0 <= dc0 + 1;
            END IF;

          WHEN ROMC_06 =>
            IF phase = 2 THEN
              dr_l <= dc0(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN ROMC_07 =>
            IF phase = 2 THEN
              dr_l <= pc1(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN ROMC_08 =>
            IF phase = 6 THEN
              pc1 <= pc0;
              pc0 <= x"0000";
            END IF;

          WHEN ROMC_09 =>
            IF phase = 2 THEN
              dr_l <= dc0(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN ROMC_0A =>
            IF phase = 6 THEN
              dc0 <= dc0 + sext(dw, 16);
            END IF;

          WHEN ROMC_0B =>
            IF phase = 2 THEN
              dr_l <= pc1(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN ROMC_0D =>
            IF phase = 6 THEN
              pc1 <= pc0 + 1;
            END IF;

          -- ROMC 0F: the interrupting device supplies the low vector byte and
          -- all devices copy PC0 into PC1.  This core's terminating ROMC 00 has
          -- already fetched and discarded the next opcode, so PC0 sits one past
          -- the interrupted instruction and PC1 must back up over it.
          WHEN ROMC_0F =>
            IF phase = 1 THEN
              int_ack_l <= '1';
            END IF;
            IF phase = 2 THEN
              dr_l <= int_vector(7 DOWNTO 0);
              dv_l <= '1';
            END IF;
            IF phase = 6 THEN
              pc1 <= pc0 - 1;
              pc0(7 DOWNTO 0) <= int_vector(7 DOWNTO 0);
            END IF;

          -- ROMC 13: high vector byte, and the device drops its request.
          WHEN ROMC_13 =>
            IF phase = 2 THEN
              dr_l <= int_vector(15 DOWNTO 8);
              dv_l <= '1';
            END IF;
            IF phase = 6 THEN
              pc0(15 DOWNTO 8) <= int_vector(15 DOWNTO 8);
            END IF;

          -- INS/OUTS n drive the port number onto the data bus here.
          WHEN ROMC_1C =>
            IF phase = 6 THEN
              port_l <= dw;
            END IF;

          WHEN ROMC_1A =>
            IF phase = 6 THEN
              io_wdata_l <= dw;
              io_wr_l <= '1';
            END IF;

          WHEN ROMC_1B =>
            IF phase = 2 THEN
              io_rd_l <= '1';
            END IF;
            IF phase = 6 THEN
              dr_l <= io_rdata;
              dv_l <= '1';
            END IF;

          WHEN ROMC_12 =>
            IF phase = 6 THEN
              pc1 <= pc0;
              pc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN ROMC_14 =>
            IF phase = 6 THEN
              pc0(15 DOWNTO 8) <= dw;
            END IF;

          WHEN ROMC_15 =>
            IF phase = 6 THEN
              pc1(15 DOWNTO 8) <= dw;
            END IF;

          WHEN ROMC_16 =>
            IF phase = 6 THEN
              dc0(15 DOWNTO 8) <= dw;
            END IF;

          WHEN ROMC_17 =>
            IF phase = 6 THEN
              pc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN ROMC_18 =>
            IF phase = 6 THEN
              pc1(7 DOWNTO 0) <= dw;
            END IF;

          WHEN ROMC_19 =>
            IF phase = 6 THEN
              dc0(7 DOWNTO 0) <= dw;
            END IF;

          WHEN ROMC_1D =>
            IF phase = 6 THEN
              dc0 <= dc1;
              dc1 <= dc0;
            END IF;

          WHEN ROMC_1E =>
            IF phase = 2 THEN
              dr_l <= pc0(7 DOWNTO 0);
              dv_l <= '1';
            END IF;

          WHEN ROMC_1F =>
            IF phase = 2 THEN
              dr_l <= pc0(15 DOWNTO 8);
              dv_l <= '1';
            END IF;

          WHEN OTHERS =>
            NULL;
        END CASE;
      END IF;
    END IF;
  END PROCESS;

  dr <= dr_l;
  dv <= dv_l;

  ext_addr  <= ext_addr_l;
  ext_rd    <= ext_rd_l;
  ext_wr    <= ext_wr_l;
  ext_wdata <= ext_wdata_l;
  ext_req   <= ext_req_l;
  ext_class <= ext_class_l;

  io_addr  <= port_l;
  io_rd    <= io_rd_l;
  io_wr    <= io_wr_l;
  io_wdata <= io_wdata_l;
  int_ack  <= int_ack_l;

  pc0o <= pc0;
  pc1o <= pc1;
  dc0o <= dc0;

END ARCHITECTURE rtl;
