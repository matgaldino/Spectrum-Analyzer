XILINX_QEMU_GIT = https://github.com/Xilinx/qemu.git
XILINX_QEMU_VERSION = xilinx_v2024.2
XILINX_QEMU_AARCH64_BIN = ${INSTALL_DIR}/bin/qemu-system-aarch64
XILINX_QEMU_MICROBLAZE_BIN = ${INSTALL_DIR}/bin/qemu-system-microblazeel

${WORK_DIR}:
	@mkdir -p $@

${INSTALL_DIR}:
	@mkdir -p $@

${WORK_DIR}/qemu: | ${WORK_DIR} ${INSTALL_DIR}
	@cd ${WORK_DIR} && git clone ${XILINX_QEMU_GIT} qemu
	@cd ${WORK_DIR}/qemu && git checkout ${XILINX_QEMU_VERSION}

${INSTALL_DIR}/bin/qemu-system-aarch64: | ${WORK_DIR}/qemu
	@echo "----------------------------------------------------------------"
	@echo "---                        QEMU BUILD                        ---"
	@echo "----------------------------------------------------------------"
	@mkdir -p ${WORK_DIR}/qemu/build
	@cd ${WORK_DIR}/qemu/build && ../configure --target-list="aarch64-softmmu,microblazeel-softmmu,arm-softmmu" --enable-fdt --disable-kvm --disable-xen --enable-gcrypt --prefix="${INSTALL_DIR}"
	@make -j8 -C ${WORK_DIR}/qemu/build all install

.PHONY: qemu-build
qemu-build: ${INSTALL_DIR}/bin/qemu-system-aarch64

.PHONY: qemu-clean
qemu-clean:
	@rm -rf ${INSTALL_DIR}
	@rm -rf ${WORK_DIR}
