-- Copyright Raphaël Bresson 2021
-- Reference file for bd wrapper: build/vivado/build/hdl/<bd_name>_wrapper.vhd or
-- build/vivado/build/hdl/<bd_name>_wrapper.v (depending which language is preferred in Makefile and after generating it:
-- make build/vivado/import_synth.done
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_led_blink.all;
use work.pkg_vga_axis_controller.all;

entity spectrum_analyzer_top is
port( DDR_addr : inout STD_LOGIC_VECTOR ( 14 downto 0 );
        DDR_ba : inout STD_LOGIC_VECTOR ( 2 downto 0 );
        DDR_cas_n : inout STD_LOGIC;
        DDR_ck_n : inout STD_LOGIC;
        DDR_ck_p : inout STD_LOGIC;
        DDR_cke : inout STD_LOGIC;
        DDR_cs_n : inout STD_LOGIC;
        DDR_dm : inout STD_LOGIC_VECTOR ( 3 downto 0 );
        DDR_dq : inout STD_LOGIC_VECTOR ( 31 downto 0 );
        DDR_dqs_n : inout STD_LOGIC_VECTOR ( 3 downto 0 );
        DDR_dqs_p : inout STD_LOGIC_VECTOR ( 3 downto 0 );
        DDR_odt : inout STD_LOGIC;
        DDR_ras_n : inout STD_LOGIC;
        DDR_reset_n : inout STD_LOGIC;
        DDR_we_n : inout STD_LOGIC;
        FIXED_IO_ddr_vrn : inout STD_LOGIC;
        FIXED_IO_ddr_vrp : inout STD_LOGIC;
        FIXED_IO_mio : inout STD_LOGIC_VECTOR ( 53 downto 0 );
        FIXED_IO_ps_clk : inout STD_LOGIC;
        FIXED_IO_ps_porb : inout STD_LOGIC;
        FIXED_IO_ps_srstb : inout STD_LOGIC;
        led   : out std_logic_vector(3 downto 0);
        -- VGA
        hsync : out std_logic;
        vsync : out std_logic;
        vga_r : out std_logic_vector(3 downto 0);
        vga_g : out std_logic_vector(3 downto 0);
        vga_b : out std_logic_vector(3 downto 0)
      );
end entity;

architecture top_arch of spectrum_analyzer_top is
  signal aclk_0      : std_logic;
  signal aresetn_0   : std_logic_vector(0 downto 0);
begin

  bd_inst: entity work.design_1_wrapper
    port map( DDR_addr(14 downto 0)     => DDR_addr(14 downto 0),
              DDR_ba(2 downto 0)        => DDR_ba(2 downto 0),
              DDR_cas_n                 => DDR_cas_n,
              DDR_ck_n                  => DDR_ck_n,
              DDR_ck_p                  => DDR_ck_p,
              DDR_cke                   => DDR_cke,
              DDR_cs_n                  => DDR_cs_n,
              DDR_dm(3 downto 0)        => DDR_dm(3 downto 0),
              DDR_dq(31 downto 0)       => DDR_dq(31 downto 0),
              DDR_dqs_n(3 downto 0)     => DDR_dqs_n(3 downto 0),
              DDR_dqs_p(3 downto 0)     => DDR_dqs_p(3 downto 0),
              DDR_odt                   => DDR_odt,
              DDR_ras_n                 => DDR_ras_n,
              DDR_reset_n               => DDR_reset_n,
              DDR_we_n                  => DDR_we_n,
              FIXED_IO_ddr_vrn          => FIXED_IO_ddr_vrn,
              FIXED_IO_ddr_vrp          => FIXED_IO_ddr_vrp,
              FIXED_IO_mio(53 downto 0) => FIXED_IO_mio(53 downto 0),
              FIXED_IO_ps_clk           => FIXED_IO_ps_clk,
              FIXED_IO_ps_porb          => FIXED_IO_ps_porb,
              FIXED_IO_ps_srstb         => FIXED_IO_ps_srstb,
              aclk_0                    => aclk_0,
              aresetn_0                 => aresetn_0
            );

  simple_led_example: led_blink
    port map( clk => aclk_0,
              rsn => aresetn_0(0),
              led => led);

  -- Etapa 1: test_mode='1' fixo → barras de cor na tela
  vga_inst: vga_axis_controller
    port map( clk_pix       => aclk_0,
              rst_n         => aresetn_0(0),
              test_mode     => '1',
              s_axis_tdata  => (others => '0'),
              s_axis_tvalid => '0',
              s_axis_tready => open,
              s_axis_tlast  => '0',
              s_axis_tuser  => '0',
              hsync         => hsync,
              vsync         => vsync,
              vga_r         => vga_r,
              vga_g         => vga_g,
              vga_b         => vga_b);
end architecture;