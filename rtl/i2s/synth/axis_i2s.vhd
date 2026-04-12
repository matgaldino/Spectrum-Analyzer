library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- -------------------------------------------------------
-- axis_i2s: converts AXI Stream stereo samples to serial I2S
--
-- Clocks generated internally from MCLK:
--   SCLK = MCLK / 8  = 2.8224 MHz
--   LRCK = SCLK / 64 = 44.1 kHz
--
-- AXI Stream input:
--   tdata  [31:0] : 24-bit sample left-aligned in [31:8]
--   tvalid        : sample is valid
--   tready        : module can accept one sample
--   tlast         : expected '1' on Right channel
--   tuser         : expected '1' on Left channel
--
-- I2S output format (Philips):
--   - data changes on SCLK falling edge
--   - receiver samples on SCLK rising edge
--   - one-bit delay after LRCK transition
--   - Left when LRCK = '0', Right when LRCK = '1'
-- -------------------------------------------------------
entity axis_i2s is
  generic(
    G_USE_EXT_CLK : boolean := false
  );
  port(
    -- Clock domain: mclk (22.5792 MHz)
    mclk          : in  std_logic;
    rst_n         : in  std_logic;  -- active-low reset

    -- AXI Stream Slave
    s_axis_tdata  : in  std_logic_vector(31 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in  std_logic;
    s_axis_tuser  : in  std_logic;

    -- I2S interface -> CS4344 (DAC)
    sclk          : out std_logic;
    lrck          : out std_logic;
    sdata         : out std_logic;

    -- Optional shared external clocks (used when G_USE_EXT_CLK=true)
    ext_sclk      : in  std_logic := '0';
    ext_lrck      : in  std_logic := '0'
  );
end entity;

architecture rtl of axis_i2s is

  -- -------------------------------------------------------
  -- SCLK generation: MCLK / 8
  -- -------------------------------------------------------
  signal mclk_cnt     : unsigned(2 downto 0) := (others => '0');
  signal sclk_gen_i   : std_logic := '1';
  signal lrck_gen_i   : std_logic := '1';
  signal sclk_src     : std_logic := '1';
  signal lrck_src     : std_logic := '1';
  signal sclk_prev    : std_logic := '1';
  signal sclk_rise    : std_logic := '0';
  signal sclk_fall    : std_logic := '0';
  signal sclk_rise_int: std_logic;
  signal sclk_fall_int: std_logic;
  signal sclk_rise_ext: std_logic := '0';
  signal sclk_fall_ext: std_logic := '0';

  -- -------------------------------------------------------
  -- LRCK generation: SCLK / 64 (32-bit frames per channel)
  -- -------------------------------------------------------
  signal sclk_cnt_gen  : unsigned(4 downto 0) := (others => '0');
  signal lrck_d1       : std_logic := '1';

  -- -------------------------------------------------------
  -- AXIS buffering (single sample per channel)
  -- -------------------------------------------------------
  signal left_buf      : std_logic_vector(23 downto 0) := (others => '0');
  signal right_buf     : std_logic_vector(23 downto 0) := (others => '0');
  signal left_pending  : std_logic := '0';
  signal right_pending : std_logic := '0';
  signal tready_r      : std_logic := '1';

  -- -------------------------------------------------------
  -- I2S serializer
  -- tx_bit_cnt: 0 = I2S delay slot, 1..24 = audio bits, 25..31 = padding
  -- -------------------------------------------------------
  signal tx_shift   : std_logic_vector(23 downto 0) := (others => '0');
  signal tx_bit_cnt : unsigned(4 downto 0) := (others => '0');
  signal sdata_i    : std_logic := '0';

begin

  -- Accepts one sample when the corresponding channel buffer is free.
  tready_r <= '1' when (s_axis_tuser = '1' and left_pending = '0') or
                       (s_axis_tuser = '0' and right_pending = '0')
             else '0';

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

  -- -------------------------------------------------------
  -- LRCK generation from SCLK
  -- -------------------------------------------------------
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        sclk_cnt_gen <= (others => '0');
        lrck_gen_i   <= '1';
      elsif sclk_rise = '1' then
        if not G_USE_EXT_CLK then
          if sclk_cnt_gen = 31 then
            sclk_cnt_gen <= (others => '0');
            lrck_gen_i   <= not lrck_gen_i;
          else
            sclk_cnt_gen <= sclk_cnt_gen + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- AXIS input capture and I2S serialization
  -- -------------------------------------------------------
  process(mclk)
    variable ext_lrck_changed : boolean;
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        left_buf        <= (others => '0');
        right_buf       <= (others => '0');
        left_pending    <= '0';
        right_pending   <= '0';
        tx_shift        <= (others => '0');
        tx_bit_cnt      <= (others => '0');
        lrck_d1         <= '1';
        sdata_i         <= '0';
      else
        ext_lrck_changed := (G_USE_EXT_CLK and (lrck_src /= lrck_d1));

        -- Tracks LRCK every mclk cycle to avoid missing external transitions.
        lrck_d1 <= lrck_src;

        -- AXIS handshake
        if s_axis_tvalid = '1' and tready_r = '1' then
          if s_axis_tuser = '1' then
            left_buf      <= s_axis_tdata(31 downto 8);
            left_pending  <= '1';

            assert s_axis_tlast = '0'
              report "axis_i2s: expected tlast='0' on Left sample"
              severity warning;
          else
            right_buf      <= s_axis_tdata(31 downto 8);
            right_pending  <= '1';

            assert s_axis_tlast = '1'
              report "axis_i2s: expected tlast='1' on Right sample"
              severity warning;
          end if;
        end if;

        -- External mode frame start (shared clock): react on LRCK transition
        -- detected against the previous mclk sample.
        if ext_lrck_changed then
          tx_bit_cnt <= (others => '0');

          if lrck_src = '0' then
            -- New channel is Left
            if left_pending = '1' then
              tx_shift     <= left_buf;
              left_pending <= '0';
            else
              tx_shift <= (others => '0');
            end if;
          else
            -- New channel is Right
            if right_pending = '1' then
              tx_shift      <= right_buf;
              right_pending <= '0';
            else
              tx_shift <= (others => '0');
            end if;
          end if;
        end if;

        -- Keeps tx_bit_cnt aligned to the same frame boundaries used by i2s_axis.
        if sclk_rise = '1' then
          if (not G_USE_EXT_CLK and sclk_cnt_gen = 31) then
            tx_bit_cnt <= (others => '0');

            -- Internal mode: at rollover, LRCK toggles after this edge,
            -- so the new channel is not lrck_src.
            if (not lrck_src) = '0' then
              -- New channel is Left
              if left_pending = '1' then
                tx_shift     <= left_buf;
                left_pending <= '0';
              else
                tx_shift <= (others => '0');
              end if;
            else
              -- New channel is Right
              if right_pending = '1' then
                tx_shift      <= right_buf;
                right_pending <= '0';
              else
                tx_shift <= (others => '0');
              end if;
            end if;
          elsif (not ext_lrck_changed) and tx_bit_cnt < 31 then
            tx_bit_cnt <= tx_bit_cnt + 1;
          end if;
        end if;

        -- Philips I2S transmit timing: after LRCK transition there is one
        -- SCLK-cycle delay slot, then 24 audio bits MSB-first.
        -- SDATA is updated on SCLK falling edge and sampled on rising edge.
        if sclk_fall = '1' then
          if tx_bit_cnt = 0 then
            sdata_i <= '0';
          elsif tx_bit_cnt <= 24 then
            sdata_i  <= tx_shift(23);
            tx_shift <= tx_shift(22 downto 0) & '0';
          else
            sdata_i <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- Outputs
  -- -------------------------------------------------------
  s_axis_tready <= tready_r;
  sclk          <= sclk_src;
  lrck          <= lrck_src;
  sdata         <= sdata_i;

end architecture;
