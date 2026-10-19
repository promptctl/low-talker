import sys
def load(p):
    d = {}
    for line in open(p):
        f = line.rstrip("\n").split("\t")
        if len(f) < 6 or not f[4].isdigit():
            continue
        d[tuple(f[:4])] = int(f[4]), f[5]
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
rows = sorted(((b[k][0] - a[k][0]) / 16000, k) for k in a if a[k] != b[k])
for d, k in rows:
    print(f"{d:+.2f}s  {' '.join(k)}")
print(f"# {len(rows)} of {len(a)} differ; fewer samples in {sum(1 for d, _ in rows if d < 0)}, same count in {sum(1 for d, _ in rows if d == 0)}")
