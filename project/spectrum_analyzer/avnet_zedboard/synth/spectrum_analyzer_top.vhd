library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg_led_blink.all;
use work.pkg_vga_axis_controller.all;
use work.pkg_i2s_axis.all; 

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
        vga_b : out std_logic_vector(3 downto 0);
        -- I2S ADC (CS5343) — PMOD JA bottom row
        i2s_adc_mclk  : out std_logic;
        i2s_adc_sclk  : out std_logic;
        i2s_adc_lrck  : out std_logic;
        i2s_adc_sdata : in  std_logic;
        -- I2S DAC (CS4344) — PMOD JA top row (loopback test)
        i2s_dac_mclk  : out std_logic;
        i2s_dac_sclk  : out std_logic;
        i2s_dac_lrck  : out std_logic;
        i2s_dac_sdata : out std_logic
      );
end entity;

architecture top_arch of spectrum_analyzer_top is
  signal aclk_0      : std_logic;
  signal aresetn_0   : std_logic_vector(0 downto 0);
  signal clk_out1_0  : std_logic;

  -- AXI Stream do DMA → VGA
  signal mm2s_tdata  : std_logic_vector(31 downto 0);
  signal mm2s_tkeep  : std_logic_vector(3 downto 0);
  signal mm2s_tvalid : std_logic;
  signal mm2s_tready : std_logic;
  signal mm2s_tlast  : std_logic;

  -- I2S RX raw (32 bits, um canal por vez)
  signal i2s_rx_tdata  : std_logic_vector(31 downto 0);
  signal i2s_rx_tvalid : std_logic;
  signal i2s_rx_tready : std_logic;
  signal i2s_rx_tlast  : std_logic;
  signal i2s_rx_tuser  : std_logic;

  -- I2S RX adaptado (64 bits, par L+R) → FIFO no BD
  signal s_axis_0_tdata  : std_logic_vector(63 downto 0);
  signal s_axis_0_tvalid : std_logic;
  signal s_axis_0_tready : std_logic;
  signal s_axis_0_tlast  : std_logic;

  -- Registrador interno do adaptador L+R
  signal left_sample : std_logic_vector(31 downto 0) := (others => '0');
  signal pair_valid  : std_logic := '0';

  -- Shared I2S clocks
  signal i2s_sh_sclk : std_logic;
  signal i2s_sh_lrck : std_logic;

  -- tuser generation (SOF)
  constant H_VISIBLE : integer := 1024;
  constant V_VISIBLE : integer := 768;
  signal pixel_x   : integer range 0 to H_VISIBLE-1 := 0;
  signal line_y    : integer range 0 to V_VISIBLE-1 := 0;
  signal tuser_gen : std_logic;

begin

  bd_inst: entity work.design_1_wrapper
    port map(
      DDR_addr(14 downto 0)     => DDR_addr(14 downto 0),
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
      aresetn_0                 => aresetn_0,
      reset_rtl_0               => '0',
      clk_out1_0                => clk_out1_0,
      M_AXIS_MM2S_0_tdata       => mm2s_tdata,
      M_AXIS_MM2S_0_tkeep       => mm2s_tkeep,
      M_AXIS_MM2S_0_tvalid      => mm2s_tvalid,
      M_AXIS_MM2S_0_tready      => mm2s_tready,
      M_AXIS_MM2S_0_tlast       => mm2s_tlast,
      S_AXIS_0_tdata            => s_axis_0_tdata,
      S_AXIS_0_tvalid           => s_axis_0_tvalid,
      S_AXIS_0_tready           => s_axis_0_tready,
      S_AXIS_0_tlast            => s_axis_0_tlast
    );

  simple_led_example: led_blink
    port map(
      clk => aclk_0,
      rsn => aresetn_0(0),
      led => led
    );

  -- -------------------------------------------------------
  -- Tuser generation (SOF)
  -- -------------------------------------------------------
  process(aclk_0)
  begin
    if rising_edge(aclk_0) then
      if aresetn_0(0) = '0' then
        pixel_x <= 0;
        line_y  <= 0;
      elsif mm2s_tvalid = '1' and mm2s_tready = '1' then
        if mm2s_tlast = '1' then
          pixel_x <= 0;
          if line_y = V_VISIBLE-1 then
            line_y <= 0;
          else
            line_y <= line_y + 1;
          end if;
        else
          if pixel_x = H_VISIBLE-1 then
            pixel_x <= 0;
            if line_y = V_VISIBLE-1 then
              line_y <= 0;
            else
              line_y <= line_y + 1;
            end if;
          else
            pixel_x <= pixel_x + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  tuser_gen <= '1' when (pixel_x = 0 and line_y = 0 and
                         mm2s_tvalid = '1' and mm2s_tready = '1') else '0';

  -- -------------------------------------------------------
  -- VGA controller
  -- -------------------------------------------------------
  vga_inst: vga_axis_controller
    port map(
      clk_pix       => aclk_0,
      rst_n         => aresetn_0(0),
      test_mode     => '0',
      s_axis_tdata  => mm2s_tdata(11 downto 0),
      s_axis_tvalid => mm2s_tvalid,
      s_axis_tready => mm2s_tready,
      s_axis_tlast  => mm2s_tlast,
      s_axis_tuser  => tuser_gen,
      hsync         => hsync,
      vsync         => vsync,
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b
    );

  -- -------------------------------------------------------
  -- I2S clock master
  -- -------------------------------------------------------
  i2s_clk: i2s_clkgen
    port map(
      mclk  => clk_out1_0,
      rst_n => aresetn_0(0),
      sclk  => i2s_sh_sclk,
      lrck  => i2s_sh_lrck
    );

  -- -------------------------------------------------------
  -- I2S RX (ADC → AXI Stream 32 bits)
  -- -------------------------------------------------------
  i2s_rx: i2s_axis
    generic map( G_USE_EXT_CLK => true )
    port map(
      mclk          => clk_out1_0,
      rst_n         => aresetn_0(0),
      sclk          => open,
      lrck          => open,
      sdata         => i2s_adc_sdata,
      ext_sclk      => i2s_sh_sclk,
      ext_lrck      => i2s_sh_lrck,
      m_axis_tdata  => i2s_rx_tdata,
      m_axis_tvalid => i2s_rx_tvalid,
      m_axis_tready => i2s_rx_tready,
      m_axis_tlast  => i2s_rx_tlast,
      m_axis_tuser  => i2s_rx_tuser
    );

  -- -------------------------------------------------------
  -- I2S TX (loopback DAC ← AXI Stream 32 bits)
  -- -------------------------------------------------------
  i2s_tx: axis_i2s
    generic map( G_USE_EXT_CLK => true )
    port map(
      mclk          => clk_out1_0,
      rst_n         => aresetn_0(0),
      s_axis_tdata  => i2s_rx_tdata,
      s_axis_tvalid => i2s_rx_tvalid,
      s_axis_tready => open,
      s_axis_tlast  => i2s_rx_tlast,
      s_axis_tuser  => i2s_rx_tuser,
      sclk          => open,
      lrck          => open,
      ext_sclk      => i2s_sh_sclk,
      ext_lrck      => i2s_sh_lrck,
      sdata         => i2s_dac_sdata
    );

  -- -------------------------------------------------------
  -- Adaptador L+R: 2x32 bits → 64 bits para a FIFO
  -- tdata[63:32] = Left, tdata[31:0] = Right
  -- Roda no domínio clk_out1_0 (22.5792 MHz)
  -- -------------------------------------------------------
  process(clk_out1_0)
  begin
    if rising_edge(clk_out1_0) then
      if aresetn_0(0) = '0' then
        left_sample <= (others => '0');
        pair_valid  <= '0';
        s_axis_0_tdata <= (others => '0');
      else
        if pair_valid = '1' and s_axis_0_tready = '1' then
          pair_valid <= '0';
          s_axis_0_tlast <= '0';
        end if;

        if i2s_rx_tvalid = '1' and i2s_rx_tready = '1' then
          if i2s_rx_tuser = '1' then
            left_sample <= i2s_rx_tdata;
          elsif i2s_rx_tlast = '1' then
            s_axis_0_tdata(63 downto 32) <= left_sample;
            s_axis_0_tdata(31 downto  0) <= i2s_rx_tdata;
            pair_valid <= '1';
            s_axis_0_tlast <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  s_axis_0_tvalid <= pair_valid;
  i2s_rx_tready   <= '1';

  -- -------------------------------------------------------
  -- Distribuição de clocks para os codecs
  -- -------------------------------------------------------
  i2s_adc_mclk <= clk_out1_0;
  i2s_dac_mclk <= clk_out1_0;
  i2s_adc_sclk <= i2s_sh_sclk;
  i2s_dac_sclk <= i2s_sh_sclk;
  i2s_adc_lrck <= i2s_sh_lrck;
  i2s_dac_lrck <= i2s_sh_lrck;

end architecture;