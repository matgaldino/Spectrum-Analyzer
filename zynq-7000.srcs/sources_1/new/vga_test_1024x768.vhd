library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vga_test_1024x768 is
  port(
    clk_pix  : in  std_logic;  -- 65 MHz
    rst_n    : in  std_logic;  -- reset actif bas
    hsync    : out std_logic;
    vsync    : out std_logic;
    vga_r    : out std_logic_vector(3 downto 0);
    vga_g    : out std_logic_vector(3 downto 0);
    vga_b    : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of vga_test_1024x768 is

  -- 1024x768@60 timings (VESA XGA)
  -- Horizontal: 1024 visible, 24 front, 136 sync, 160 back => 1344 total
  constant H_VISIBLE : integer := 1024;
  constant H_FP      : integer := 24;
  constant H_SYNC    : integer := 136;
  constant H_BP      : integer := 160;
  constant H_TOTAL   : integer := H_VISIBLE + H_FP + H_SYNC + H_BP; -- 1344

  -- Vertical: 768 visible, 3 front, 6 sync, 29 back => 806 total
  constant V_VISIBLE : integer := 768;
  constant V_FP      : integer := 3;
  constant V_SYNC    : integer := 6;
  constant V_BP      : integer := 29;
  constant V_TOTAL   : integer := V_VISIBLE + V_FP + V_SYNC + V_BP; -- 806

  signal h_cnt : integer range 0 to H_TOTAL-1 := 0;
  signal v_cnt : integer range 0 to V_TOTAL-1 := 0;

  signal active_video : std_logic;
  signal r, g, b : std_logic_vector(3 downto 0);

begin

  -- Counters
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if rst_n = '0' then
        h_cnt <= 0;
        v_cnt <= 0;
      else
        if h_cnt = H_TOTAL-1 then
          h_cnt <= 0;
          if v_cnt = V_TOTAL-1 then
            v_cnt <= 0;
          else
            v_cnt <= v_cnt + 1;
          end if;
        else
          h_cnt <= h_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  -- Sync signals (active low)
  hsync <= '0' when (h_cnt >= (H_VISIBLE + H_FP) and h_cnt < (H_VISIBLE + H_FP + H_SYNC)) else '1';
  vsync <= '0' when (v_cnt >= (V_VISIBLE + V_FP) and v_cnt < (V_VISIBLE + V_FP + V_SYNC)) else '1';

  -- Active video region
  active_video <= '1' when (h_cnt < H_VISIBLE and v_cnt < V_VISIBLE) else '0';

  -- Test pattern (8 vertical color bars)
  process(h_cnt, v_cnt, active_video)
    variable band : integer;
  begin
    r <= (others => '0');
    g <= (others => '0');
    b <= (others => '0');

    if active_video = '1' then
      -- 1024 / 8 = 128 pixels par bande
      band := h_cnt / 128;

      case band is
        when 0 => r <= x"F"; g <= x"0"; b <= x"0"; -- Red
        when 1 => r <= x"0"; g <= x"F"; b <= x"0"; -- Green
        when 2 => r <= x"0"; g <= x"0"; b <= x"F"; -- Blue
        when 3 => r <= x"F"; g <= x"F"; b <= x"0"; -- Yellow
        when 4 => r <= x"0"; g <= x"F"; b <= x"F"; -- Cyan
        when 5 => r <= x"F"; g <= x"0"; b <= x"F"; -- Magenta
        when 6 => r <= x"F"; g <= x"F"; b <= x"F"; -- White
        when others =>
          -- Checkerboard (bande 7)
          if ((h_cnt / 16) mod 2) = ((v_cnt / 16) mod 2) then
            r <= x"2"; g <= x"2"; b <= x"2";
          else
            r <= x"E"; g <= x"E"; b <= x"E";
          end if;
      end case;
    end if;
  end process;

  vga_r <= r;
  vga_g <= g;
  vga_b <= b;

end architecture;