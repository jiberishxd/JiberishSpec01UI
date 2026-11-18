# Peak number of locals active at the top level of each Lua file (the main
# chunk may hold at most 200). Tokenizes, tracks block nesting, and counts
# locals (and for-loop control variables) at nesting depth 0, plus the most
# held at once inside top-level do-blocks.
import re, sys
TOKEN = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|\S', re.S)
def tokens(src):
    for m in TOKEN.finditer(src):
        t = m.group(0)
        if t.startswith('--') or t[0] in '"\'' or t.startswith('[['): continue
        yield t
for p in sys.argv[1:]:
    toks = list(tokens(open(p).read()))
    stack = []          # open block kinds
    counts = [0]        # locals per scope on the do-chain from the main chunk
    peak = 0
    i = 0
    pending_loop = False
    while i < len(toks):
        t = toks[i]
        main_chain = all(k == 'do' for k in stack)
        if t == 'local' and main_chain:
            if toks[i+1] == 'function':
                counts[-1] += 1
            else:
                j = i + 1
                while True:
                    counts[-1] += 1
                    j += 1
                    if j < len(toks) and toks[j] == ',': j += 1; continue
                    break
            peak = max(peak, sum(counts))
        if t == 'function': stack.append('function')
        elif t == 'if': stack.append('if')
        elif t in ('while', 'for'):
            stack.append('loop'); pending_loop = True
            if t == 'for' and all(k == 'do' for k in stack[:-1]):
                peak = max(peak, sum(counts) + 4)
        elif t == 'do':
            if pending_loop: pending_loop = False
            else:
                stack.append('do')
                if all(k == 'do' for k in stack): counts.append(0)
        elif t == 'repeat': stack.append('repeat')
        elif t in ('end', 'until'):
            kind = stack.pop() if stack else None
            if kind == 'do' and all(k == 'do' for k in stack) and len(counts) > 1: counts.pop()
        i += 1
    flag = '  <-- near the 200 limit' if peak > 180 else ''
    if peak > 120: print(f'{peak:4d} {p}{flag}')
