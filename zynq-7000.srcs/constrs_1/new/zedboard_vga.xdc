## =========================
##  Clock 100 MHz (PL)
## =========================
set_property PACKAGE_PIN Y9 [get_ports clk100]
set_property IOSTANDARD LVCMOS33 [get_ports clk100]
create_clock -name clk100 -period 10.000 [get_ports clk100]

## =========================
##  VGA (ZedBoard)
##  vga_r[3:0], vga_g[3:0], vga_b[3:0]
## =========================

# RED  (V20, U20, V19, V18)
set_property PACKAGE_PIN V20 [get_ports {vga_r[3]}]
set_property PACKAGE_PIN U20 [get_ports {vga_r[2]}]
set_property PACKAGE_PIN V19 [get_ports {vga_r[1]}]
set_property PACKAGE_PIN V18 [get_ports {vga_r[0]}]

# GREEN (AB22, AA22, AB21, AA21)
set_property PACKAGE_PIN AB22 [get_ports {vga_g[3]}]
set_property PACKAGE_PIN AA22 [get_ports {vga_g[2]}]
set_property PACKAGE_PIN AB21 [get_ports {vga_g[1]}]
set_property PACKAGE_PIN AA21 [get_ports {vga_g[0]}]

# BLUE (Y21, Y20, AB20, AB19)
set_property PACKAGE_PIN Y21  [get_ports {vga_b[3]}]
set_property PACKAGE_PIN Y20  [get_ports {vga_b[2]}]
set_property PACKAGE_PIN AB20 [get_ports {vga_b[1]}]
set_property PACKAGE_PIN AB19 [get_ports {vga_b[0]}]

# HSYNC / VSYNC
set_property PACKAGE_PIN AA19 [get_ports hsync]
set_property PACKAGE_PIN Y19  [get_ports vsync]

# IO standard VGA
set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[*] vga_g[*] vga_b[*] hsync vsync}]