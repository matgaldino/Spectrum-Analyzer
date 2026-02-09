# Tips and tricks

Debugging with hardware emulation using GDB
----
To be able to debug an application in hardware emulation, a TCP socket is created (tcp::9000). To use it, open gdb in a new terminal:
```bash
gdb
```
Then connect GDB to the tcp socket:
```gdb
target remote tcp::9000
```

Debugging with hardware emulation using XSCT
----
Another possibility is to connect xsct shell to this socket.
To do this, open xsct in a new terminal and open xsct:
```bash
xsct -nodisp
```
Then connect xsct to the tcp socket:
```tcl
gdbremote connect tcp:localhost:9000
```

Using apptainer
----
If needed, a container (based on Ubuntu 20.04) is given with all prerequisites preinstalled.

To use it, you have to install Vivado before.
Then source Vivado environnement.
```bash
source <vivado_install>/settings64.sh
```

Then install apptainer and build the container (this will take some time):
```bash
make apptainer-install
```

To be able to use the container, you have to source the generated environnement file:
```bash
source build/apptainer-env-host.sh
```

Then to use the container for a given command, you only have to prefix all your commands with `apptainer-run`.

For example:
```bash
apptainer-run make vivado-all
```

