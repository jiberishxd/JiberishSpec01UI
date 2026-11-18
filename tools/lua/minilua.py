"""A small Lua 5.1 interpreter in Python, for running addon tests offline.

Compiles source to Python closures. Covers the language (closures, varargs,
multiple returns, metatables, setfenv/loadfile) and the parts of the standard
library addons commonly use. Not a full implementation: no coroutines, string
patterns are translated to Python regular expressions.
"""
import math
import os
import re
import sys
import time
import functools

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
# lua_static.py sits beside this file.
from lua_static import tokenize, LuaSyntaxError, BINARY, UNARY_PRIORITY  # noqa: E402


class LuaError(Exception):
    def __init__(self, value, where=None):
        super().__init__(value)
        self.value = value
        self.where = where
        self.trace = []

    def __str__(self):
        return f'{tostr(self.value)}' + ''.join(f'\n    at {w}' for w in self.trace[:12])


class Break(Exception):
    pass


class Return(Exception):
    __slots__ = ('values',)

    def __init__(self, values):
        self.values = values


class BoolKey:
    __slots__ = ('v',)

    def __init__(self, v): self.v = v
    def __hash__(self): return hash(('bool', self.v))
    def __eq__(self, other): return isinstance(other, BoolKey) and other.v == self.v


TRUE_KEY, FALSE_KEY = BoolKey(True), BoolKey(False)


def norm(k):
    if k is True: return TRUE_KEY
    if k is False: return FALSE_KEY
    if type(k) is int: return float(k)
    return k


def denorm(k):
    if k is TRUE_KEY: return True
    if k is FALSE_KEY: return False
    return k


class Table:
    __slots__ = ('hash', 'meta', 'keys', 'pos', '__weakref__')

    def __init__(self, items=None):
        self.hash = {}
        self.meta = None
        self.keys = None
        self.pos = None
        if items:
            for k, v in items.items():
                self.rawset(k, v)

    def rawget(self, k):
        return self.hash.get(norm(k))

    def rawset(self, k, v):
        k = norm(k)
        if k is None:
            raise LuaError('table index is nil')
        if isinstance(k, float) and k != k:
            raise LuaError('table index is NaN')
        if v is None:
            self.hash.pop(k, None)
        else:
            if k not in self.hash:
                self.keys = None
            self.hash[k] = v

    def length(self):
        n = 0
        h = self.hash
        while (n + 1.0) in h:
            n += 1
        return n

    def next(self, k):
        if self.keys is None:
            self.keys = list(self.hash.keys())
            self.pos = {key: i for i, key in enumerate(self.keys)}
        if k is None:
            i = 0
        else:
            nk = norm(k)
            if nk not in self.pos:
                # A key added after the snapshot: rebuild and look again.
                self.keys = list(self.hash.keys())
                self.pos = {key: i for i, key in enumerate(self.keys)}
                if nk not in self.pos:
                    raise LuaError("invalid key to 'next'")
            i = self.pos[nk] + 1
        keys, h = self.keys, self.hash
        while i < len(keys):
            key = keys[i]
            v = h.get(key)
            if v is not None:
                return [denorm(key), v]
            i += 1
        return [None]


class Function:
    __slots__ = ('name', 'params', 'vararg', 'body', 'scope', 'fenv', 'line', 'chunk')

    def __repr__(self): return f'function: {self.name}'


class PyFunction:
    __slots__ = ('fn', 'name')

    def __init__(self, fn, name='?'):
        self.fn = fn
        self.name = name


class Frame:
    __slots__ = ('varargs', 'fenv', 'function')

    def __init__(self, varargs, fenv, function):
        self.varargs = varargs
        self.fenv = fenv
        self.function = function


class Scope:
    __slots__ = ('vars', 'parent', 'frame')

    def __init__(self, parent, frame, names=None):
        self.vars = names if names is not None else {}
        self.parent = parent
        self.frame = frame


def ltype(v):
    if v is None: return 'nil'
    if v is True or v is False: return 'boolean'
    t = type(v)
    if t is float or t is int: return 'number'
    if t is str: return 'string'
    if t is Table: return 'table'
    if t is Function or t is PyFunction: return 'function'
    return 'userdata'


def truthy(v):
    return v is not None and v is not False


def fmtnum(n):
    if n != n: return 'nan'
    if n == math.inf: return 'inf'
    if n == -math.inf: return '-inf'
    if n == int(n) and abs(n) < 1e15: return '%d' % n
    return '%.14g' % n


STRING_META = Table()


def tostr(v):
    t = ltype(v)
    if t == 'nil': return 'nil'
    if t == 'boolean': return 'true' if v else 'false'
    if t == 'number': return fmtnum(v)
    if t == 'string': return v
    if t == 'table':
        mt = v.meta
        if mt is not None:
            h = mt.rawget('__tostring')
            if h is not None:
                return first(call(h, [v]))
        return 'table: 0x%08x' % (id(v) & 0xffffffff)
    if t == 'function': return 'function: 0x%08x' % (id(v) & 0xffffffff)
    return 'userdata: 0x%08x' % (id(v) & 0xffffffff)


def tonum(v):
    if v is True or v is False or v is None: return None
    if type(v) in (float, int): return float(v)
    if type(v) is str:
        s = v.strip()
        try:
            if s.lower().startswith(('0x', '-0x')):
                return float(int(s, 16))
            return float(s)
        except ValueError:
            return None
    return None


def first(values):
    return values[0] if values else None


def call(f, args):
    t = type(f)
    if t is Function:
        return call_lua(f, args)
    if t is PyFunction:
        r = f.fn(*args)
        if r is None: return []
        if type(r) is list: return r
        return [r]
    if t is Table and f.meta is not None:
        h = f.meta.rawget('__call')
        if h is not None:
            return call(h, [f] + list(args))
    raise LuaError(f'attempt to call a {ltype(f)} value')


DEPTH = [0]


def call_lua(f, args):
    params = f.params
    n = len(params)
    names = {}
    for i in range(n):
        names[params[i]] = args[i] if i < len(args) else None
    frame = Frame(list(args[n:]) if f.vararg else None, f.fenv, f)
    scope = Scope(f.scope, frame, names)
    DEPTH[0] += 1
    if DEPTH[0] > 3000:
        DEPTH[0] -= 1
        raise LuaError('stack overflow')
    try:
        f.body(scope)
    except Return as r:
        return r.values
    except LuaError as e:
        if len(e.trace) < 30:
            e.trace.append(f'{f.chunk}:{f.line} in {f.name}')
        raise
    finally:
        DEPTH[0] -= 1
    return []


def index(obj, k):
    t = type(obj)
    if t is Table:
        v = obj.hash.get(norm(k))
        if v is not None: return v
        mt = obj.meta
        if mt is None: return None
        h = mt.hash.get('__index')
        if h is None: return None
        if type(h) is Table: return index(h, k)
        return first(call(h, [obj, k]))
    if t is str:
        return index(STRING_META.rawget('__index'), k)
    raise LuaError(f'attempt to index a {ltype(obj)} value' + (f" (field '{k}')" if isinstance(k, str) else ''))


def setindex(obj, k, v):
    if type(obj) is Table:
        mt = obj.meta
        if mt is not None and obj.hash.get(norm(k)) is None:
            h = mt.hash.get('__newindex')
            if h is not None:
                if type(h) is Table:
                    return setindex(h, k, v)
                call(h, [obj, k, v])
                return
        obj.rawset(k, v)
        return
    raise LuaError(f'attempt to index a {ltype(obj)} value' + (f" (field '{k}')" if isinstance(k, str) else ''))


def arith(op, a, b):
    x, y = tonum(a), tonum(b)
    if x is None or y is None:
        bad = a if x is None else b
        raise LuaError(f'attempt to perform arithmetic on a {ltype(bad)} value')
    if op == '+': return x + y
    if op == '-': return x - y
    if op == '*': return x * y
    if op == '/':
        if y == 0:
            if x == 0 or x != x: return math.nan
            return math.inf if x > 0 else -math.inf
        return x / y
    if op == '%':
        if y == 0: return math.nan
        return x - math.floor(x / y) * y
    if op == '^':
        try:
            return math.pow(x, y)
        except (OverflowError, ValueError):
            return math.nan
    raise LuaError('bad op')


def eq(a, b):
    ta, tb = ltype(a), ltype(b)
    if ta != tb: return False
    if ta in ('table', 'function', 'userdata'): return a is b
    return a == b


def lt(a, b):
    ta, tb = ltype(a), ltype(b)
    if ta == tb and ta in ('number', 'string'): return a < b
    raise LuaError(f'attempt to compare {ta} with {tb}')


def le(a, b):
    ta, tb = ltype(a), ltype(b)
    if ta == tb and ta in ('number', 'string'): return a <= b
    raise LuaError(f'attempt to compare {ta} with {tb}')


def concat(a, b):
    for v in (a, b):
        if ltype(v) not in ('string', 'number'):
            raise LuaError(f'attempt to concatenate a {ltype(v)} value')
    return (a if type(a) is str else fmtnum(a)) + (b if type(b) is str else fmtnum(b))


def length(v):
    if type(v) is str: return float(len(v))
    if type(v) is Table: return float(v.length())
    raise LuaError(f'attempt to get length of a {ltype(v)} value')


def unescape(raw):
    if raw.startswith('['):
        m = re.match(r'\[(=*)\[', raw)
        body = raw[m.end():len(raw) - len(m.group(1)) - 2]
        if body.startswith('\r\n'): body = body[2:]
        elif body.startswith('\n'): body = body[1:]
        return body
    body = raw[1:-1]
    out, i = [], 0
    simple = {'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
              '\\': '\\', '"': '"', "'": "'", '\n': '\n'}
    while i < len(body):
        c = body[i]
        if c == '\\':
            i += 1
            c = body[i]
            if c in simple:
                out.append(simple[c]); i += 1
            elif c.isdigit():
                j = i
                while j < len(body) and j - i < 3 and body[j].isdigit(): j += 1
                out.append(chr(int(body[i:j]))); i = j
            else:
                out.append(c); i += 1
        else:
            out.append(c); i += 1
    return ''.join(out)


def parse_number(text):
    if text.lower().startswith('0x'): return float(int(text, 16))
    return float(text)


# Compiler ------------------------------------------------------------------------
class Compiler:
    def __init__(self, source, chunk):
        if source.startswith('\ufeff'): source = source[1:]
        self.tokens = tokenize(source)
        self.pos = 0
        self.chunk = chunk
        self.vararg = [True]

    @property
    def tok(self): return self.tokens[self.pos]

    def peek(self, n=1): return self.tokens[min(self.pos + n, len(self.tokens) - 1)]

    def check(self, value):
        t = self.tok
        return t.kind in ('keyword', 'symbol') and t.value == value

    def accept(self, value):
        if self.check(value):
            self.pos += 1
            return True
        return False

    def expect(self, value):
        if not self.accept(value):
            raise LuaSyntaxError(f'{self.chunk}:{self.tok.line}: {value!r} expected near {self.tok.value!r}')

    def name(self):
        t = self.tok
        if t.kind != 'name':
            raise LuaSyntaxError(f'{self.chunk}:{t.line}: name expected near {t.value!r}')
        self.pos += 1
        return t.value

    def compile_chunk(self):
        body = self.block()
        if self.tok.kind != 'eof':
            raise LuaSyntaxError(f'{self.chunk}:{self.tok.line}: <eof> expected')
        return body

    def block_follow(self):
        t = self.tok
        return t.kind == 'eof' or (t.kind == 'keyword' and t.value in ('else', 'elseif', 'end', 'until'))

    def block(self):
        stmts = []
        chunk = self.chunk
        while not self.block_follow():
            line = self.tok.line
            if self.check('return'):
                self.pos += 1
                if self.block_follow() or self.check(';'):
                    fn = self.ret([])
                else:
                    fn = self.ret(self.exprlist())
                self.accept(';')
                stmts.append((fn, line))
                break
            if self.accept('break'):
                def brk(scope):
                    raise Break()
                stmts.append((brk, line))
                self.accept(';')
                break
            stmts.append((self.statement(), line))
            self.accept(';')

        def run(scope):
            for fn, line in stmts:
                try:
                    nscope = fn(scope)
                except LuaError as e:
                    if e.where is None:
                        e.where = f'{chunk}:{line}'
                        if isinstance(e.value, str) and not e.value.startswith(chunk):
                            e.value = f'{chunk}:{line}: {e.value}'
                    raise
                except (Break, Return):
                    raise
                except RecursionError:
                    raise LuaError(f'{chunk}:{line}: stack overflow')
                except Exception as e:  # interpreter or host bug
                    raise LuaError(f'{chunk}:{line}: internal {type(e).__name__}: {e}')
                if nscope is not None:
                    scope = nscope
            return scope
        return run

    def ret(self, exprs):
        multi = self.multi(exprs)

        def fn(scope):
            raise Return(multi(scope))
        return fn

    def multi(self, exprs):
        """exprs: list of (single, multi). Returns scope -> list of values."""
        if not exprs:
            return lambda scope: []
        singles = [e[0] for e in exprs[:-1]]
        last_single, last_multi = exprs[-1]
        if last_multi is None:
            allsingle = singles + [last_single]
            if len(allsingle) == 1:
                s0 = allsingle[0]
                return lambda scope: [s0(scope)]
            return lambda scope: [s(scope) for s in allsingle]
        if not singles:
            return last_multi

        def fn(scope):
            vals = [s(scope) for s in singles]
            vals.extend(last_multi(scope))
            return vals
        return fn

    def scoped(self):
        body = self.block()

        def run(scope):
            body(Scope(scope, scope.frame))
        return run

    def statement(self):
        if self.accept('if'):
            clauses = []
            cond = self.expr()[0]; self.expect('then'); clauses.append((cond, self.scoped()))
            while self.accept('elseif'):
                cond = self.expr()[0]; self.expect('then'); clauses.append((cond, self.scoped()))
            orelse = self.scoped() if self.accept('else') else None
            self.expect('end')

            def stmt_if(scope):
                for c, b in clauses:
                    if truthy(c(scope)):
                        b(scope)
                        return
                if orelse: orelse(scope)
            return stmt_if
        if self.accept('while'):
            cond = self.expr()[0]; self.expect('do'); body = self.scoped(); self.expect('end')

            def stmt_while(scope):
                try:
                    while truthy(cond(scope)):
                        body(scope)
                except Break:
                    pass
            return stmt_while
        if self.accept('do'):
            body = self.scoped(); self.expect('end')

            def stmt_do(scope):
                body(scope)
            return stmt_do
        if self.accept('for'):
            n1 = self.name()
            if self.accept('='):
                start = self.expr()[0]; self.expect(','); stop = self.expr()[0]
                step = self.expr()[0] if self.accept(',') else None
                self.expect('do'); body = self.block(); self.expect('end')

                def stmt_fornum(scope):
                    a, b = tonum(start(scope)), tonum(stop(scope))
                    c = tonum(step(scope)) if step else 1.0
                    if a is None or b is None or c is None:
                        raise LuaError("'for' initial value must be a number")
                    i = a
                    try:
                        while (c > 0 and i <= b) or (c <= 0 and i >= b):
                            body(Scope(scope, scope.frame, {n1: i}))
                            i += c
                    except Break:
                        pass
                return stmt_fornum
            names = [n1]
            while self.accept(','): names.append(self.name())
            self.expect('in')
            explist = self.multi(self.exprlist())
            self.expect('do'); body = self.block(); self.expect('end')

            def stmt_forin(scope):
                vals = explist(scope)
                f, s, var = (vals + [None, None, None])[:3]
                try:
                    while True:
                        r = call(f, [s, var])
                        v0 = r[0] if r else None
                        if v0 is None: break
                        var = v0
                        bound = {}
                        for i, nm in enumerate(names):
                            bound[nm] = r[i] if i < len(r) else None
                        body(Scope(scope, scope.frame, bound))
                except Break:
                    pass
            return stmt_forin
        if self.accept('repeat'):
            body_stmts = self.block()
            self.expect('until')
            cond = self.expr()[0]

            def stmt_repeat(scope):
                try:
                    while True:
                        # The condition sees the body's locals.
                        last = body_stmts(Scope(scope, scope.frame))
                        if truthy(cond(last)): break
                except Break:
                    pass
            return stmt_repeat
        if self.accept('function'):
            line = self.tokens[self.pos - 1].line
            n = self.name()
            path = [n]
            method = False
            while self.check('.') or self.check(':'):
                method = self.tok.value == ':'
                self.pos += 1
                path.append(self.name())
                if method: break
            label = '.'.join(path)
            fn = self.funcbody(label, line, method)
            if len(path) == 1:
                def stmt_func(scope):
                    assign_name(scope, n, fn(scope))
                return stmt_func
            base, keys = path[0], path[1:]

            def stmt_func_field(scope):
                obj = lookup(scope, base)
                for k in keys[:-1]: obj = index(obj, k)
                setindex(obj, keys[-1], fn(scope))
            return stmt_func_field
        if self.accept('local'):
            if self.accept('function'):
                line = self.tokens[self.pos - 1].line
                n = self.name()
                fn = self.funcbody(n, line, False)

                def stmt_localfunc(scope):
                    new = Scope(scope, scope.frame, {n: None})
                    new.vars[n] = fn(new)
                    return new
                return stmt_localfunc
            names = [self.name()]
            while self.accept(','): names.append(self.name())
            values = self.multi(self.exprlist()) if self.accept('=') else (lambda scope: [])

            def stmt_local(scope):
                vals = values(scope)
                bound = {}
                for i, nm in enumerate(names):
                    bound[nm] = vals[i] if i < len(vals) else None
                return Scope(scope, scope.frame, bound)
            return stmt_local
        return self.exprstat()

    def exprstat(self):
        target = self.suffixed(want_target=True)
        if self.check('=') or self.check(','):
            targets = [target]
            while self.accept(','):
                targets.append(self.suffixed(want_target=True))
            self.expect('=')
            values = self.multi(self.exprlist())
            setters = []
            for t in targets:
                if t[0] != 'target':
                    raise LuaSyntaxError(f'{self.chunk}:{self.tok.line}: cannot assign')
                setters.append(t[1])

            def stmt_assign(scope):
                # Evaluate the targets' tables/keys first, then the values.
                prepared = [s(scope) for s in setters]
                vals = values(scope)
                for i, p in enumerate(prepared):
                    p(vals[i] if i < len(vals) else None)
            return stmt_assign
        if target[0] != 'call':
            raise LuaSyntaxError(f'{self.chunk}:{self.tok.line}: syntax error near {self.tok.value!r}')
        callfn = target[2]

        def stmt_call(scope):
            callfn(scope)
        return stmt_call

    def funcbody(self, label, line, method):
        self.expect('(')
        params = ['self'] if method else []
        vararg = False
        if not self.check(')'):
            while True:
                if self.accept('...'):
                    vararg = True
                    break
                params.append(self.name())
                if not self.accept(','): break
        self.expect(')')
        self.vararg.append(vararg)
        body = self.block()
        self.vararg.pop()
        self.expect('end')
        chunk = self.chunk

        def make(scope):
            f = Function()
            f.name, f.params, f.vararg, f.body, f.scope = label, params, vararg, body, scope
            f.fenv = scope.frame.fenv
            f.line, f.chunk = line, chunk
            return f
        return make

    def exprlist(self):
        exprs = [self.expr()]
        while self.accept(','):
            exprs.append(self.expr())
        return exprs

    # Expressions return (single, multi|None)
    def primary(self):
        t = self.tok
        if t.kind == 'name':
            self.pos += 1
            n = t.value
            return ('name', n)
        if self.accept('('):
            e = self.expr()[0]
            self.expect(')')
            return ('value', e)
        raise LuaSyntaxError(f'{self.chunk}:{t.line}: unexpected symbol near {t.value!r}')

    def suffixed(self, want_target=False):
        kind, data = self.primary()
        if kind == 'name':
            n = data

            def cur(scope):
                return lookup(scope, n)
            name_only = n
        else:
            cur = data
            name_only = None
        last = None  # ('index', objfn, keyfn) | ('call', fn)
        while True:
            if self.check('.') or self.check('['):
                if self.accept('.'):
                    k = self.name()
                    keyfn = (lambda k: (lambda scope: k))(k)
                else:
                    self.pos += 1
                    keyfn = self.expr()[0]
                    self.expect(']')
                objfn = cur
                cur = (lambda o, kf: (lambda scope: index(o(scope), kf(scope))))(objfn, keyfn)
                last = ('index', objfn, keyfn)
                name_only = None
            elif self.check(':'):
                self.pos += 1
                m = self.name()
                args = self.callargs()
                objfn = cur

                def mcall(scope, o=objfn, m=m, args=args):
                    obj = o(scope)
                    f = index(obj, m)
                    if f is None:
                        raise LuaError(f"attempt to call method '{m}' (a nil value)")
                    return call(f, [obj] + args(scope))
                cur = (lambda mc: (lambda scope: first(mc(scope))))(mcall)
                last = ('call', mcall)
                name_only = None
            elif self.check('(') or self.check('{') or self.tok.kind == 'string':
                args = self.callargs()
                fnexpr = cur
                fname = name_only

                def fcall(scope, f=fnexpr, args=args, fname=fname):
                    fv = f(scope)
                    if fv is None and fname:
                        raise LuaError(f"attempt to call global '{fname}' (a nil value)" if not is_local(scope, fname)
                                       else f"attempt to call local '{fname}' (a nil value)")
                    return call(fv, args(scope))
                cur = (lambda fc: (lambda scope: first(fc(scope))))(fcall)
                last = ('call', fcall)
                name_only = None
            else:
                break
        if want_target:
            if last is None and kind == 'name':
                n = data

                def prep_name(scope):
                    return lambda v: assign_name(scope, n, v)
                return ('target', prep_name)
            if last is not None and last[0] == 'index':
                objfn, keyfn = last[1], last[2]

                def prep_index(scope):
                    o, k = objfn(scope), keyfn(scope)
                    return lambda v: setindex(o, k, v)
                return ('target', prep_index)
            if last is not None and last[0] == 'call':
                return ('call', None, last[1])
            return ('value', cur)
        if last is not None and last[0] == 'call':
            return (cur, last[1])
        return (cur, None)

    def callargs(self):
        t = self.tok
        if t.kind == 'string':
            self.pos += 1
            s = unescape(t.value)
            return lambda scope: [s]
        if self.check('{'):
            tf = self.table()
            return lambda scope: [tf(scope)]
        self.expect('(')
        if self.check(')'):
            self.pos += 1
            return lambda scope: []
        m = self.multi(self.exprlist())
        self.expect(')')
        return m

    def table(self):
        self.expect('{')
        array, keyed = [], []
        while not self.check('}'):
            if self.check('['):
                self.pos += 1
                k = self.expr()[0]; self.expect(']'); self.expect('=')
                keyed.append((len(array), k, self.expr()[0]))
            elif self.tok.kind == 'name' and self.peek().kind == 'symbol' and self.peek().value == '=':
                k = self.tok.value
                self.pos += 2
                keyed.append((len(array), (lambda k: (lambda s: k))(k), self.expr()[0]))
            else:
                array.append(self.expr())
            if not (self.accept(',') or self.accept(';')):
                break
        self.expect('}')
        arr = self.multi(array) if array else None
        nonnil_last = array and array[-1][1] is not None

        def build(scope):
            t = Table()
            for _, k, v in keyed:
                kv = k(scope)
                vv = v(scope)
                if vv is not None:
                    t.rawset(kv, vv)
            if arr:
                vals = arr(scope)
                for i, v in enumerate(vals):
                    if v is not None:
                        t.rawset(float(i + 1), v)
            return t
        return build

    def simple(self):
        t = self.tok
        if t.kind == 'number':
            self.pos += 1
            v = parse_number(t.value)
            return (lambda s: v, None)
        if t.kind == 'string':
            self.pos += 1
            v = unescape(t.value)
            return (lambda s: v, None)
        if t.kind == 'keyword' and t.value in ('nil', 'true', 'false'):
            self.pos += 1
            v = {'nil': None, 'true': True, 'false': False}[t.value]
            return (lambda s: v, None)
        if self.check('...'):
            self.pos += 1

            def va_multi(scope):
                return list(scope.frame.varargs or [])

            def va_single(scope):
                v = scope.frame.varargs
                return v[0] if v else None
            return (va_single, va_multi)
        if self.check('{'):
            return (self.table(), None)
        if self.accept('function'):
            return (self.funcbody('anonymous', t.line, False), None)
        return self.suffixed()

    def expr(self, limit=0):
        t = self.tok
        if (t.kind == 'keyword' and t.value == 'not') or (t.kind == 'symbol' and t.value in ('-', '#')):
            self.pos += 1
            operand = self.expr(UNARY_PRIORITY)[0]
            op = t.value
            if op == 'not':
                left = lambda s: not truthy(operand(s))
            elif op == '-':
                def left(s):
                    v = tonum(operand(s))
                    if v is None: raise LuaError(f'attempt to perform arithmetic on a {ltype(operand(s))} value')
                    return -v
            else:
                left = lambda s: length(operand(s))
            result = (left, None)
        else:
            result = self.simple()
        while True:
            t = self.tok
            op = t.value if t.kind in ('keyword', 'symbol') else None
            if op not in BINARY or BINARY[op][0] <= limit:
                return result
            self.pos += 1
            right = self.expr(BINARY[op][1])[0]
            left = result[0]
            result = (binop(op, left, right), None)


def binop(op, a, b):
    if op == 'and':
        def f(s):
            v = a(s)
            return b(s) if truthy(v) else v
    elif op == 'or':
        def f(s):
            v = a(s)
            return v if truthy(v) else b(s)
    elif op == '==':
        f = lambda s: eq(a(s), b(s))
    elif op == '~=':
        f = lambda s: not eq(a(s), b(s))
    elif op == '<':
        f = lambda s: lt(a(s), b(s))
    elif op == '>':
        f = lambda s: lt(b(s), a(s))
    elif op == '<=':
        f = lambda s: le(a(s), b(s))
    elif op == '>=':
        f = lambda s: le(b(s), a(s))
    elif op == '..':
        f = lambda s: concat(a(s), b(s))
    else:
        def f(s):
            x, y = a(s), b(s)
            if type(x) is float and type(y) is float:
                if op == '+': return x + y
                if op == '-': return x - y
                if op == '*': return x * y
            return arith(op, x, y)
    return f


def lookup(scope, name):
    s = scope
    while s is not None:
        v = s.vars
        if name in v:
            return v[name]
        s = s.parent
    return index(scope.frame.fenv, name)


def is_local(scope, name):
    s = scope
    while s is not None:
        if name in s.vars: return True
        s = s.parent
    return False


def assign_name(scope, name, value):
    s = scope
    while s is not None:
        if name in s.vars:
            s.vars[name] = value
            return
        s = s.parent
    setindex(scope.frame.fenv, name, value)


# Runtime ----------------------------------------------------------------------------
class Lua:
    def __init__(self):
        self.G = Table()
        self.install()

    def load(self, source, chunk='chunk', fenv=None):
        body = Compiler(source, chunk).compile_chunk()
        f = Function()
        f.name, f.params, f.vararg, f.body = 'main chunk', [], True, body
        f.scope = None
        f.fenv = fenv or self.G
        f.line, f.chunk = 0, chunk
        return f

    def run_file(self, path, *args):
        with open(path, encoding='utf-8-sig') as h:
            f = self.load(h.read(), os.path.basename(path))
        return call(f, list(args))

    def install(self):
        G = self.G
        lua = self

        def reg(name, fn, table=None):
            (table or G).rawset(name, PyFunction(fn, name))

        G.rawset('_G', G)
        G.rawset('_VERSION', 'Lua 5.1')

        def lprint(*args):
            print('\t'.join(tostr(a) for a in args))
        reg('print', lprint)
        def ltypefn(*a):
            if not a: raise LuaError("bad argument #1 to 'type' (value expected)")
            return ltype(a[0])
        reg('type', ltypefn)
        reg('tostring', lambda v=None, *a: tostr(v))

        def ltonumber(v=None, base=None, *a):
            if base is not None and base != 10:
                try:
                    return float(int(str(v).strip(), int(base)))
                except ValueError:
                    return None
            return tonum(v)
        reg('tonumber', ltonumber)
        reg('rawget', lambda t, k=None, *a: t.rawget(k))

        def lrawset(t, k, v=None, *a):
            t.rawset(k, v)
            return t
        reg('rawset', lrawset)
        reg('rawequal', lambda a=None, b=None, *x: eq(a, b) if ltype(a) not in ('number',) else a == b)

        def lsetmetatable(t, mt=None, *a):
            if type(t) is not Table: raise LuaError("bad argument #1 to 'setmetatable' (table expected)")
            t.meta = mt
            return t
        reg('setmetatable', lsetmetatable)

        def lgetmetatable(t=None, *a):
            if type(t) is Table: return t.meta
            if type(t) is str: return STRING_META
            return None
        reg('getmetatable', lgetmetatable)

        def lnext(t, k=None, *a):
            if type(t) is not Table: raise LuaError("bad argument #1 to 'next' (table expected)")
            return t.next(k)
        nextfn = PyFunction(lnext, 'next')
        G.rawset('next', nextfn)

        def lpairs(t=None, *a):
            if type(t) is not Table: raise LuaError(f"bad argument #1 to 'pairs' (table expected, got {ltype(t)})")
            return [nextfn, t, None]
        reg('pairs', lpairs)

        def inext(t, i):
            i = i + 1
            v = index(t, i)
            if v is None: return [None]
            return [i, v]
        inextfn = PyFunction(inext, 'ipairs_iter')

        def lipairs(t=None, *a):
            if type(t) is not Table: raise LuaError(f"bad argument #1 to 'ipairs' (table expected, got {ltype(t)})")
            return [inextfn, t, 0.0]
        reg('ipairs', lipairs)

        def lselect(n, *args):
            if n == '#': return float(len(args))
            n = int(tonum(n))
            if n < 0: n = len(args) + n + 1
            if n < 1: raise LuaError("bad argument #1 to 'select' (index out of range)")
            return list(args[n - 1:])
        reg('select', lselect)

        def lunpack(t, i=None, j=None, *a):
            i = int(i) if i is not None else 1
            j = int(j) if j is not None else t.length()
            return [t.rawget(float(k)) for k in range(i, j + 1)]
        reg('unpack', lunpack)

        def lerror(msg=None, level=1, *a):
            raise LuaError(msg)
        reg('error', lerror)

        def lassert(v=None, msg=None, *rest):
            if not truthy(v):
                raise LuaError(msg if msg is not None else 'assertion failed!')
            return [v, msg] + list(rest)
        reg('assert', lassert)

        def lpcall(f=None, *args):
            try:
                return [True] + call(f, list(args))
            except LuaError as e:
                return [False, e.value]
            except (Break, Return):
                raise
            except RecursionError:
                return [False, 'stack overflow']
        reg('pcall', lpcall)

        def lxpcall(f, handler, *args):
            try:
                return [True] + call(f, list(args))
            except LuaError as e:
                return [False] + call(handler, [e.value])
        reg('xpcall', lxpcall)

        def lsetfenv(f, t, *a):
            if type(f) is Function:
                f.fenv = t
                return f
            raise LuaError('setfenv: only functions are supported')
        reg('setfenv', lsetfenv)
        reg('getfenv', lambda f=None, *a: f.fenv if type(f) is Function else G)

        def lloadstring(src, chunk=None, *a):
            try:
                return lua.load(src, chunk or src[:40])
            except LuaSyntaxError as e:
                return [None, str(e)]
        reg('loadstring', lloadstring)
        reg('load', lloadstring)

        def lloadfile(path, *a):
            try:
                with open(path, encoding='utf-8-sig') as h:
                    return lua.load(h.read(), path)
            except (OSError, LuaSyntaxError) as e:
                return [None, str(e)]
        reg('loadfile', lloadfile)

        def ldofile(path, *a):
            f = lloadfile(path)
            if type(f) is list: raise LuaError(f[1])
            return call(f, [])
        reg('dofile', ldofile)
        reg('collectgarbage', lambda *a: 0.0)

        # math
        M = Table()
        G.rawset('math', M)
        for name, fn in {
            'floor': lambda x, *a: float(math.floor(tonum(x))), 'ceil': lambda x, *a: float(math.ceil(tonum(x))),
            'abs': lambda x, *a: abs(tonum(x)), 'sqrt': lambda x, *a: math.sqrt(tonum(x)),
            'sin': lambda x, *a: math.sin(tonum(x)), 'cos': lambda x, *a: math.cos(tonum(x)),
            'tan': lambda x, *a: math.tan(tonum(x)), 'exp': lambda x, *a: math.exp(tonum(x)),
            'log': lambda x, *a: math.log(tonum(x)), 'log10': lambda x, *a: math.log10(tonum(x)),
            'pow': lambda x, y, *a: math.pow(tonum(x), tonum(y)), 'fmod': lambda x, y, *a: math.fmod(tonum(x), tonum(y)),
            'atan': lambda x, *a: math.atan(tonum(x)), 'atan2': lambda y, x, *a: math.atan2(tonum(y), tonum(x)),
            'random': lambda *a: 0.5 if not a else float(int(tonum(a[0])) if len(a) == 1 else int(tonum(a[0]))),
            'randomseed': lambda *a: None, 'rad': lambda x, *a: math.radians(tonum(x)),
            'deg': lambda x, *a: math.degrees(tonum(x)),
        }.items():
            reg(name, fn, M)

        def lmax(*args):
            vals = [tonum(a) for a in args]
            if any(v is None for v in vals) or not vals: raise LuaError("bad argument to 'max' (number expected)")
            return max(vals)

        def lmin(*args):
            vals = [tonum(a) for a in args]
            if any(v is None for v in vals) or not vals: raise LuaError("bad argument to 'min' (number expected)")
            return min(vals)
        reg('max', lmax, M)
        reg('min', lmin, M)

        def lmodf(x, *a):
            x = tonum(x)
            ip = float(math.trunc(x))
            return [ip, x - ip]
        reg('modf', lmodf, M)
        M.rawset('pi', math.pi)
        M.rawset('huge', math.inf)

        # table
        T = Table()
        G.rawset('table', T)

        def tinsert(t, *args):
            if len(args) == 1:
                t.rawset(float(t.length() + 1), args[0])
            else:
                pos, v = int(tonum(args[0])), args[1]
                n = t.length()
                for i in range(n, pos - 1, -1):
                    t.rawset(float(i + 1), t.rawget(float(i)))
                t.rawset(float(pos), v)
        reg('insert', tinsert, T)

        def tremove(t, pos=None, *a):
            n = t.length()
            if n == 0: return None
            pos = n if pos is None else int(tonum(pos))
            v = t.rawget(float(pos))
            for i in range(pos, n):
                t.rawset(float(i), t.rawget(float(i + 1)))
            t.rawset(float(n), None)
            return v
        reg('remove', tremove, T)

        def tconcat(t, sep='', i=None, j=None, *a):
            i = 1 if i is None else int(i)
            j = t.length() if j is None else int(j)
            parts = []
            for k in range(i, j + 1):
                v = t.rawget(float(k))
                if ltype(v) not in ('string', 'number'): raise LuaError("invalid value in table for 'concat'")
                parts.append(tostr(v))
            return (sep if type(sep) is str else tostr(sep)).join(parts)
        reg('concat', tconcat, T)

        def tsort(t, comp=None, *a):
            n = t.length()
            vals = [t.rawget(float(i)) for i in range(1, n + 1)]
            if comp is None:
                key = functools.cmp_to_key(lambda x, y: -1 if lt(x, y) else (1 if lt(y, x) else 0))
            else:
                key = functools.cmp_to_key(lambda x, y: -1 if truthy(first(call(comp, [x, y])))
                                           else (1 if truthy(first(call(comp, [y, x]))) else 0))
            vals.sort(key=key)
            for i, v in enumerate(vals):
                t.rawset(float(i + 1), v)
        reg('sort', tsort, T)
        reg('getn', lambda t, *a: float(t.length()), T)
        reg('maxn', lambda t, *a: max([k for k in t.hash if type(k) is float] or [0.0]), T)

        # string
        S = Table()
        G.rawset('string', S)
        STRING_META.rawset('__index', S)

        def ssub(s, i=1.0, j=-1.0, *a):
            s = tostr(s)
            n = len(s)
            i, j = int(tonum(i)), int(tonum(j))
            if i < 0: i = max(n + i + 1, 1)
            elif i == 0: i = 1
            if j < 0: j = n + j + 1
            elif j > n: j = n
            return s[i - 1:j] if i <= j else ''
        reg('sub', ssub, S)
        reg('len', lambda s, *a: float(len(s)), S)
        reg('upper', lambda s, *a: tostr(s).upper(), S)
        reg('lower', lambda s, *a: tostr(s).lower(), S)
        reg('rep', lambda s, n, sep=None, *a: (tostr(s) * int(tonum(n))) if not sep else tostr(sep).join([tostr(s)] * int(tonum(n))), S)
        reg('reverse', lambda s, *a: tostr(s)[::-1], S)

        def sbyte(s, i=1.0, j=None, *a):
            s = tostr(s)
            i = int(tonum(i))
            j = i if j is None else int(tonum(j))
            if i < 0: i = len(s) + i + 1
            if j < 0: j = len(s) + j + 1
            return [float(ord(c)) for c in s[i - 1:j]]
        reg('byte', sbyte, S)
        reg('char', lambda *a: ''.join(chr(int(tonum(c))) for c in a), S)
        reg('format', lambda fmt, *a: lformat(fmt, a), S)

        def sfind(s, pat, init=1.0, plain=None, *a):
            s, pat = tostr(s), tostr(pat)
            init = int(tonum(init)) if init is not None else 1
            if init < 0: init = max(len(s) + init + 1, 1)
            if init == 0: init = 1
            if truthy(plain) or not re.search(r'[\^\$\*\+\?\.\(\)\[\]%\-]', pat):
                k = s.find(pat, init - 1)
                return [None] if k < 0 else [float(k + 1), float(k + len(pat))]
            rx, anchored = lua_pattern(pat)
            m = rx.match(s, init - 1) if anchored else rx.search(s, init - 1)
            if not m: return [None]
            return [float(m.start() + 1), float(m.end())] + captures(m, False)
        reg('find', sfind, S)

        def smatch(s, pat, init=1.0, *a):
            s = tostr(s)
            init = int(tonum(init)) if init is not None else 1
            if init < 0: init = max(len(s) + init + 1, 1)
            rx, anchored = lua_pattern(tostr(pat))
            m = rx.match(s, max(init - 1, 0)) if anchored else rx.search(s, max(init - 1, 0))
            if not m: return [None]
            return captures(m, True)
        reg('match', smatch, S)

        def sgmatch(s, pat, *a):
            s = tostr(s)
            rx, anchored = lua_pattern(tostr(pat))
            it = iter(rx.finditer(s)) if not anchored else iter([m for m in [rx.match(s)] if m])

            def step(*a):
                try:
                    m = next(it)
                except StopIteration:
                    return [None]
                return captures(m, True)
            return PyFunction(step, 'gmatch_iter')
        reg('gmatch', sgmatch, S)

        def sgsub(s, pat, repl, n=None, *a):
            s = tostr(s)
            rx, anchored = lua_pattern(tostr(pat))
            limit = int(tonum(n)) if n is not None else -1
            count = [0]
            out, pos = [], 0
            while limit < 0 or count[0] < limit:
                m = rx.match(s, pos) if anchored and pos == 0 else (None if anchored else rx.search(s, pos))
                if not m: break
                caps = captures(m, True)
                whole = m.group(0)
                if type(repl) is str or ltype(repl) == 'number':
                    r = tostr(repl)

                    def sub_ref(mm):
                        c = mm.group(1)
                        if c == '%': return '%'
                        k = int(c)
                        if k == 0: return whole
                        v = caps[k - 1] if k - 1 < len(caps) else None
                        return tostr(v)
                    value = re.sub(r'%([0-9%])', sub_ref, r)
                elif type(repl) is Table:
                    v = index(repl, caps[0])
                    value = whole if not truthy(v) else tostr(v)
                else:
                    v = first(call(repl, caps))
                    value = whole if not truthy(v) else tostr(v)
                out.append(s[pos:m.start()])
                out.append(value)
                count[0] += 1
                if m.end() == m.start():
                    if m.start() < len(s): out.append(s[m.start()])
                    pos = m.end() + 1
                else:
                    pos = m.end()
                if pos > len(s) or anchored: break
            out.append(s[pos:])
            return [''.join(out), float(count[0])]
        reg('gsub', sgsub, S)

        # os
        O = Table()
        G.rawset('os', O)
        reg('time', lambda *a: float(int(time.time())), O)
        reg('clock', lambda *a: time.process_time(), O)
        reg('date', lambda fmt='%c', *a: time.strftime(fmt.lstrip('!').replace('*t', '%c')), O)
        reg('getenv', lambda k, *a: os.environ.get(k), O)
        reg('exit', lambda code=0, *a: sys.exit(int(code) if code is not True else 0), O)
        io = Table()
        G.rawset('io', io)
        reg('write', lambda *a: sys.stdout.write(''.join(tostr(x) for x in a)), io)

        def iopen(path, mode='r', *a):
            try:
                handle = open(tostr(path), mode.replace('b', '') + 'b' if 'b' not in mode else mode)
            except OSError as e:
                return [None, str(e)]
            f = Table()
            def fread(self, fmt='*a', *x):
                data = handle.read()
                return data.decode('latin-1')
            def fwrite(self, *x):
                handle.write(''.join(tostr(v) for v in x).encode('latin-1'))
                return self
            def fclose(self, *x):
                handle.close()
                return True
            reg('read', fread, f); reg('write', fwrite, f); reg('close', fclose, f)
            return f
        reg('open', iopen, io)


def captures(m, whole_if_none):
    groups = m.groups()
    if not groups:
        return [m.group(0)] if whole_if_none else []
    out = []
    for i, g in enumerate(groups):
        if m.re.groupindex and f'pos{i+1}' in m.re.groupindex:
            out.append(float(m.start(f'pos{i+1}') + 1))
        else:
            out.append(g)
    return out


CLASSES = {'a': r'A-Za-z', 'd': r'0-9', 'l': r'a-z', 's': r'\s', 'u': r'A-Z', 'w': r'A-Za-z0-9',
           'x': r'0-9A-Fa-f', 'p': r'!-/:-@\[-`{-~', 'c': r'\x00-\x1f\x7f', 'g': r'!-~'}
_PATTERNS = {}


def lua_pattern(pat):
    if pat in _PATTERNS: return _PATTERNS[pat]
    out = []
    i, n = 0, len(pat)
    anchored = False
    groups = 0
    if pat.startswith('^'):
        anchored = True
        i = 1
    while i < n:
        c = pat[i]
        if c == '%':
            i += 1
            d = pat[i]
            if d.lower() in CLASSES:
                cls = CLASSES[d.lower()]
                out.append(f'[^{cls}]' if d.isupper() else f'[{cls}]')
            elif d == 'b':
                raise LuaError('%b patterns are not supported')
            elif d == 'f':
                raise LuaError('%f patterns are not supported')
            elif d.isdigit():
                out.append(f'(?:\\{d})')
            else:
                out.append(re.escape(d))
            i += 1
        elif c == '[':
            j = i + 1
            parts = ['[']
            if j < n and pat[j] == '^':
                parts.append('^'); j += 1
            first_char = True
            while j < n and (pat[j] != ']' or first_char):
                ch = pat[j]
                first_char = False
                if ch == '%' and j + 1 < n:
                    d = pat[j + 1]
                    if d.lower() in CLASSES:
                        if d.isupper():
                            raise LuaError('negated class in set not supported')
                        parts.append(CLASSES[d.lower()])
                    else:
                        parts.append(re.escape(d))
                    j += 2
                elif ch == '-' and parts[-1] != '[' and j + 1 < n and pat[j + 1] != ']':
                    parts.append('-'); j += 1
                elif ch in '\\]^[':
                    parts.append('\\' + ch); j += 1
                else:
                    parts.append(ch); j += 1
            parts.append(']')
            out.append(''.join(parts))
            i = j + 1
        elif c == '(':
            groups += 1
            if i + 1 < n and pat[i + 1] == ')':
                out.append(f'(?P<pos{groups}>)')
                i += 2
            else:
                out.append('(')
                i += 1
        elif c == ')':
            out.append(')'); i += 1
        elif c == '.':
            out.append('.'); i += 1
        elif c == '$' and i == n - 1:
            out.append(r'\Z'); i += 1
        elif c in '*+?':
            out.append(c); i += 1
        elif c == '-':
            if out:
                out.append('*?')
            else:
                out.append(re.escape(c))
            i += 1
        else:
            out.append(re.escape(c)); i += 1
    rx = re.compile(''.join(out), re.S)
    _PATTERNS[pat] = (rx, anchored)
    return rx, anchored


FORMAT = re.compile(r'%([-+ #0]*)(\d*)(?:\.(\d+))?([diouxXeEfgGqsc%])')


def lformat(fmt, args):
    fmt = tostr(fmt)
    args = list(args)
    pos = [0]

    def nxt():
        if pos[0] >= len(args):
            raise LuaError(f"bad argument #{pos[0] + 2} to 'format' (no value)")
        v = args[pos[0]]
        pos[0] += 1
        return v

    def repl(m):
        flags, width, prec, conv = m.groups()
        if conv == '%': return '%'
        spec = '%' + flags + width + ('.' + prec if prec is not None else '')
        v = nxt()
        if conv in 'diouxXc':
            num = tonum(v)
            if num is None: raise LuaError(f"bad argument to 'format' (number expected, got {ltype(v)})")
            if conv == 'c': return chr(int(num))
            return (spec + ('d' if conv in 'iu' else conv)) % int(num)
        if conv in 'eEfgG':
            num = tonum(v)
            if num is None: raise LuaError(f"bad argument to 'format' (number expected, got {ltype(v)})")
            return (spec + conv) % num
        if conv == 'q':
            return '"' + tostr(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
        return (spec + 's') % tostr(v)
    return FORMAT.sub(repl, fmt)


def main(argv):
    import threading
    sys.setrecursionlimit(100000)
    threading.stack_size(512 * 1024 * 1024)
    result = {}

    def run():
        lua = Lua()
        try:
            lua.run_file(argv[0], *argv[1:])
            result['ok'] = True
        except LuaError as e:
            print('lua: ' + str(e), file=sys.stderr)
            result['ok'] = False
        except LuaSyntaxError as e:
            print('lua: syntax error: ' + str(e), file=sys.stderr)
            result['ok'] = False
    thread = threading.Thread(target=run)
    thread.start()
    thread.join()
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
