-- pkg_i2s_axis.vhd
library ieee;
use ieee.std_logic_1164.all;

package pkg_i2s_axis is
  component i2s_axis is
    port(
      mclk          : in  std_logic;
      rst_n         : in  std_logic;

      sclk          : out std_logic;
      lrck          : out std_logic;
      sdata         : in  std_logic;

      m_axis_tdata  : out std_logic_vector(31 downto 0);
      m_axis_tvalid : out std_logic;
      m_axis_tready : in  std_logic;
      m_axis_tlast  : out std_logic;
      m_axis_tuser  : out std_logic
    );
  end component;

  component axis_i2s is
    port(
      mclk          : in  std_logic;
      rst_n         : in  std_logic;

      s_axis_tdata  : in  std_logic_vector(31 downto 0);
      s_axis_tvalid : in  std_logic;
      s_axis_tready : out std_logic;
      s_axis_tlast  : in  std_logic;
      s_axis_tuser  : in  std_logic;

      sclk          : out std_logic;
      lrck          : out std_logic;
      sdata         : out std_logic
    );
  end component;
end package;