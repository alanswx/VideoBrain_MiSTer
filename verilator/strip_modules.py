# Remove modules from the ghdl-synth netlist so a hand-converted Verilog file
# can take their place. Usage: strip_modules.py netlist.v name [name...]
import re, sys

path, names = sys.argv[1], set(sys.argv[2:])
src = open(path).read()
out, kept, dropped = [], [], []

# ghdl emits "module <name>\n  (ports);\n ... endmodule" with no nesting.
for chunk in re.split(r'(?m)^(?=module\s)', src):
    m = re.match(r'module\s+(\S+)', chunk)
    if m and m.group(1) in names:
        dropped.append(m.group(1))
    else:
        if m: kept.append(m.group(1))
        out.append(chunk)

missing = names - set(dropped)
if missing:
    sys.exit("strip_modules: not in netlist: %s" % ", ".join(sorted(missing)))

open(path, 'w').write("".join(out))
print("stripped: %s" % ", ".join(dropped))
