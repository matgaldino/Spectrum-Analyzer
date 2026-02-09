APPTAINER_BIND_DIRS      = --bind=$(realpath ${XILINX_VIVADO}/../..),${PWD}
APPTAINER_CMD            = PATH=${INSTALL_DIR}:${PATH} apptainer
APPTAINER_BUILD          = ${APPTAINER_CMD} build
APPTAINER_IMAGE          = ${WORK_DIR}/debian_11.sif
APPTAINER_IMAGE_DEF      = ${PWD}/script/apptainer/debian-11.def
APPTAINER_ENV            = --env=XILINX_VIVADO=${XILINX_VIVADO}
APPTAINER_RUN            = ${APPTAINER_CMD} exec ${ENV} ${APPTAINER_BIND_DIRS} ${APPTAINER_IMAGE}
APPTAINER_STARTUP_SCRIPT = ${PWD}/script/apptainer/apptainer-exec.sh

${INSTALL_DIR}/bin/apptainer: | ${WORK_DIR} ${INSTALL_DIR}
	@echo "### Installing Apptainer ###"
	@cd ${WORK_DIR} && curl -s https://raw.githubusercontent.com/apptainer/apptainer/main/tools/install-unprivileged.sh | bash -s - ${INSTALL_DIR}

${APPTAINER_IMAGE}: ${INSTALL_DIR}/bin/apptainer ${APPTAINER_IMAGE_DEF}
	@echo "### Creating container image: $@ ###"
	${APPTAINER_BUILD} -F $@ ${APPTAINER_IMAGE_DEF}

${WORK_DIR}/apptainer-env-host.sh: ${APPTAINER_IMAGE} ${APPTAINER_STARTUP_SCRIPT}
	@echo "### Creating host environnement file: $@ ###"
	@echo "#!/bin/bash" > $@
	@echo "alias apptainer-run=\"${APPTAINER_RUN} bash ${APPTAINER_STARTUP_SCRIPT}\" " >> $@

.PHONY: ${WORK_DIR}/apptainer-install.sh
apptainer-install: ${WORK_DIR}/apptainer-env-host.sh

