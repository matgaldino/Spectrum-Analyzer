-- pkg_vga_axis_controller.vhd
library ieee;
use ieee.std_logic_1164.all;

package pkg_vga_axis_controller is
  component vga_axis_controller is
    port(
      clk_pix       : in  std_logic;
      rst_n         : in  std_logic;

      test_mode     : in  std_logic;

      s_axis_tdata  : in  std_logic_vector(11 downto 0);
      s_axis_tvalid : in  std_logic;
      s_axis_tready : out std_logic;
      s_axis_tlast  : in  std_logic;
      s_axis_tuser  : in  std_logic;

      hsync         : out std_logic;
      vsync         : out std_logic;
      vga_r         : out std_logic_vector(3 downto 0);
      vga_g         : out std_logic_vector(3 downto 0);
      vga_b         : out std_logic_vector(3 downto 0)
    );
  end component;
end package;