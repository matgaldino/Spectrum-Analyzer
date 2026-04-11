library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.string_format_pkg.all;

entity tb_i2s_axis is
  generic(
    -- Number of stereo pairs (L+R) to test
    P_NUM_PAIRS : integer := 16
  );
end entity;

architecture testbench of tb_i2s_axis is

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
  signal stim_adc_finished  : boolean := false;
  signal stim_axis_finished : boolean := false;
  signal adc_started        : boolean := false;

  -- -------------------------------------------------------
  -- DUT signals
  -- -------------------------------------------------------
  signal mclk          : std_logic := '0';
  signal rst_n         : std_logic := '0';

  -- I2S (driven by ADC model)
  signal sclk          : std_logic;
  signal lrck          : std_logic;
  signal sdata         : std_logic := '0';

  -- AXI Stream
  signal m_axis_tdata  : std_logic_vector(31 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '1';
  signal m_axis_tlast  : std_logic;
  signal m_axis_tuser  : std_logic;

begin

  finished <= stim_adc_finished and stim_axis_finished;

  -- -------------------------------------------------------
  -- Device Under Test
  -- -------------------------------------------------------
  dut: entity work.i2s_axis
    port map(
      mclk          => mclk,
      rst_n         => rst_n,
      sclk          => sclk,
      lrck          => lrck,
      sdata         => sdata,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tlast  => m_axis_tlast,
      m_axis_tuser  => m_axis_tuser
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
  -- Measures SCLK/LRCK periods directly (phase-independent)
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
    -- Skip first LRCK period to let clocks stabilize
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
  -- Test 2: ADC model
  -- Generates random 24-bit samples and drives sdata
  -- serially, following I2S Philips standard:
  --   - data changes on SCLK falling edge
  --   - MSB appears 1 SCLK after LRCK transition
  -- -------------------------------------------------------
  stim_adc: process
    variable seed1   : integer := 42;
    variable seed2   : integer := 137;
    variable fval    : real;
    variable slv     : std_logic_vector(23 downto 0);
    variable sample  : std_logic_vector(23 downto 0);
    variable lrck_prev_v : std_logic := '0';
    variable timeout : integer := 0;
  begin
    sdata <= '0';
    wait until rst_n = '1' and rising_edge(mclk);
    -- Wait for clocks to stabilize (1 full LRCK period)
    wait for C_LRCK_PERIOD;
    wait until rising_edge(mclk);

    print_info("Test 2: ADC model sending " & integer'image(P_NUM_PAIRS) & " stereo pairs");

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

      -- Send Left channel
      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when lrck_prev_v = '1' and lrck = '0';
        lrck_prev_v := lrck;
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES
          report "Timeout waiting for LRCK falling edge"
          severity failure;
      end loop;
      lrck_prev_v := lrck;

      if pair = 0 then
        -- Marks that the first real stereo frame is about to be transmitted.
        adc_started <= true;
      end if;

      wait until falling_edge(sclk);
      sample := sent_left(pair);
      for b in 23 downto 0 loop
        sdata <= sample(b);
        if b > 0 then
          wait until falling_edge(sclk);
        end if;
      end loop;
      for b in 0 to 7 loop
        wait until falling_edge(sclk);
        sdata <= '0';
      end loop;

      -- Send Right channel
      timeout := 0;
      loop
        wait until rising_edge(mclk);
        exit when lrck_prev_v = '0' and lrck = '1';
        lrck_prev_v := lrck;
        timeout := timeout + 1;
        assert timeout < C_TIMEOUT_CYCLES
          report "Timeout waiting for LRCK rising edge"
          severity failure;
      end loop;
      lrck_prev_v := lrck;

      wait until falling_edge(sclk);
      sample := sent_right(pair);
      for b in 23 downto 0 loop
        sdata <= sample(b);
        if b > 0 then
          wait until falling_edge(sclk);
        end if;
      end loop;
      for b in 0 to 7 loop
        wait until falling_edge(sclk);
        sdata <= '0';
      end loop;

      print_info("ADC: pair " & integer'image(pair) & " sent");
    end loop;

    sdata <= '0';
    stim_adc_finished <= true;
    print_info("ADC model: all pairs sent");
    wait;
  end process;

  -- -------------------------------------------------------
  -- Test 2: AXI Stream capture
  -- Receives samples from DUT and stores them
  -- -------------------------------------------------------
  stim_axis_capture: process
  variable pair    : integer := 0;
  variable timeout : integer := 0;
begin
  wait until rst_n = '1' and rising_edge(mclk);
  wait until adc_started;
  wait until rising_edge(mclk);

  print_info("AXI capture: first real frame started, waiting for samples");

  pair := 0;
  while pair < P_NUM_PAIRS loop

    -- Wait for Left channel (tuser='1')
    timeout := 0;
    loop
      wait until rising_edge(mclk);
      exit when m_axis_tvalid = '1' and m_axis_tready = '1' and m_axis_tuser = '1';
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYCLES * P_NUM_PAIRS * 4
        report "Timeout waiting for Left channel (tuser) in AXI capture"
        severity failure;
    end loop;
    assert m_axis_tlast = '0'
      report "AXI framing error: Left sample must have tlast='0'"
      severity failure;
    recv_left(pair) <= m_axis_tdata(31 downto 8);

    -- Wait for Right channel (tlast='1')
    timeout := 0;
    loop
      wait until rising_edge(mclk);
      exit when m_axis_tvalid = '1' and m_axis_tready = '1' and m_axis_tlast = '1';
      timeout := timeout + 1;
      assert timeout < C_TIMEOUT_CYCLES * P_NUM_PAIRS * 4
        report "Timeout waiting for Right channel (tlast) in AXI capture"
        severity failure;
    end loop;
    assert m_axis_tuser = '0'
      report "AXI framing error: Right sample must have tuser='0'"
      severity failure;
    recv_right(pair) <= m_axis_tdata(31 downto 8);

    print_info("AXI capture: pair " & integer'image(pair) & " received");
    pair := pair + 1;
  end loop;

  stim_axis_finished <= true;
  print_info("AXI capture: all pairs received");
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
    -- Extra cycles for signals to propagate
    wait until rising_edge(mclk);

    print_info("=== FINAL VERIFICATION START ===");

    idx := 0;
    while idx < P_NUM_PAIRS loop

      -- Verify Left channel
      if sent_left(idx) /= recv_left(idx) then
        print_error("Left mismatch pair " & integer'image(idx)
                  & " | sent=" & to_hex(sent_left(idx))
                  & " | recv=" & to_hex(recv_left(idx)));
        errors := errors + 1;
      end if;

      -- Verify Right channel
      if sent_right(idx) /= recv_right(idx) then
        print_error("Right mismatch pair " & integer'image(idx)
                  & " | sent=" & to_hex(sent_right(idx))
                  & " | recv=" & to_hex(recv_right(idx)));
        errors := errors + 1;
      end if;

      -- After checking, always print values (verbose mode)
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