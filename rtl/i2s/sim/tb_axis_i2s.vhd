library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.string_format_pkg.all;

entity tb_axis_i2s is
  generic(
    -- Number of stereo pairs (L+R) to test
    P_NUM_PAIRS : integer := 16
  );
end entity;

architecture testbench of tb_axis_i2s is

  -- -------------------------------------------------------
  -- Clock periods
  -- MCLK = 22.5792 MHz -> period = 44.29 ns
  -- SCLK = MCLK/8      -> period = 354.3 ns
  -- LRCK = SCLK/64     -> period = 22675 ns (~44.1 kHz)
  -- -------------------------------------------------------
  constant C_MCLK_HALF_PERIOD : time    := 22145 ps;
  constant C_MCLK_PERIOD      : time    := C_MCLK_HALF_PERIOD * 2;
  constant C_SCLK_PERIOD      : time    := C_MCLK_PERIOD * 8;
  constant C_LRCK_PERIOD      : time    := C_SCLK_PERIOD * 64;

  -- Timeout: 2 full LRCK periods in MCLK cycles
  constant C_TIMEOUT_CYCLES   : integer := 512 * 2;

  -- -------------------------------------------------------
  -- Sample storage
  -- -------------------------------------------------------
  type t_sample_24 is array(0 to P_NUM_PAIRS-1) of std_logic_vector(23 downto 0);

  signal sent_left  : t_sample_24 := (others => (others => '0'));
  signal sent_right : t_sample_24 := (others => (others => '0'));
  signal recv_left  : t_sample_24 := (others => (others => '0'));
  signal recv_right : t_sample_24 := (others => (others => '0'));

  -- -------------------------------------------------------
  -- Simulation control
  -- -------------------------------------------------------
  signal finished           : boolean := false;
  signal stim_axis_finished : boolean := false;
  signal stim_i2s_finished  : boolean := false;
  signal axis_started       : boolean := false;

  -- -------------------------------------------------------
  -- DUT signals
  -- -------------------------------------------------------
  signal mclk          : std_logic := '0';
  signal rst_n         : std_logic := '0';

  -- AXI Stream (driven by TB)
  signal s_axis_tdata  : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tlast  : std_logic := '0';
  signal s_axis_tuser  : std_logic := '0';

  -- I2S output (observed by TB)
  signal sclk          : std_logic;
  signal lrck          : std_logic;
  signal sdata         : std_logic;

begin

  finished <= stim_axis_finished and stim_i2s_finished;

  -- -------------------------------------------------------
  -- Device Under Test
  -- -------------------------------------------------------
  dut: entity work.axis_i2s
    port map(
      mclk          => mclk,
      rst_n         => rst_n,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tlast  => s_axis_tlast,
      s_axis_tuser  => s_axis_tuser,
      sclk          => sclk,
      lrck          => lrck,
      sdata         => sdata
    );

  -- -------------------------------------------------------
  -- MCLK generator: 22.5792 MHz
  -- -------------------------------------------------------
  clk_gen: process begin
    mclk <= '1'; wait for C_MCLK_HALF_PERIOD;
    mclk <= '0'; wait for C_MCLK_HALF_PERIOD;
    if finished then
      -- Extra cycles for verif to execute after finished
      for i in 0 to 63 loop
        mclk <= '1'; wait for C_MCLK_HALF_PERIOD;
        mclk <= '0'; wait for C_MCLK_HALF_PERIOD;
      end loop;
      wait;
    end if;
  end process;

  -- -------------------------------------------------------
  -- Reset: 10 MCLK cycles active low
  -- -------------------------------------------------------
  rst_gen: process begin
    print_info("Holding reset for 10 cycles");
    rst_n <= '0';
    for i in 0 to 9 loop
      wait until rising_edge(mclk);
    end loop;
    print_info("Releasing reset");
    rst_n <= '1';
    wait;
  end process;

  -- -------------------------------------------------------
  -- Test 1: SCLK and LRCK timing verification
  -- -------------------------------------------------------
  timing_check: process
    variable t_sclk_0 : time := 0 ns;
    variable t_sclk_1 : time := 0 ns;
    variable t_lrck_0 : time := 0 ns;
    variable t_lrck_1 : time := 0 ns;
    variable sclk_period_meas : time := 0 ns;
    variable lrck_period_meas : time := 0 ns;
  begin
    wait until rst_n = '1' and rising_edge(mclk);
    wait for C_LRCK_PERIOD;
    print_info("Test 1: verifying SCLK and LRCK timing");

    wait until rising_edge(sclk);
    t_sclk_0 := now;
    wait until rising_edge(sclk);
    t_sclk_1 := now;
    sclk_period_meas := t_sclk_1 - t_sclk_0;

    wait until rising_edge(lrck);
    t_lrck_0 := now;
    wait until rising_edge(lrck);
    t_lrck_1 := now;
    lrck_period_meas := t_lrck_1 - t_lrck_0;

    if sclk_period_meas = C_SCLK_PERIOD then
      print_success("SCLK period: " & time'image(sclk_period_meas) & " - correct (MCLK/8)");
    else
      print_error("SCLK period: expected " & time'image(C_SCLK_PERIOD)
                & ", got " & time'image(sclk_period_meas));
    end if;
    assert sclk_period_meas = C_SCLK_PERIOD
      report "SCLK timing check failed"
      severity failure;

    if lrck_period_meas = C_LRCK_PERIOD then
      print_success("LRCK period: " & time'image(lrck_period_meas) & " - correct (SCLK/64)");
    else
      print_error("LRCK period: expected " & time'image(C_LRCK_PERIOD)
                & ", got " & time'image(lrck_period_meas));
    end if;
    assert lrck_period_meas = C_LRCK_PERIOD
      report "LRCK timing check failed"
      severity failure;

    wait;
  end process;

  -- -------------------------------------------------------
  -- Test 2: AXIS stimulus
  -- Sends random 24-bit stereo samples to the DUT
  -- -------------------------------------------------------
  stim_axis: process
    variable seed1   : integer := 42;
    variable seed2   : integer := 137;
    variable fval    : real;
    variable slv     : std_logic_vector(23 downto 0);
    variable sample  : std_logic_vector(23 downto 0);
    variable timeout : integer := 0;
  begin
    s_axis_tdata  <= (others => '0');
    s_axis_tvalid <= '0';
    s_axis_tlast  <= '0';
    s_axis_tuser  <= '0';

    wait until rst_n = '1' and rising_edge(mclk);
    wait for C_LRCK_PERIOD;
    wait until rising_edge(mclk);

    print_info("Test 2: AXIS stimulus sending " & integer'image(P_NUM_PAIRS) & " stereo pairs");

    -- Generate random samples
    for i in 0 to P_NUM_PAIRS-1 loop
      for b in slv'range loop
        uniform(seed1, seed2, fval);
        if fval > 0.5 then slv(b) := '1'; else slv(b) := '0'; end if;
      end loop;
      sent_left(i) <= slv;

      for b in slv'range loop
        uniform(seed1, seed2, fval);
        if fval > 0.5 then slv(b) := '1'; else slv(b) := '0'; end if;
      end loop;
      sent_right(i) <= slv;
    end loop;

    wait until rising_edge(mclk);

    for pair in 0 to P_NUM_PAIRS-1 loop
      -- Left sample
      sample        := sent_left(pair);
      s_axis_tdata  <= sample & x"00";
      s_axis_tuser  <= '1';
      s_axis_tlast  <= '0';
      s_axis_tvalid <= '1';

      if pair = 0 then
        axis_started <= true;
      end if;

      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when s_axis_tready = '1';
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES
          report "Timeout waiting AXIS ready on Left sample"
          severity failure;
      end loop;

      -- Deassert between beats to keep waveforms readable
      s_axis_tvalid <= '0';
      s_axis_tuser  <= '0';
      s_axis_tlast  <= '0';
      wait until rising_edge(mclk);

      -- Right sample
      sample        := sent_right(pair);
      s_axis_tdata  <= sample & x"00";
      s_axis_tuser  <= '0';
      s_axis_tlast  <= '1';
      s_axis_tvalid <= '1';

      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when s_axis_tready = '1';
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES
          report "Timeout waiting AXIS ready on Right sample"
          severity failure;
      end loop;

      s_axis_tvalid <= '0';
      s_axis_tuser  <= '0';
      s_axis_tlast  <= '0';
      wait until rising_edge(mclk);

      print_info("AXIS: pair " & integer'image(pair) & " sent");
    end loop;

    s_axis_tdata  <= (others => '0');
    s_axis_tvalid <= '0';
    s_axis_tuser  <= '0';
    s_axis_tlast  <= '0';

    stim_axis_finished <= true;
    print_info("AXIS stimulus: all pairs sent");
    wait;
  end process;

  -- -------------------------------------------------------
  -- Test 2: I2S capture
  -- Captures serial output and rebuilds 24-bit samples
  -- -------------------------------------------------------
  stim_i2s_capture: process
    variable pair      : integer := 0;
    variable sample_v  : std_logic_vector(23 downto 0);
    variable timeout   : integer := 0;
    variable lrck_prev_v : std_logic := '0';
  begin
    wait until rst_n = '1' and rising_edge(mclk);
    wait until axis_started;
    wait until rising_edge(mclk);
    lrck_prev_v := lrck;

    print_info("I2S capture: waiting for samples");

    pair := 0;
    while pair < P_NUM_PAIRS loop

      -- Wait Left channel start (LRCK falling edge)
      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when lrck_prev_v = '1' and lrck = '0';
        lrck_prev_v := lrck;
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES * 4
          report "Timeout waiting for LRCK falling edge (Left)"
          severity failure;
      end loop;
      lrck_prev_v := lrck;

      -- I2S delay slot (ignore one rising SCLK)
      wait until rising_edge(sclk);

      -- Capture 24 bits, MSB first, on SCLK rising edge
      for b in 23 downto 0 loop
        wait until rising_edge(sclk);
        sample_v(b) := sdata;
      end loop;
      recv_left(pair) <= sample_v;

      -- Wait Right channel start (LRCK rising edge)
      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when lrck_prev_v = '0' and lrck = '1';
        lrck_prev_v := lrck;
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES * 4
          report "Timeout waiting for LRCK rising edge (Right)"
          severity failure;
      end loop;
      lrck_prev_v := lrck;

      -- I2S delay slot (ignore one rising SCLK)
      wait until rising_edge(sclk);

      -- Capture 24 bits, MSB first, on SCLK rising edge
      for b in 23 downto 0 loop
        wait until rising_edge(sclk);
        sample_v(b) := sdata;
      end loop;
      recv_right(pair) <= sample_v;

      print_info("I2S capture: pair " & integer'image(pair) & " received");
      pair := pair + 1;
    end loop;

    stim_i2s_finished <= true;
    print_info("I2S capture: all pairs received");
    wait;
  end process;

  -- -------------------------------------------------------
  -- Final Verification
  -- -------------------------------------------------------
  verif: process
    variable errors : integer := 0;
    variable idx    : integer := 0;
  begin
    wait until finished;
    wait until rising_edge(mclk);

    print_info("=== FINAL VERIFICATION START ===");

    idx := 0;
    while idx < P_NUM_PAIRS loop
      if sent_left(idx) /= recv_left(idx) then
        print_error("Left mismatch pair " & integer'image(idx)
                  & " | sent=" & to_hex(sent_left(idx))
                  & " | recv=" & to_hex(recv_left(idx)));
        errors := errors + 1;
      end if;

      if sent_right(idx) /= recv_right(idx) then
        print_error("Right mismatch pair " & integer'image(idx)
                  & " | sent=" & to_hex(sent_right(idx))
                  & " | recv=" & to_hex(recv_right(idx)));
        errors := errors + 1;
      end if;

      print_info("Pair " & integer'image(idx)
               & " L sent=" & to_hex(sent_left(idx))
               & " recv=" & to_hex(recv_left(idx))
               & " R sent=" & to_hex(sent_right(idx))
               & " recv=" & to_hex(recv_right(idx)));
      idx := idx + 1;
    end loop;

    if errors /= 0 then
      print_error("Simulation failed: " & integer'image(errors) & " errors");
    end if;

    assert errors = 0 severity failure;
    print_info("=== FINAL VERIFICATION END ===");
    print_success("Simulation successfully finished!");
    wait;
  end process;

end architecture;
