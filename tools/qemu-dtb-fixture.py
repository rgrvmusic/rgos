#!/usr/bin/env python3
"""Make the Pi's PL011 UART usable under QEMU, so the test has a console.

This produces a QEMU TEST FIXTURE. It is never used to build the image and
changes nothing about what runs on real hardware. On a real Pi the firmware
sets all of this up before Linux starts; QEMU emulates no VideoCore, so the
kernel has to be handed a device tree that does not depend on it.

Three edits, all in serial@7e201000:

1. clocks. The node takes its uartclk from cprman, and cprman's rates come
   from the firmware mailbox. QEMU logs those property tags as "unhandled",
   so uartclk reads as 0 and amba-pl011 never registers a tty -- the boot
   log contains no ttyAMA0 at all. Repoint both clocks at a fixed 48 MHz
   clock, which is what the firmware would have programmed.

2. skip-init. Present because the firmware has already initialised the port.
   QEMU has not, so the driver must do it itself.

3. uart-has-rtscts. On a Pi 4 the PL011 is wired to the Bluetooth module with
   hardware flow control. With no CTS to assert, a console can stall on
   output. Drop it for the fixture.

Without these, earlycon still prints -- it is polled and needs no clock -- so
a boot looks healthy while being impossible to log in to.
"""
import re
import sys


def node_span(text, name):
    m = re.search(r'^\s*' + re.escape(name) + r'\s*\{', text, re.M)
    if not m:
        raise SystemExit(f"node {name} not found")
    depth = 0
    for i in range(m.end() - 1, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return m.end(), i
    raise SystemExit(f"unbalanced braces for {name}")


def main(src, dst, hz=48_000_000):
    text = open(src).read()

    # Pick a phandle that is definitely free: dtc rejects duplicates.
    used = {int(p, 16) for p in re.findall(r'phandle = <(0x[0-9a-f]+)>', text)}
    ph = 0x100
    while ph in used:
        ph += 1
    phref = f"0x{ph:x}"

    # A root-level fixed clock to stand in for cprman's uartclk.
    clock = (
        "\n\tregroove-qemu-uartclk {\n"
        '\t\tcompatible = "fixed-clock";\n'
        "\t\t#clock-cells = <0x00>;\n"
        f"\t\tclock-frequency = <0x{hz:x}>;\n"
        f"\t\tphandle = <{phref}>;\n"
        "\t};\n"
    )
    # Append just before the final closing brace of the root node.
    text = text.rstrip()
    assert text.endswith('};'), "unexpected dts tail"
    text = text[:-2] + clock + "};\n"

    s, e = node_span(text, "serial@7e201000")
    body = text[s:e]
    before = body

    # 1. fixed uartclk / apb_pclk
    body = re.sub(r'^\s*clocks = <[^;]*>;',
                  f'\t\t\tclocks = <{phref} {phref}>;', body, flags=re.M)
    # Drop anything else upstream may add about clocking the firmware owns.
    body = re.sub(r'^\s*clock-names = "uartclk", "apb_pclk";',
                  '\t\t\tclock-names = "uartclk", "apb_pclk";', body, flags=re.M)
    # 2. let the driver initialise the port
    body = re.sub(r'^\s*skip-init;\n', '', body, flags=re.M)
    # 3. no Bluetooth modem lines to handshake with
    body = re.sub(r'^\s*uart-has-rtscts;\n', '', body, flags=re.M)

    if body == before:
        raise SystemExit("serial@7e201000 was not modified -- check the dts")
    text = text[:s] + body + text[e:]

    open(dst, "w").write(text)
    print(f"wrote {dst}: uartclk -> fixed {hz} Hz (phandle {phref}), "
          f"skip-init and uart-has-rtscts removed")


if __name__ == "__main__":
    main(*sys.argv[1:])
