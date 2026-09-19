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

    pc0o      : OUT uv16;
    pc1o      : OUT uv16;
    dc0o      : OUT uv16
    );
END ENTITY f8_busif;

ARCHITECTURE rtl OF f8_busif IS

  SIGNAL dc0, pc0, pc1 : uv16 := (OTHERS => '0');
  SIGNAL dr_l : uv8 := (OTHERS => '0');
  SIGNAL dv_l : std_logic := '0';

  SIGNAL ext_req_l   : std_logic := '0';
  SIGNAL ext_class_l : bus_access_t := ACC_NONE;
  SIGNAL ext_addr_l  : unsigned(13 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ext_rd_l    : std_logic := '0';
  SIGNAL ext_wr_l    : std_logic := '0';
  SIGNAL ext_wdata_l : uv8 := (OTHERS => '0');
  SIGNAL write_pending : std_logic := '0';

  FUNCTION classify(a : unsigned(13 DOWNTO 0); is_write : std_logic)
    RETURN bus_access_t IS
    VARIABLE a_eff : unsigned(13 DOWNTO 0) := cpu_addr_fold(a);
    VARIABLE result : bus_access_t;
  BEGIN
    IF a_eff < to_unsigned(ADDR_UV201_LO, 14) THEN
      result := ACC_NONE;
    ELSIF a_eff <= to_unsigned(ADDR_UV201_HI, 14) THEN
      result := ACC_UV201_WR WHEN is_write = '1' ELSE ACC_UV201_RD;
    ELSIF a_eff <= to_unsigned(ADDR_CART1_HI, 14) THEN
      result := ACC_CART_WR WHEN is_write = '1' ELSE ACC_CART_RD;
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
                WHEN ROMC_01 =>
                  pc0 <= pc0 + sext(dw, 16);
                WHEN ROMC_03 =>
                  pc0 <= pc0 + 1;
                WHEN ROMC_0C =>
                  pc0(7 DOWNTO 0) <= dw;
                WHEN ROMC_0E =>
                  dc0(7 DOWNTO 0) <= dw;
                WHEN ROMC_11 =>
                  dc0(15 DOWNTO 8) <= dw;
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

          -- Interrupt-vector ROMC states need the future F3853 path.
          WHEN ROMC_0F | ROMC_13 =>
            NULL;

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

  pc0o <= pc0;
  pc1o <= pc1;
  dc0o <= dc0;

END ARCHITECTURE rtl;
