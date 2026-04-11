library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vga_axis_controller is
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
end entity;

architecture rtl of vga_axis_controller is

  constant H_VISIBLE : integer := 1024;
  constant H_FP      : integer := 24;
  constant H_SYNC    : integer := 136;
  constant H_BP      : integer := 160;
  constant H_TOTAL   : integer := H_VISIBLE + H_FP + H_SYNC + H_BP;

  constant V_VISIBLE : integer := 768;
  constant V_FP      : integer := 3;
  constant V_SYNC    : integer := 6;
  constant V_BP      : integer := 29;
  constant V_TOTAL   : integer := V_VISIBLE + V_FP + V_SYNC + V_BP;

  signal h_cnt        : integer range 0 to H_TOTAL-1 := 0;
  signal v_cnt        : integer range 0 to V_TOTAL-1 := 0;
  signal active_video : std_logic;
  signal hsync_comb   : std_logic;
  signal vsync_comb   : std_logic;
  signal r_comb       : std_logic_vector(3 downto 0);
  signal g_comb       : std_logic_vector(3 downto 0);
  signal b_comb       : std_logic_vector(3 downto 0);
  signal axis_tready_i: std_logic;
  signal synced       : std_logic := '1';

begin

  -- -------------------------------------------------------
  -- H / V counters + SOF resynchronization
  -- -------------------------------------------------------
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if rst_n = '0' then
        h_cnt  <= 0;
        v_cnt  <= 0;
        synced <= '1';
      else
        if s_axis_tvalid = '1' and axis_tready_i = '1' and
           s_axis_tuser = '1' and test_mode = '0' then
          -- SOF received: resynchronizes counters to (0,0)
          -- Pixel 0 is consumed in this cycle, counters stay at 0
          -- so the next pixel is displayed at position 1
          synced <= '1';
          h_cnt  <= 0;
          v_cnt  <= 0;
        else
          -- Normal scan
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
    end if;
  end process;

  -- -------------------------------------------------------
  -- Combinational logic: active window, sync pulses, backpressure
  -- -------------------------------------------------------
  active_video  <= '1' when (h_cnt < H_VISIBLE and v_cnt < V_VISIBLE) else '0';
  hsync_comb    <= '0' when (h_cnt >= H_VISIBLE + H_FP and
                              h_cnt <  H_VISIBLE + H_FP + H_SYNC) else '1';
  vsync_comb    <= '0' when (v_cnt >= V_VISIBLE + V_FP and
                              v_cnt <  V_VISIBLE + V_FP + V_SYNC) else '1';
  axis_tready_i <= active_video and (not test_mode);
  s_axis_tready <= axis_tready_i;

  -- -------------------------------------------------------
  -- Color generation
  -- -------------------------------------------------------
  process(h_cnt, v_cnt, active_video, test_mode, synced, s_axis_tdata, s_axis_tvalid)
    variable band : integer;
  begin
    r_comb <= (others => '0');
    g_comb <= (others => '0');
    b_comb <= (others => '0');

    if active_video = '1' then
      if test_mode = '1' then
        -- Test pattern: 8 vertical bars
        band := h_cnt / 128;
        case band is
          when 0      => r_comb <= x"F"; g_comb <= x"0"; b_comb <= x"0";
          when 1      => r_comb <= x"0"; g_comb <= x"F"; b_comb <= x"0";
          when 2      => r_comb <= x"0"; g_comb <= x"0"; b_comb <= x"F";
          when 3      => r_comb <= x"F"; g_comb <= x"F"; b_comb <= x"0";
          when 4      => r_comb <= x"0"; g_comb <= x"F"; b_comb <= x"F";
          when 5      => r_comb <= x"F"; g_comb <= x"0"; b_comb <= x"F";
          when 6      => r_comb <= x"F"; g_comb <= x"F"; b_comb <= x"F";
          when others =>
            if ((h_cnt / 16) mod 2) = ((v_cnt / 16) mod 2) then
              r_comb <= x"2"; g_comb <= x"2"; b_comb <= x"2";
            else
              r_comb <= x"E"; g_comb <= x"E"; b_comb <= x"E";
            end if;
        end case;
      else
        -- Normal mode: AXI Stream
        -- Display pixel if synchronized and valid data present
        if synced = '1' and s_axis_tvalid = '1' then
          r_comb <= s_axis_tdata(11 downto 8);
          g_comb <= s_axis_tdata(7  downto 4);
          b_comb <= s_axis_tdata(3  downto 0);
        end if;
        -- tvalid='0' or not synchronized → black pixel (default)
      end if;
    end if;
  end process;

  -- -------------------------------------------------------
  -- Output register stage (1-cycle pipeline)
  -- hsync, vsync and color registered together → always aligned
  -- -------------------------------------------------------
  process(clk_pix)
  begin
    if rising_edge(clk_pix) then
      if rst_n = '0' then
        hsync <= '1';  -- inactive
        vsync <= '1';  -- inactive
        vga_r <= (others => '0');
        vga_g <= (others => '0');
        vga_b <= (others => '0');
      else
        hsync <= hsync_comb;
        vsync <= vsync_comb;
        vga_r <= r_comb;
        vga_g <= g_comb;
        vga_b <= b_comb;
      end if;
    end if;
  end process;

end architecture;