ifndef (i2s_axis_INCLUDED)
	include rtl/sim_utils/sources.mk

	i2s_axis_INCLUDED = 1
	i2s_axis_DIR      = ${PWD}/rtl/i2s

	i2s_axis_SYNTH_SRC += ${i2s_axis_DIR}/synth/pkg_i2s_axis.vhd
	i2s_axis_SYNTH_SRC += ${i2s_axis_DIR}/synth/i2s_clkgen.vhd
	i2s_axis_SYNTH_SRC += ${i2s_axis_DIR}/synth/i2s_axis.vhd
	i2s_axis_SYNTH_SRC += ${i2s_axis_DIR}/synth/axis_i2s.vhd

	i2s_axis_SIM_SRC += ${i2s_axis_DIR}/sim/tb_i2s_axis.vhd
	i2s_axis_SIM_SRC += ${i2s_axis_DIR}/sim/tb_axis_i2s.vhd
	i2s_axis_SIM_SRC += ${i2s_axis_DIR}/sim/tb_i2s_loopback.vhd
	i2s_axis_SIM_TB  += tb_i2s_axis
	i2s_axis_SIM_TB  += tb_axis_i2s
	i2s_axis_SIM_TB  += tb_i2s_loopback

	SYNTH_SRC += ${i2s_axis_SYNTH_SRC}
	SIM_SRC   += ${i2s_axis_SIM_SRC}
	SIM_TB    += ${i2s_axis_SIM_TB}

	RTL_MODULES_DEF += ${i2s_axis_DIR}/sources.mk
	RTL_MODULES     += i2s_axis
endif
