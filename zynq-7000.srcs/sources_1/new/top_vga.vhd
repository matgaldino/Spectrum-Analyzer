library ieee;
use ieee.std_logic_1164.all;

entity top_vga is
  port(
    clk100  : in  std_logic;  -- horloge 100 MHz de la ZedBoard (PL)
    hsync   : out std_logic;
    vsync   : out std_logic;
    vga_r   : out std_logic_vector(3 downto 0);
    vga_g   : out std_logic_vector(3 downto 0);
    vga_b   : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of top_vga is
  signal clk_pix : std_logic;
begin

   u_clk : entity work.clk_wiz_1
  port map(
    clk_in1  => clk100,
    clk_out1 => clk_pix,
    reset    => '0'     -- reset inactif
    -- locked : tu peux le laisser non connecté si tu ne l'utilises pas
  );

  -- VGA test pattern
  u_vga : entity work.vga_test_1024x768
    port map(
      clk_pix => clk_pix,
      rst_n   => '1',     -- reset désactivé
      hsync   => hsync,
      vsync   => vsync,
      vga_r   => vga_r,
      vga_g   => vga_g,
      vga_b   => vga_b
    );

end architecture;