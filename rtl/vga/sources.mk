ifndef (vga_axis_controller_INCLUDED)
  include rtl/sim_utils/sources.mk

  vga_axis_controller_INCLUDED = 1
  vga_axis_controller_DIR      = ${PWD}/rtl/vga

  vga_axis_controller_SYNTH_SRC += ${vga_axis_controller_DIR}/synth/pkg_vga_axis_controller.vhd
  vga_axis_controller_SYNTH_SRC += ${vga_axis_controller_DIR}/synth/vga_axis_controller.vhd

  vga_axis_controller_SIM_SRC += ${vga_axis_controller_DIR}/sim/tb_vga_axis_controller.vhd
  vga_axis_controller_SIM_TB  += tb_vga_axis_controller

  SYNTH_SRC += ${vga_axis_controller_SYNTH_SRC}
  SIM_SRC   += ${vga_axis_controller_SIM_SRC}
  SIM_TB    += ${vga_axis_controller_SIM_TB}

  RTL_MODULES_DEF += ${vga_axis_controller_DIR}/sources.mk
  RTL_MODULES     += vga_axis_controller
endif
