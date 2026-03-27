library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.string_format_pkg.all;

entity tb_vga_axis_controller is
  generic(
    -- Number of complete lines to test (reduced for faster simulation)
    P_TEST_LINES : integer := 4;
    -- Number of pixels per visible line
    P_H_VISIBLE  : integer := 1024
  );
end entity;

architecture testbench of tb_vga_axis_controller is

  -- -------------------------------------------------------
  -- Timings 1024x768 (mirrors DUT constants)
  -- -------------------------------------------------------
  constant H_VISIBLE : integer := 1024;
  constant H_FP      : integer := 24;
  constant H_SYNC    : integer := 136;
  constant H_BP      : integer := 160;
  constant H_TOTAL   : integer := H_VISIBLE + H_FP + H_SYNC + H_BP; -- 1344

  constant V_VISIBLE : integer := 768;
  constant V_FP      : integer := 3;
  constant V_SYNC    : integer := 6;
  constant V_BP      : integer := 29;
  constant V_TOTAL   : integer := V_VISIBLE + V_FP + V_SYNC + V_BP; -- 806

  -- -------------------------------------------------------
  -- Types for sample storage
  -- -------------------------------------------------------
  type t_pixel is record
    r : std_logic_vector(3 downto 0);
    g : std_logic_vector(3 downto 0);
    b : std_logic_vector(3 downto 0);
  end record;

  type t_line   is array(0 to P_H_VISIBLE-1)  of t_pixel;
  type t_frame  is array(0 to P_TEST_LINES-1) of t_line;

  -- -------------------------------------------------------
  -- Simulation control signals
  -- -------------------------------------------------------
  signal finished              : boolean := false;
  signal stim_stream_finished  : boolean := false;
  signal stim_ready_finished   : boolean := false;

  -- -------------------------------------------------------
  -- DUT signals
  -- -------------------------------------------------------
  signal clk_pix       : std_logic := '0';
  signal rst_n         : std_logic := '0';
  signal test_mode     : std_logic := '0';

  signal s_axis_tdata  : std_logic_vector(11 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;
  signal s_axis_tlast  : std_logic := '0';
  signal s_axis_tuser  : std_logic := '0';

  signal hsync         : std_logic;
  signal vsync         : std_logic;
  signal vga_r         : std_logic_vector(3 downto 0);
  signal vga_g         : std_logic_vector(3 downto 0);
  signal vga_b         : std_logic_vector(3 downto 0);

  -- -------------------------------------------------------
  -- Storage for sent and received samples
  -- -------------------------------------------------------
  signal sent_frame : t_frame;
  signal recv_frame : t_frame;

begin

  finished <= stim_stream_finished and stim_ready_finished;

  -- -------------------------------------------------------
  -- Device Under Test
  -- -------------------------------------------------------
  dut: entity work.vga_axis_controller
    port map(
      clk_pix       => clk_pix,
      rst_n         => rst_n,
      test_mode     => test_mode,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tlast  => s_axis_tlast,
      s_axis_tuser  => s_axis_tuser,
      hsync         => hsync,
      vsync         => vsync,
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b
    );

  -- -------------------------------------------------------
  -- Clock: 65 MHz (~15.38 ns period)
  -- -------------------------------------------------------
  clk_gen: process begin
    clk_pix <= '1'; wait for 7.69 ns;
    clk_pix <= '0'; wait for 7.69 ns;
    if finished then
    -- Ciclos extras para o verif executar após finished
    for i in 0 to 9 loop
      clk_pix <= '1'; wait for 7.69 ns;
      clk_pix <= '0'; wait for 7.69 ns;
    end loop;
    wait;
  end if;
end process;

  -- -------------------------------------------------------
  -- Reset: 10 cycles active low
  -- -------------------------------------------------------
  rst_gen: process begin
    print_info("Holding reset for 10 cycles");
    rst_n <= '0';
    for i in 0 to 9 loop
      wait until rising_edge(clk_pix);
    end loop;
    print_info("Releasing reset");
    rst_n <= '1';
    wait;
  end process;

  -- -------------------------------------------------------
  -- Test 1: test mode (test_mode='1')
  -- -------------------------------------------------------
  test_mode_check: process
    variable h_sync_pulses : integer := 0;
    variable v_sync_pulses : integer := 0;
  begin
    wait until rst_n = '1' and rising_edge(clk_pix);
    test_mode <= '1';
    print_info("Test 1: verifying hsync/vsync pulses in test mode");

    for cycle in 0 to H_TOTAL * V_TOTAL - 1 loop
      wait until rising_edge(clk_pix);
      if hsync = '0' then h_sync_pulses := h_sync_pulses + 1; end if;
      if vsync = '0' then v_sync_pulses := v_sync_pulses + 1; end if;
    end loop;

    wait until rising_edge(clk_pix);

    if h_sync_pulses = H_SYNC * V_TOTAL then
      print_success("hsync: " & integer'image(h_sync_pulses) & " active cycles - correct");
    else
      print_error("hsync: expected " & integer'image(H_SYNC * V_TOTAL)
                & " active cycles, received " & integer'image(h_sync_pulses));
    end if;

    if v_sync_pulses = V_SYNC * H_TOTAL then
      print_success("vsync: " & integer'image(v_sync_pulses) & " active cycles - correct");
    else
      print_error("vsync: expected " & integer'image(V_SYNC * H_TOTAL)
                & " active cycles, received " & integer'image(v_sync_pulses));
    end if;

    test_mode <= '0';
    wait;
  end process;

  -- -------------------------------------------------------
  -- AXI Stream Stimulus
  -- -------------------------------------------------------
  stim_stream: process
    variable seed1 : integer := 42;
    variable seed2 : integer := 137;
    variable fval  : real;
    variable slv   : std_logic_vector(11 downto 0);
  begin
    s_axis_tvalid <= '0';
    s_axis_tdata  <= (others => '0');
    s_axis_tlast  <= '0';
    s_axis_tuser  <= '0';

    wait until rst_n = '1' and rising_edge(clk_pix);
    wait for H_TOTAL * V_TOTAL * 15.38 ns; 
    wait until rising_edge(clk_pix);

    print_info("Test 2: sending " & integer'image(P_TEST_LINES) & " lines via AXI Stream");

    for row in 0 to P_TEST_LINES-1 loop
      for col in 0 to P_H_VISIBLE-1 loop
        for i in slv'range loop
          uniform(seed1, seed2, fval);
          if fval > 0.5 then slv(i) := '1'; else slv(i) := '0'; end if;
        end loop;
        sent_frame(row)(col).r <= slv(11 downto 8);
        sent_frame(row)(col).g <= slv(7  downto 4);
        sent_frame(row)(col).b <= slv(3  downto 0);
      end loop;
    end loop;
    wait until rising_edge(clk_pix);

    for row in 0 to P_TEST_LINES-1 loop
      print_info("Sending line " & integer'image(row));
      for col in 0 to P_H_VISIBLE-1 loop
        s_axis_tdata  <= sent_frame(row)(col).r
                       & sent_frame(row)(col).g
                       & sent_frame(row)(col).b;
        s_axis_tvalid <= '1';
        if col = P_H_VISIBLE-1 then
          s_axis_tlast <= '1';
        else
          s_axis_tlast <= '0';
        end if;
        if row = 0 and col = 0 then
          s_axis_tuser <= '1';
        else
          s_axis_tuser <= '0';
        end if;
        wait until s_axis_tready = '1' and rising_edge(clk_pix);
      end loop;
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tlast  <= '0';
    s_axis_tuser  <= '0';
    wait until rising_edge(clk_pix);
    stim_stream_finished <= true;
    print_info("Stream: all pixels sent");
    wait;
  end process;

  -- -------------------------------------------------------
  -- Output Capture
  -- -------------------------------------------------------
stim_out_capture: process
  variable row     : integer := 0;
  variable col     : integer := 0;
  variable capture : boolean := false;
begin
  -- Aguarda SOF para sincronizar com o início real do stream
  wait until s_axis_tuser = '1' and s_axis_tvalid = '1' and rising_edge(clk_pix);
  print_info("Capture: SOF detectado, iniciando captura");

  row     := 0;
  col     := 0;
  capture := false;

  while row < P_TEST_LINES loop
    wait until rising_edge(clk_pix);

    -- Captura 1 ciclo após handshake (compensa pipeline do DUT)
    if capture then
      recv_frame(row)(col).r <= vga_r;
      recv_frame(row)(col).g <= vga_g;
      recv_frame(row)(col).b <= vga_b;
      if col = P_H_VISIBLE-1 then
        col := 0;
        row := row + 1;
      else
        col := col + 1;
      end if;
      capture := false;
    end if;

    -- Handshake completo = pixel consumido
    if s_axis_tready = '1' and s_axis_tvalid = '1' then
      capture := true;
    end if;

  end loop;

  stim_ready_finished <= true;
  print_info("Capture: todos os pixels capturados");
  wait;
end process;

  -- -------------------------------------------------------
  -- Final Verification
  -- -------------------------------------------------------
  verif: process
    variable errors : integer := 0;
  begin
    wait until finished;

    print_info("Simulation ended: verifying data");

    for row in 0 to P_TEST_LINES-1 loop
      for col in 0 to P_H_VISIBLE-1 loop
        if    sent_frame(row)(col).r /= recv_frame(row)(col).r
           or sent_frame(row)(col).g /= recv_frame(row)(col).g
           or sent_frame(row)(col).b /= recv_frame(row)(col).b
        then
          print_error("Mismatch row " & integer'image(row)
                    & " col " & integer'image(col)
                    & " | sent R=" & to_hex(sent_frame(row)(col).r)
                    & " G=" & to_hex(sent_frame(row)(col).g)
                    & " B=" & to_hex(sent_frame(row)(col).b)
                    & " | received R=" & to_hex(recv_frame(row)(col).r)
                    & " G=" & to_hex(recv_frame(row)(col).g)
                    & " B=" & to_hex(recv_frame(row)(col).b));
          errors := errors + 1;
        end if;
      end loop;
    end loop;

    if errors /= 0 then
      print_error("Simulation failed: " & integer'image(errors) & " errors");
    end if;

    assert errors = 0 severity failure;
    print_success("Simulation successfully finished!");
    wait;
  end process;

end architecture;
