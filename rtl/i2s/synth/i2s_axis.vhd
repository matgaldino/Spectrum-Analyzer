library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -------------------------------------------------------
-- i2s_axis: converts serial I2S (CS5343 ADC) to AXI Stream
--
-- Clocks generated internally from MCLK:
--   SCLK = MCLK / 8  = 2.8224 MHz
--   LRCK = SCLK / 64 = 44.1 kHz
--
-- I2S format (Philips standard):
--   - MSB first
--   - Data changes on SCLK falling edge
--   - Data is sampled on SCLK rising edge
--   - MSB appears 1 SCLK after LRCK transition
--   - Left when LRCK = '0'
--   - Right when LRCK = '1'
--   - 24 audio bits per channel, 32 bits per channel frame
--
-- AXI Stream output:
--   tdata  [31:0] : 24-bit sample left-aligned in [31:8]
--   tvalid        : '1' when sample is ready
--   tready        : consumer backpressure
--   tlast         : '1' on Right channel (end of stereo pair)
--   tuser         : '1' on Left channel  (start of stereo pair)
-- -------------------------------------------------------
entity i2s_axis is
  generic(
    G_USE_EXT_CLK : boolean := false
  );
  port(
    -- Clock domain: mclk (22.5792 MHz)
    mclk          : in  std_logic;
    rst_n         : in  std_logic;  -- active-low reset

    -- I2S interface -> CS5343 (ADC)
    sclk          : out std_logic;  -- bit clock  (MCLK/8)
    lrck          : out std_logic;  -- word clock (SCLK/64)
    sdata         : in  std_logic;  -- serial data from ADC

    -- Optional shared external clocks (used when G_USE_EXT_CLK=true)
    ext_sclk      : in  std_logic := '0';
    ext_lrck      : in  std_logic := '0';

    -- AXI Stream Master
    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;
    m_axis_tuser  : out std_logic
  );
end entity;

architecture rtl of i2s_axis is

  -- -------------------------------------------------------
  -- SCLK generation: MCLK / 8
  -- Counter 0..7, SCLK='1' during first 4 cycles
  -- SCLK rising edge: transition from cnt=7 to cnt=0
  -- -------------------------------------------------------
  signal mclk_cnt     : unsigned(2 downto 0) := (others => '0');
  signal sclk_gen_i   : std_logic := '1';
  signal lrck_gen_i   : std_logic := '0';
  signal sclk_src     : std_logic := '1';
  signal lrck_src     : std_logic := '0';
  signal sclk_prev    : std_logic := '1';
  signal sclk_rise    : std_logic := '0';
  signal sclk_fall    : std_logic := '0';
  signal sclk_rise_int: std_logic;
  signal sclk_fall_int: std_logic;
  signal sclk_rise_ext: std_logic := '0';
  signal sclk_fall_ext: std_logic := '0';
  signal sclk_fall_d  : std_logic := '0';

  -- -------------------------------------------------------
  -- LRCK generation: SCLK / 64
  -- LRCK half-period counter in SCLK cycles (0..31)
  -- LRCK toggles every 32 SCLK cycles (32 bits per channel)
  -- -------------------------------------------------------
  signal sclk_cnt_gen  : unsigned(4 downto 0) := (others => '0');
  signal lrck_d1       : std_logic := '0';

  -- -------------------------------------------------------
  -- Serial reception
  -- Captures 24 bits per channel frame
  -- bit_cnt: 0..23 = audio bits, 24..31 = padding bits (ignored)
  -- -------------------------------------------------------
  signal bit_cnt   : unsigned(4 downto 0) := (others => '0');
  signal shift_reg : std_logic_vector(23 downto 0) := (others => '0');
  signal sdata_d   : std_logic := '0';

  -- -------------------------------------------------------
  -- AXI Stream output
  -- -------------------------------------------------------
  signal tdata_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal tvalid_r  : std_logic := '0';
  signal tlast_r   : std_logic := '0';
  signal tuser_r   : std_logic := '0';
  signal is_right  : std_logic := '0';  -- '0'=Left, '1'=Right

begin

  -- -------------------------------------------------------
  -- SCLK generation from MCLK
  -- -------------------------------------------------------
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        mclk_cnt   <= (others => '0');
        sclk_gen_i <= '1';
      else
        if G_USE_EXT_CLK then
          mclk_cnt   <= (others => '0');
          sclk_gen_i <= '1';
        else
          if mclk_cnt = 7 then
            mclk_cnt <= (others => '0');
            sclk_gen_i <= '1';
          else
            mclk_cnt <= mclk_cnt + 1;
            if mclk_cnt = 3 then
              sclk_gen_i <= '0';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Select shared or internal clocks
  sclk_src <= ext_sclk when G_USE_EXT_CLK else sclk_gen_i;
  lrck_src <= ext_lrck when G_USE_EXT_CLK else lrck_gen_i;

  -- SCLK edge detection in mclk domain (for external clock mode)
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        sclk_prev <= '1';
        sclk_rise_ext <= '0';
        sclk_fall_ext <= '0';
      else
        sclk_rise_ext <= '0';
        sclk_fall_ext <= '0';
        if sclk_prev = '0' and sclk_src = '1' then
          sclk_rise_ext <= '1';
        elsif sclk_prev = '1' and sclk_src = '0' then
          sclk_fall_ext <= '1';
        end if;
        sclk_prev <= sclk_src;
      end if;
    end if;
  end process;

  sclk_rise_int <= '1' when mclk_cnt = 7 else '0';
  sclk_fall_int <= '1' when mclk_cnt = 3 else '0';
  sclk_rise <= sclk_rise_ext when G_USE_EXT_CLK else sclk_rise_int;
  sclk_fall <= sclk_fall_ext when G_USE_EXT_CLK else sclk_fall_int;

  -- Diagnostic margin patch: pre-samples SDATA on SCLK falling edge,
  -- then uses the registered value on SCLK rising edge.
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        sdata_d <= '0';
        sclk_fall_d <= '0';
      else
        -- Samples one mclk after SCLK falling edge to avoid sampling
        -- exactly at the external transition instant.
        sclk_fall_d <= sclk_fall;
        if sclk_fall_d = '1' then
          sdata_d <= sdata;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- LRCK generation from SCLK
  -- Counts SCLK rising edges, toggles LRCK every 32
  -- -------------------------------------------------------
  process(mclk)
  begin
    if rising_edge(mclk) then
        if rst_n = '0' then
          sclk_cnt_gen  <= (others => '0');
          lrck_gen_i    <= '0';
      else
        if not G_USE_EXT_CLK then
          if mclk_cnt = 7 then
            if sclk_cnt_gen = 31 then
              sclk_cnt_gen <= (others => '0');
              lrck_gen_i   <= not lrck_gen_i;
            else
              sclk_cnt_gen <= sclk_cnt_gen + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- I2S bit reception
  -- In this design LRCK toggles on SCLK rising edge and the ADC
  -- drives data on SCLK falling edge. Following Philips I2S,
  -- the first rising edge after LRCK transition is a delay slot
  -- and the MSB is sampled on the next rising edge.
  -- bit_cnt = 0      -> delay slot (ignored)
  -- bit_cnt = 1..24  -> audio bits [23..0] (MSB first)
  -- bit_cnt = 25..31 -> padding bits (ignored)
  -- -------------------------------------------------------
  process(mclk)
    variable ext_lrck_changed : boolean;
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        bit_cnt   <= (others => '0');
        shift_reg <= (others => '0');
        is_right  <= '0';
        lrck_d1   <= '0';
        tvalid_r  <= '0';
        tlast_r   <= '0';
        tuser_r   <= '0';
        tdata_r   <= (others => '0');
      else
        ext_lrck_changed := (G_USE_EXT_CLK and (lrck_src /= lrck_d1));

        -- Tracks LRCK every mclk cycle to avoid missing external transitions.
        lrck_d1 <= lrck_src;

        -- Clears tvalid after handshake
        if tvalid_r = '1' and m_axis_tready = '1' then
          tvalid_r <= '0';
          tlast_r  <= '0';
          tuser_r  <= '0';
        end if;

        if ext_lrck_changed then
          bit_cnt  <= (others => '0');
          is_right <= lrck_src;
        end if;

        -- Captures bits on SCLK rising edge
        if sclk_rise = '1' then
          -- Internal mode: frame start is the local LRCK rollover event.
          -- External mode: frame start is handled by ext_lrck_changed.
          if (not G_USE_EXT_CLK and sclk_cnt_gen = 31) then
            bit_cnt <= (others => '0');
            is_right <= not lrck_src;
          elsif (not ext_lrck_changed) and bit_cnt < 31 then
            bit_cnt <= bit_cnt + 1;
          end if;

          -- bit_cnt = 1..24: captures audio bits (MSB first)
          if bit_cnt >= 1 and bit_cnt <= 24 then
            shift_reg <= shift_reg(22 downto 0) & sdata_d;
          end if;

          -- bit_cnt = 24: last audio bit captured -> publishes sample
          if bit_cnt = 24 then
            tdata_r  <= shift_reg(22 downto 0) & sdata_d & x"00";  -- left-aligned
            tvalid_r <= '1';
            tlast_r  <= is_right;   -- '1' on Right channel (end of stereo pair)
            tuser_r  <= not is_right;  -- '1' on Left channel (start of stereo pair)
          end if;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- Outputs
  -- -------------------------------------------------------
  sclk          <= sclk_src;
  lrck          <= lrck_src;
  m_axis_tdata  <= tdata_r;
  m_axis_tvalid <= tvalid_r;
  m_axis_tlast  <= tlast_r;
  m_axis_tuser  <= tuser_r;

end architecture;