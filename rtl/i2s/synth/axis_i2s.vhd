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
    sdata         : out std_logic
  );
end entity;

architecture rtl of axis_i2s is

  -- -------------------------------------------------------
  -- SCLK generation: MCLK / 8
  -- -------------------------------------------------------
  signal mclk_cnt  : unsigned(2 downto 0) := (others => '0');
  signal sclk_i    : std_logic := '1';
  signal sclk_rise : std_logic;
  signal sclk_fall : std_logic;

  -- -------------------------------------------------------
  -- LRCK generation: SCLK / 64 (32-bit frames per channel)
  -- -------------------------------------------------------
  signal sclk_cnt  : unsigned(4 downto 0) := (others => '0');
  -- Starts in '1' so the first LRCK toggle after reset opens a Left frame.
  signal lrck_i    : std_logic := '1';

  -- -------------------------------------------------------
  -- AXIS buffering (single sample per channel)
  -- -------------------------------------------------------
  signal left_buf      : std_logic_vector(23 downto 0) := (others => '0');
  signal right_buf     : std_logic_vector(23 downto 0) := (others => '0');
  signal left_pending  : std_logic := '0';
  signal right_pending : std_logic := '0';
  signal expect_right  : std_logic := '0';  -- '0' expects Left, '1' expects Right
  signal tready_r      : std_logic := '1';

  -- -------------------------------------------------------
  -- I2S serializer
  -- tx_bit_cnt: 0 = I2S delay slot, 1..24 = audio bits, 25..31 = padding
  -- -------------------------------------------------------
  signal tx_shift       : std_logic_vector(23 downto 0) := (others => '0');
  signal tx_bit_cnt     : unsigned(4 downto 0) := (others => '0');
  signal active_is_right: std_logic := '0';
  signal sdata_i        : std_logic := '0';

begin

  -- Accepts one sample at a time, alternating Left/Right order.
  tready_r <= '1' when (expect_right = '0' and left_pending = '0') or
                       (expect_right = '1' and right_pending = '0')
             else '0';

  -- -------------------------------------------------------
  -- SCLK generation from MCLK
  -- -------------------------------------------------------
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

  sclk_rise <= '1' when mclk_cnt = 7 else '0';
  sclk_fall <= '1' when mclk_cnt = 3 else '0';

  -- -------------------------------------------------------
  -- LRCK generation from SCLK
  -- -------------------------------------------------------
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        sclk_cnt <= (others => '0');
        lrck_i   <= '1';
      elsif sclk_rise = '1' then
        if sclk_cnt = 31 then
          sclk_cnt <= (others => '0');
          lrck_i   <= not lrck_i;
        else
          sclk_cnt <= sclk_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- AXIS input capture and I2S serialization
  -- -------------------------------------------------------
  process(mclk)
  begin
    if rising_edge(mclk) then
      if rst_n = '0' then
        left_buf        <= (others => '0');
        right_buf       <= (others => '0');
        left_pending    <= '0';
        right_pending   <= '0';
        expect_right    <= '0';
        tx_shift        <= (others => '0');
        tx_bit_cnt      <= (others => '0');
        active_is_right <= '0';
        sdata_i         <= '0';
      else
        -- AXIS handshake
        if s_axis_tvalid = '1' and tready_r = '1' then
          if expect_right = '0' then
            left_buf      <= s_axis_tdata(31 downto 8);
            left_pending  <= '1';
            expect_right  <= '1';

            assert s_axis_tuser = '1'
              report "axis_i2s: expected tuser='1' on Left sample"
              severity warning;
            assert s_axis_tlast = '0'
              report "axis_i2s: expected tlast='0' on Left sample"
              severity warning;
          else
            right_buf      <= s_axis_tdata(31 downto 8);
            right_pending  <= '1';
            expect_right   <= '0';

            assert s_axis_tuser = '0'
              report "axis_i2s: expected tuser='0' on Right sample"
              severity warning;
            assert s_axis_tlast = '1'
              report "axis_i2s: expected tlast='1' on Right sample"
              severity warning;
          end if;
        end if;

        -- Channel start on LRCK rollover event (new channel begins)
        if sclk_rise = '1' and sclk_cnt = 31 then
          active_is_right <= not lrck_i;
          tx_bit_cnt      <= (others => '0');

          if (not lrck_i) = '0' then
            -- New channel is Left
            if left_pending = '1' then
              tx_shift     <= left_buf;
              left_pending <= '0';
            else
              tx_shift     <= (others => '0');
            end if;
          else
            -- New channel is Right
            if right_pending = '1' then
              tx_shift      <= right_buf;
              right_pending <= '0';
            else
              tx_shift      <= (others => '0');
            end if;
          end if;
        elsif sclk_fall = '1' then
          -- I2S output on SCLK falling edge
          if tx_bit_cnt = 0 then
            sdata_i <= '0';
          elsif tx_bit_cnt <= 24 then
            sdata_i  <= tx_shift(23);
            tx_shift <= tx_shift(22 downto 0) & '0';
          else
            sdata_i <= '0';
          end if;

          if tx_bit_cnt < 31 then
            tx_bit_cnt <= tx_bit_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- Outputs
  -- -------------------------------------------------------
  s_axis_tready <= tready_r;
  sclk          <= sclk_i;
  lrck          <= lrck_i;
  sdata         <= sdata_i;

end architecture;
