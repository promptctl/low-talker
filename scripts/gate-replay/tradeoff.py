"""One line per design: speech lost after bursts (beyond the silence control) and background talk let in."""
import re, sys
def summary(path):
    rows = [l.rstrip("\n").split("\t") for l in open(path)]
    lost = {}
    for r in rows:
        if len(r) >= 5 and "@" in r[1] and r[4].startswith("lost"):
            m = re.match(r"(knock|bursts|silence)(\d*)@", r[1])
            key = (r[0], r[1].split("@")[1], r[2], r[3])
            lost.setdefault(key, {})[m.group(1) + (m.group(2) or "1")] = float(r[4].split()[1].rstrip("s"))
    out = []
    for n in ["1", "3", "5"]:
        xs = []
        for kinds in lost.values():
            b = kinds.get("bursts" + n)
            if b is not None:
                xs.append(b - kinds.get("silence" + n, 0))
        out.append(f"{n} burst{'s' if n != '1' else ''}: >0.1 s lost in {sum(1 for x in xs if x > 0.1)}/{len(xs)}, worst {max(xs):.1f} s")
    talk = {}
    for r in rows:
        if r[0].startswith("TALK"):
            db = r[1]; past = float(re.search(r"\(([\d.]+)s past", r[3]).group(1))
            talk.setdefault(db, []).append(past)
        if r[0].startswith("SHORT"):
            db = "short " + r[1]; new = float(re.search(r"new ([\d.]+)s", r[3]).group(1)); mk = float(re.search(r"kept ([\d.]+)s", r[2]).group(1))
            talk.setdefault(db, []).append(new - mk)
    t = "; ".join(f"{k}: worst {max(v):.1f} s, {sum(1 for x in v if x > 0.1)}/{len(v)}" for k, v in talk.items() if k.endswith(("-24 dB", "-27 dB", "-30 dB", "-36 dB")))
    return out, t
for name, path in [(a.split("=")[0], a.split("=")[1]) for a in sys.argv[1:]]:
    bursts, talk = summary(path)
    print(f"== {name}\n  lost after bursts: " + " | ".join(bursts) + f"\n  talk let in (long readers past the speech / short presses): {talk}")
