"""Minimal Lua 5.1 syntax checker with scope analysis (no Lua runtime needed).

Parses each file with a recursive-descent parser for the full 5.1 grammar and
reports syntax errors, plus every global name read or written, so typos in
local names show up as unexpected globals.
"""
import re
import sys
from pathlib import Path

KEYWORDS = {'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'if', 'in', 'local',
            'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'}
TOKEN = re.compile(r'''
    (?P<ws>[ \t\r\n]+)
  | (?P<comment>--(?:\[(?P<ceq>=*)\[.*?\](?P=ceq)\]|[^\n]*))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<number>0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<lstring>\[(?P<seq>=*)\[.*?\](?P=seq)\])
  | (?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<op>\.\.\.|\.\.|==|~=|<=|>=|[-+*/%^\#<>=(){}\[\];:,.])
''', re.S | re.X)


class LuaError(Exception):
    pass


def lex(source):
    tokens, pos, line = [], 0, 1
    while pos < len(source):
        match = TOKEN.match(source, pos)
        if not match:
            raise LuaError(f'line {line}: unexpected character {source[pos]!r}')
        kind, text = match.lastgroup, match.group()
        if match.group('comment') is not None:
            kind = 'comment'
        elif match.group('lstring') is not None:
            kind = 'string'
        elif kind in ('ceq', 'seq'):
            kind = 'comment' if match.group('comment') is not None else 'string'
        if kind == 'name' and text in KEYWORDS:
            kind = text
        elif kind == 'op':
            kind = text
        if kind not in ('ws', 'comment'):
            tokens.append((kind, text, line))
        line += text.count('\n')
        pos = match.end()
    tokens.append(('eof', '', line))
    return tokens


class Parser:
    def __init__(self, tokens):
        self.tokens, self.index = tokens, 0
        self.scopes = [set()]
        self.globals_read, self.globals_written = {}, {}
        self.loop_depth = [0]

    # token helpers
    @property
    def kind(self): return self.tokens[self.index][0]
    @property
    def line(self): return self.tokens[self.index][2]

    def error(self, message):
        kind, text, line = self.tokens[self.index]
        raise LuaError(f'line {line}: {message} near {text or kind!r}')

    def accept(self, kind):
        if self.kind == kind:
            self.index += 1
            return True
        return False

    def expect(self, kind):
        if self.kind != kind:
            self.error(f'expected {kind!r}')
        token = self.tokens[self.index]
        self.index += 1
        return token

    # scopes
    def declare(self, name): self.scopes[-1].add(name)

    def resolve(self, name, line, write=False):
        if any(name in scope for scope in self.scopes):
            return
        (self.globals_written if write else self.globals_read).setdefault(name, line)

    def block(self, names=(), new_function=False):
        self.scopes.append(set(names))
        if new_function:
            self.loop_depth.append(0)
        while self.kind not in ('eof', 'end', 'else', 'elseif', 'until'):
            if self.kind == 'return':
                self.index += 1
                if self.kind not in ('eof', 'end', 'else', 'elseif', 'until', ';'):
                    self.explist()
                self.accept(';')
                if self.kind not in ('eof', 'end', 'else', 'elseif', 'until'):
                    self.error("'return' must be the last statement in a block")
                break
            if self.kind == 'break':
                if not self.loop_depth[-1]:
                    self.error("'break' outside a loop")
                self.index += 1
                self.accept(';')
                if self.kind not in ('eof', 'end', 'else', 'elseif', 'until'):
                    self.error("'break' must be the last statement in a block")
                break
            self.statement()
            self.accept(';')
        if new_function:
            self.loop_depth.pop()
        return self.scopes.pop()

    def loop_block(self, names=()):
        self.loop_depth[-1] += 1
        self.block(names)
        self.loop_depth[-1] -= 1

    def statement(self):
        kind = self.kind
        if kind == 'do':
            self.index += 1; self.block(); self.expect('end')
        elif kind == 'while':
            self.index += 1; self.exp(); self.expect('do'); self.loop_block(); self.expect('end')
        elif kind == 'repeat':
            self.index += 1
            self.loop_depth[-1] += 1
            self.scopes.append(set())
            while self.kind not in ('eof', 'until'):
                if self.kind in ('end', 'else', 'elseif'):
                    self.error("expected 'until'")
                if self.kind == 'return':
                    self.index += 1
                    if self.kind not in ('until', ';'): self.explist()
                    self.accept(';'); break
                if self.kind == 'break':
                    self.index += 1; self.accept(';'); break
                self.statement(); self.accept(';')
            self.expect('until'); self.exp()
            self.scopes.pop(); self.loop_depth[-1] -= 1
        elif kind == 'if':
            self.index += 1; self.exp(); self.expect('then'); self.block()
            while self.kind == 'elseif':
                self.index += 1; self.exp(); self.expect('then'); self.block()
            if self.accept('else'): self.block()
            self.expect('end')
        elif kind == 'for':
            self.index += 1
            names = [self.expect('name')[1]]
            if self.accept('='):
                self.exp(); self.expect(','); self.exp()
                if self.accept(','): self.exp()
            else:
                while self.accept(','): names.append(self.expect('name')[1])
                self.expect('in'); self.explist()
            self.expect('do'); self.loop_block(names); self.expect('end')
        elif kind == 'function':
            self.index += 1
            name, line = self.expect('name')[1], self.line
            self.resolve(name, line, write=self.kind not in ('.', ':'))
            method = False
            while self.kind in ('.', ':'):
                method = self.kind == ':'
                self.index += 1; self.expect('name')
                if method: break
            self.funcbody(method)
        elif kind == 'local':
            self.index += 1
            if self.accept('function'):
                name = self.expect('name')[1]
                self.declare(name)
                self.funcbody(False)
            else:
                names = [self.expect('name')[1]]
                while self.accept(','): names.append(self.expect('name')[1])
                if self.accept('='): self.explist()
                for name in names: self.declare(name)
        else:
            self.exprstat()

    def funcbody(self, method):
        self.expect('(')
        params = ['self'] if method else []
        if self.kind != ')':
            while True:
                if self.accept('...'):
                    params.append('...'); break
                params.append(self.expect('name')[1])
                if not self.accept(','): break
        self.expect(')')
        self.block(params, new_function=True)
        self.expect('end')

    def exprstat(self):
        start = self.index
        kind = self.primaryexp(assign_target=True)
        if self.kind in ('=', ','):
            targets = [(kind, start)]
            while self.accept(','):
                start = self.index
                targets.append((self.primaryexp(assign_target=True), start))
            self.expect('=')
            self.explist()
            for target, at in targets:
                if target == 'call':
                    self.error('cannot assign to a function call')
                if target == 'name':
                    _, text, line = self.tokens[at]
                    self.resolve(text, line, write=True)
        elif kind != 'call':
            self.error('expression is not a statement (expected a call or an assignment)')

    def primaryexp(self, assign_target=False):
        """Returns 'name', 'index', 'call' or 'paren'."""
        if self.kind == 'name':
            _, text, line = self.tokens[self.index]
            self.index += 1
            kind = 'name'
            pending = (text, line)
        elif self.accept('('):
            self.exp(); self.expect(')')
            kind, pending = 'paren', None
        else:
            self.error('unexpected symbol')
        while True:
            if self.kind == '.':
                self.index += 1; self.expect('name'); new = 'index'
            elif self.kind == '[':
                self.index += 1; self.exp(); self.expect(']'); new = 'index'
            elif self.kind == ':':
                self.index += 1; self.expect('name'); self.args(); new = 'call'
            elif self.kind in ('(', '{', 'string'):
                self.args(); new = 'call'
            else:
                break
            if pending:
                self.resolve(*pending); pending = None
            kind = new
        if pending and not (assign_target and self.kind in ('=', ',')):
            self.resolve(*pending)
        return kind

    def args(self):
        if self.accept('string'):
            return
        if self.kind == '{':
            return self.table()
        self.expect('(')
        if self.kind != ')': self.explist()
        self.expect(')')

    def table(self):
        self.expect('{')
        while self.kind != '}':
            if self.kind == '[':
                self.index += 1; self.exp(); self.expect(']'); self.expect('='); self.exp()
            elif self.kind == 'name' and self.tokens[self.index + 1][0] == '=':
                self.index += 2; self.exp()
            else:
                self.exp()
            if not (self.accept(',') or self.accept(';')):
                break
        self.expect('}')

    def explist(self):
        self.exp()
        while self.accept(','): self.exp()

    BINARY = {'or': (1, 1), 'and': (2, 2), '<': (3, 3), '>': (3, 3), '<=': (3, 3), '>=': (3, 3), '~=': (3, 3), '==': (3, 3),
              '..': (5, 4), '+': (6, 6), '-': (6, 6), '*': (7, 7), '/': (7, 7), '%': (7, 7), '^': (10, 9)}

    def exp(self, limit=0):
        if self.kind in ('not', '-', '#'):
            self.index += 1; self.exp(8)
        else:
            self.simpleexp()
        while self.kind in self.BINARY and self.BINARY[self.kind][0] > limit:
            right = self.BINARY[self.kind][1]
            self.index += 1
            self.exp(right)

    def simpleexp(self):
        kind = self.kind
        if kind in ('number', 'string', 'nil', 'true', 'false'):
            self.index += 1
        elif kind == '...':
            if not any('...' in scope for scope in self.scopes[-1:]) and not self.vararg_ok():
                self.error("cannot use '...' outside a vararg function")
            self.index += 1
        elif kind == '{':
            self.table()
        elif kind == 'function':
            self.index += 1; self.funcbody(False)
        else:
            self.primaryexp()

    def vararg_ok(self):
        # Main chunk is vararg; inside functions the param list must contain '...'.
        depth = len(self.loop_depth)
        if depth == 1:
            return True
        # Find the scope of the innermost function: scopes pushed after it are plain blocks.
        return any('...' in scope for scope in self.scopes[self.function_scope_index():])

    def function_scope_index(self):
        return getattr(self, '_function_scopes', [0])[-1]


def check(path):
    source = path.read_text(encoding='utf-8-sig')
    parser = Parser(lex(source))
    # Track function scope starts for '...' validation.
    parser._function_scopes = [0]
    original = parser.block

    def block(names=(), new_function=False):
        if new_function:
            parser._function_scopes.append(len(parser.scopes))
        result = original(names, new_function)
        if new_function:
            parser._function_scopes.pop()
        return result
    parser.block = block
    parser.block()
    if parser.kind != 'eof':
        parser.error("unexpected token (unbalanced 'end'?)")
    return parser


def main():
    failed = False
    for name in sys.argv[1:]:
        path = Path(name)
        try:
            parser = check(path)
        except LuaError as problem:
            failed = True
            print(f'FAIL {path.name}: {problem}')
            continue
        reads = ' '.join(sorted(parser.globals_read))
        writes = ' '.join(sorted(parser.globals_written))
        print(f'OK   {path.name}\n     reads: {reads}\n     writes: {writes or "-"}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
