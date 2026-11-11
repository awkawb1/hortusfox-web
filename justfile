set quiet := true

# Passed to QEMU in boot-vm
export QEMU_KERNEL_PARAMS := "console=ttyS0"
# Bound to 127.0.0.1 explicitly: a bare "hostfwd=tcp::8080-:80" (empty host
# address) binds 0.0.0.0, exposing this throwaway VM (root password "toor",
# firewall disabled, test credentials) to the whole network, not just this
# machine.
export QEMU_NET_OPTS := "hostfwd=tcp:127.0.0.1:8080-:80"
export QEMU_OPTS := "-nographic"

[private]
_default:
	just --list

[doc('Clean build artifacts and shutdown running virtual machines')]
[group('maintenance')]
clean:
    #!/usr/bin/env bash
    rm result > /dev/null 2>&1
    # Scoped to this project's own disk image, not `pkill qemu` -- a bare
    # match on the process name would kill *any* QEMU VM on the host (this
    # one's forwarded port is the only reason we need to kill anything).
    pkill -f "$(pwd)/nixos.qcow2" > /dev/null 2>&1
    rm nixos.qcow2 > /dev/null 2>&1
    exit 0

[doc('Build virtual machine for testing')]
[group('main')]
build-vm: clean
    nom build ".#nixosConfigurations.test.config.system.build.vm"

[doc('Run virtual machine in current terminal')]
[group('main')]
boot-vm:
    #!/usr/bin/env bash
    [ -x result/bin/run-nixos-vm ] && \
        ./result/bin/run-nixos-vm
    reset
