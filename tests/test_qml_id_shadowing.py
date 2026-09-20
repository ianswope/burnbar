import re, sys
bad = []
for f in ('BarWidget.qml', 'BurnPanel.qml', 'Service.qml'):
    src = open(f).read()
    ids   = set(re.findall(r'^\s*id:\s*([A-Za-z_]\w*)', src, re.M))
    props = set(re.findall(r'^\s*(?:readonly\s+)?property\s+\w+\s+([A-Za-z_]\w*)\s*:', src, re.M))
    shared = ids & props
    if not shared:
        continue
    # strip comments and string literals so declarations/animation targets don't count
    clean = re.sub(r'//[^\n]*', '', src)
    clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.S)
    clean = re.sub(r'"[^"\n]*"', '""', clean)
    clean = re.sub(r"'[^'\n]*'", "''", clean)
    for i, line in enumerate(clean.split('\n'), 1):
        for name in shared:
            if re.match(r'\s*id:\s*%s\b' % name, line):            continue
            if re.match(r'\s*(readonly\s+)?property\s+\w+\s+%s\s*:' % name, line): continue
            for m in re.finditer(r'(?<![.\w])%s\b' % name, line):
                bad.append("%s:%d  unqualified `%s` (also an id, the id wins)\n      %s"
                           % (f, i, name, line.strip()))
if bad:
    print("FAIL: a name that is both an id and a property must always be qualified:")
    for b in bad: print("   " + b)
    sys.exit(1)
print("ok")
