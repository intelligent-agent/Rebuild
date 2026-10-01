#!/usr/bin/env python3
# Kconfig helpers for rebuild-firmware (#106), on Klipper's own kconfiglib.
#
#   firmware-kconfig.py reference KLIPPER STOCK EFFECTIVE USERFILE TITLE
#       Every option the user can set for this MCU, with its help text and
#       current value, ready to copy into the user's file.
#   firmware-kconfig.py diff KLIPPER STOCK NEW
#       The lines that take STOCK to NEW: what menuconfig changed, as the
#       user's file should hold it.
#   firmware-kconfig.py check KLIPPER EFFECTIVE USERFILE
#       A warning for each line in the user's file that did not take effect:
#       an unknown option, one that cannot be set on this MCU, or one another
#       option overrides.
#
# KLIPPER is the build copy of the Klipper tree. STOCK, EFFECTIVE and NEW
# are complete configs, after olddefconfig.
import os
import re
import sys
import textwrap


def load(klipper, config):
    sys.path.insert(0, os.path.join(klipper, "lib", "kconfiglib"))
    import kconfiglib
    os.chdir(klipper)    # Kconfig's `source` lines are relative to the tree
    kconf = kconfiglib.Kconfig("src/Kconfig", warn_to_stderr=False)
    kconf.load_config(config)
    return kconfiglib, kconf


def values(kconfiglib, kconf):
    return {s.name: s.str_value for s in kconf.unique_defined_syms}


def line(kconfiglib, sym, value):
    if sym.orig_type in (kconfiglib.BOOL, kconfiglib.TRISTATE):
        return "CONFIG_%s=%s" % (sym.name, value or "n")
    if sym.orig_type == kconfiglib.STRING:
        return 'CONFIG_%s="%s"' % (sym.name, value.replace('"', '\\"'))
    return "CONFIG_%s=%s" % (sym.name, value)


def settable(kconfiglib, sym):
    # Only what a config line can actually change: an option with a prompt
    # that is visible here. Options that another option selects, or that
    # depend on something switched off, are not.
    return sym.visibility > 0 and any(n.prompt for n in sym.nodes)


def machine(choice):
    # Which architecture and chip: fixed by the board, and a list of every
    # MCU Klipper supports would bury the options that matter.
    return any(sym.name.startswith("MACH_") for sym in choice.syms)


def named_in(path):
    names = set()
    if path and os.path.exists(path):
        for text in open(path):
            m = re.match(r"\s*(?:#\s*)?CONFIG_(\w+)(?:=| is not set)", text)
            if m:
                names.add(m.group(1))
    return names


def reference(klipper, stock, effective, userfile, title):
    kconfiglib, kconf = load(klipper, stock)
    stock_values = values(kconfiglib, kconf)
    kconf.load_config(effective)
    user_names = named_in(userfile)
    role = os.path.basename(userfile)
    out = []
    for text in title.split("\\n"):
        out.append("# " + text if text else "#")
    out += ["#",
            "# Every option you can set for this MCU, with its current value.",
            "# Copy a line into %s and change it there - =y to switch an" % role,
            "# option on, =n to switch it off and make room. This file is",
            "# regenerated on every build; editing it has no effect.",
            ""]
    for node in kconf.node_iter():
        item = node.item
        if isinstance(item, kconfiglib.Choice) and node.prompt and item.visibility > 0:
            if machine(item):
                continue
            out.append("# %s: one of these is =y. Set by how the chip is" % node.prompt[0])
            out.append("# wired on the board - leave it as it is.")
            out.append("")
            continue
        if not isinstance(item, kconfiglib.Symbol) or not node.prompt:
            continue
        if not settable(kconfiglib, item) or item.name.startswith("MACH_"):
            continue
        out.append("# " + node.prompt[0])
        if node.help:
            for para in node.help.strip().split("\n\n")[:1]:
                for w in textwrap.wrap(" ".join(para.split()), 72):
                    out.append("#   " + w)
        if item.name in user_names:
            where = "set in %s" % role
        elif stock_values.get(item.name) == item.str_value:
            where = "stock"
        else:
            where = "follows another setting"
        value = line(kconfiglib, item, item.str_value)
        out.append("%-44s # %s" % (value, where))
        out.append("")
    sys.stdout.write("\n".join(out))


def diff(klipper, stock, new):
    kconfiglib, kconf = load(klipper, stock)
    stock_values = values(kconfiglib, kconf)
    kconf.load_config(new)
    for sym in kconf.unique_defined_syms:
        if not settable(kconfiglib, sym):
            continue
        if stock_values.get(sym.name) != sym.str_value:
            print(line(kconfiglib, sym, sym.str_value))


def check(klipper, effective, userfile):
    kconfiglib, kconf = load(klipper, effective)
    wanted = {}
    for text in open(userfile):
        m = re.match(r"\s*CONFIG_(\w+)=(.*)$", text.strip())
        if m:
            wanted[m.group(1)] = m.group(2).strip().strip('"')
        m = re.match(r"\s*#\s*CONFIG_(\w+) is not set", text)
        if m:
            wanted[m.group(1)] = "n"
    for name, value in wanted.items():
        sym = kconf.syms.get(name)
        if sym is None or not sym.nodes:
            print("CONFIG_%s: no such option in this Klipper - ignored" % name)
        elif not settable(kconfiglib, sym):
            print("CONFIG_%s: cannot be set on this MCU - ignored" % name)
        elif sym.str_value != value and not (value == "n" and sym.str_value == ""):
            print("CONFIG_%s=%s: is %s, set by another option" % (name, value, sym.str_value or "n"))


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "reference" and len(args) == 5:
        reference(*args)
    elif cmd == "diff" and len(args) == 3:
        diff(*args)
    elif cmd == "check" and len(args) == 3:
        check(*args)
    else:
        sys.exit(__doc__ if __doc__ else "usage: see the header of this file")
