--------------------------------------------------------------------------------
-- VideoBrain UV201 shared types
--------------------------------------------------------------------------------
-- Kept separate from uv202_pack so renderer/fetcher/FIFO-specific structures
-- do not leak into the UV202 timing/bus package.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

PACKAGE uv201_pack IS

  -- One UV201 FIFO entry is either:
  --   * a background/gap pixel count, or
  --   * one fetched byte (8 sprite pixels) plus the object's 5-bit colour.
  --
  -- The five colour bits are the two intensity bits from 0820-082F plus the
  -- three colour bits from 0810-081F, matching the 32-entry logical palette
  -- used by the UV201 before FINAL MODIFIER XOR is applied.
  TYPE uv201_fifo_entry_t IS RECORD
    is_gap  : std_logic;
    payload : uv8;
    color   : std_logic_vector(4 DOWNTO 0);
  END RECORD;

  CONSTANT UV201_FIFO_ENTRY_ZERO : uv201_fifo_entry_t := (
    is_gap  => '0',
    payload => (OTHERS => '0'),
    color   => (OTHERS => '0')
    );

  CONSTANT UV201_FIFO_DEPTH : natural := 10;

END PACKAGE uv201_pack;

PACKAGE BODY uv201_pack IS
END PACKAGE BODY uv201_pack;
