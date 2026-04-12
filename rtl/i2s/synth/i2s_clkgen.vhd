library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -------------------------------------------------------
-- i2s_clkgen: shared I2S clock generator from MCLK
--
-- Generates:
--   SCLK = MCLK / 8
--   LRCK = SCLK / 64
-- -------------------------------------------------------
entity i2s_clkgen is
  port(
    mclk : in  std_logic;
    rst_n: in  std_logic;
    sclk : out std_logic;
    lrck : out std_logic
  );
end entity;

architecture rtl of i2s_clkgen is
  signal mclk_cnt : unsigned(2 downto 0) := (others => '0');
  signal sclk_i   : std_logic := '1';
  signal sclk_cnt : unsigned(4 downto 0) := (others => '0');
  signal lrck_i   : std_logic := '1';
begin

  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        mclk_cnt <= (others => '0');
        sclk_i   <= '1';
      else
        if mclk_cnt = 7 then
          mclk_cnt <= (others => '0');
          sclk_i   <= '1';
        else
          mclk_cnt <= mclk_cnt + 1;
          if mclk_cnt = 3 then
            sclk_i <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        sclk_cnt <= (others => '0');
        lrck_i   <= '1';
      else
        if mclk_cnt = 7 then
          if sclk_cnt = 31 then
            sclk_cnt <= (others => '0');
            lrck_i   <= not lrck_i;
          else
            sclk_cnt <= sclk_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  sclk <= sclk_i;
  lrck <= lrck_i;

end architecture;
