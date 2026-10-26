//! Formula language: parses a text expression in the variable `x` and compiles
//! it into a small stack-machine program that can be evaluated without
//! allocating.
//!
//! Grammar (lowest to highest precedence):
//!   expr    := term (('+' | '-') term)*
//!   term    := unary (('*' | '/' | '%') unary | <implicit *> unary)*
//!   unary   := ('-' | '+') unary | power
//!   power   := primary ('^' unary)?          right associative
//!   primary := number | constant | 'x' | func '(' args ')' | '(' expr ')'
//!
//! Implicit multiplication lets you write `2x`, `3sin(x)` or `(x+1)(x-1)`.

const std = @import("std");

pub const max_ops = 256;
const max_stack = 64;

pub const Func = enum {
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    exp,
    ln,
    log,
    log2,
    sqrt,
    cbrt,
    abs,
    floor,
    ceil,
    round,
    trunc,
    frac,
    sign,
    atan2,
    pow,
    min,
    max,
    mod,
    clamp,

    pub fn arity(f: Func) u8 {
        return switch (f) {
            .atan2, .pow, .min, .max, .mod => 2,
            .clamp => 3,
            else => 1,
        };
    }
};

pub const constants = [_]struct { name: []const u8, value: f64 }{
    .{ .name = "pi", .value = std.math.pi },
    .{ .name = "tau", .value = std.math.tau },
    .{ .name = "e", .value = std.math.e },
};

pub const Op = union(enum) {
    constant: f64,
    x,
    neg,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    call: Func,
};

/// Describes why a formula failed to compile. `pos`/`len` point into the
/// source text (byte offsets) so a UI can highlight the problem.
pub const Diagnostic = struct {
    pos: usize = 0,
    len: usize = 0,
    buf: [128]u8 = undefined,
    msg_len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.msg_len];
    }

    pub fn set(d: *Diagnostic, pos: usize, len: usize, comptime fmt: []const u8, args: anytype) void {
        d.pos = pos;
        d.len = len;
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch blk: {
            const ellipsis = "...";
            @memcpy(d.buf[d.buf.len - ellipsis.len ..], ellipsis);
            break :blk d.buf[0..];
        };
        d.msg_len = s.len;
    }
};

pub const Error = error{InvalidFormula};

pub const Program = struct {
    ops: [max_ops]Op = undefined,
    len: usize = 0,
    uses_x: bool = false,

    pub fn eval(p: *const Program, x: f64) f64 {
        var stack: [max_stack]f64 = undefined;
        var sp: usize = 0;
        for (p.ops[0..p.len]) |op| {
            switch (op) {
                .constant => |v| {
                    stack[sp] = v;
                    sp += 1;
                },
                .x => {
                    stack[sp] = x;
                    sp += 1;
                },
                .neg => stack[sp - 1] = -stack[sp - 1],
                .add, .sub, .mul, .div, .mod, .pow => {
                    sp -= 1;
                    const b = stack[sp];
                    const a = stack[sp - 1];
                    stack[sp - 1] = switch (op) {
                        .add => a + b,
                        .sub => a - b,
                        .mul => a * b,
                        .div => a / b,
                        .mod => floorMod(a, b),
                        .pow => std.math.pow(f64, a, b),
                        else => unreachable,
                    };
                },
                .call => |f| {
                    const n = f.arity();
                    sp -= n;
                    const a = stack[sp..][0..n];
                    stack[sp] = callFunc(f, a);
                    sp += 1;
                },
            }
        }
        std.debug.assert(sp == 1);
        return stack[0];
    }
};

fn floorMod(a: f64, b: f64) f64 {
    return a - b * @floor(a / b);
}

fn callFunc(f: Func, a: []const f64) f64 {
    return switch (f) {
        .sin => @sin(a[0]),
        .cos => @cos(a[0]),
        .tan => @tan(a[0]),
        .asin => std.math.asin(a[0]),
        .acos => std.math.acos(a[0]),
        .atan => std.math.atan(a[0]),
        .sinh => std.math.sinh(a[0]),
        .cosh => std.math.cosh(a[0]),
        .tanh => std.math.tanh(a[0]),
        .exp => @exp(a[0]),
        .ln => @log(a[0]),
        .log => @log10(a[0]),
        .log2 => @log2(a[0]),
        .sqrt => @sqrt(a[0]),
        .cbrt => std.math.cbrt(a[0]),
        .abs => @abs(a[0]),
        .floor => @floor(a[0]),
        .ceil => @ceil(a[0]),
        .round => @round(a[0]),
        .trunc => @trunc(a[0]),
        .frac => a[0] - @floor(a[0]),
        .sign => if (a[0] > 0) 1 else if (a[0] < 0) -1 else 0,
        .atan2 => std.math.atan2(a[0], a[1]),
        .pow => std.math.pow(f64, a[0], a[1]),
        .min => @min(a[0], a[1]),
        .max => @max(a[0], a[1]),
        .mod => floorMod(a[0], a[1]),
        .clamp => std.math.clamp(a[0], @min(a[1], a[2]), @max(a[1], a[2])),
    };
}

pub const Options = struct {
    /// When false, any use of `x` is an error. Used for the range fields,
    /// which accept constant expressions such as `2*pi`.
    allow_x: bool = true,
};

pub fn compile(source: []const u8, options: Options, diag: *Diagnostic) Error!Program {
    var p: Parser = .{ .src = source, .options = options, .diag = diag };
    p.advance();
    if (p.tok.kind == .end) {
        diag.set(0, 0, "Enter an expression", .{});
        return error.InvalidFormula;
    }
    try p.parseExpr();
    if (p.tok.kind != .end) {
        if (p.tok.kind == .rparen) {
            p.fail("Unmatched ')'", .{});
        } else if (p.tok.kind == .invalid) {
            p.fail("Invalid character '{s}'", .{p.tokText()});
        } else {
            p.fail("Unexpected '{s}'", .{p.tokText()});
        }
        return error.InvalidFormula;
    }
    std.debug.assert(p.depth == 1);
    return p.prog;
}

const TokKind = enum { end, number, ident, plus, minus, star, slash, percent, caret, lparen, rparen, comma, invalid };

const Token = struct {
    kind: TokKind,
    start: usize,
    end: usize,
    number: f64 = 0,
};

const Parser = struct {
    src: []const u8,
    options: Options,
    diag: *Diagnostic,
    pos: usize = 0,
    tok: Token = .{ .kind = .end, .start = 0, .end = 0 },
    prog: Program = .{},
    /// Current evaluation stack depth, tracked so eval() can use a fixed stack.
    depth: usize = 0,
    /// Parenthesis nesting, bounded to keep recursion shallow.
    nesting: usize = 0,

    fn tokText(p: *const Parser) []const u8 {
        return p.src[p.tok.start..p.tok.end];
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) void {
        p.diag.set(p.tok.start, p.tok.end - p.tok.start, fmt, args);
    }

    fn advance(p: *Parser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
        const start = p.pos;
        if (p.pos >= p.src.len) {
            p.tok = .{ .kind = .end, .start = start, .end = start };
            return;
        }
        const c = p.src[p.pos];
        if (std.ascii.isDigit(c) or (c == '.' and p.pos + 1 < p.src.len and std.ascii.isDigit(p.src[p.pos + 1]))) {
            p.lexNumber();
            return;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
            p.tok = .{ .kind = .ident, .start = start, .end = p.pos };
            return;
        }
        p.pos += 1;
        const kind: TokKind = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '^' => .caret,
            '(' => .lparen,
            ')' => .rparen,
            ',' => .comma,
            else => .invalid,
        };
        // Swallow the rest of a multi-byte UTF-8 sequence so the error
        // message shows the whole character.
        if (kind == .invalid and c >= 0x80) {
            while (p.pos < p.src.len and p.src[p.pos] & 0xC0 == 0x80) p.pos += 1;
        }
        p.tok = .{ .kind = kind, .start = start, .end = p.pos };
    }

    fn lexNumber(p: *Parser) void {
        const start = p.pos;
        const s = p.src;
        while (p.pos < s.len and std.ascii.isDigit(s[p.pos])) p.pos += 1;
        if (p.pos < s.len and s[p.pos] == '.') {
            p.pos += 1;
            while (p.pos < s.len and std.ascii.isDigit(s[p.pos])) p.pos += 1;
        }
        // Only treat `e` as an exponent when digits follow, so `2e` means 2*e.
        if (p.pos < s.len and (s[p.pos] == 'e' or s[p.pos] == 'E')) {
            var q = p.pos + 1;
            if (q < s.len and (s[q] == '+' or s[q] == '-')) q += 1;
            if (q < s.len and std.ascii.isDigit(s[q])) {
                while (q < s.len and std.ascii.isDigit(s[q])) q += 1;
                p.pos = q;
            }
        }
        const value = std.fmt.parseFloat(f64, s[start..p.pos]) catch std.math.nan(f64);
        p.tok = .{ .kind = .number, .start = start, .end = p.pos, .number = value };
    }

    fn emit(p: *Parser, op: Op) Error!void {
        if (p.prog.len >= max_ops) {
            p.fail("Formula is too long", .{});
            return error.InvalidFormula;
        }
        p.prog.ops[p.prog.len] = op;
        p.prog.len += 1;
        switch (op) {
            .constant, .x => p.depth += 1,
            .neg => {},
            .add, .sub, .mul, .div, .mod, .pow => p.depth -= 1,
            .call => |f| p.depth = p.depth + 1 - f.arity(),
        }
        if (p.depth > max_stack) {
            p.fail("Formula is nested too deeply", .{});
            return error.InvalidFormula;
        }
    }

    fn parseExpr(p: *Parser) Error!void {
        try p.parseTerm();
        while (true) {
            const op: Op = switch (p.tok.kind) {
                .plus => .add,
                .minus => .sub,
                else => return,
            };
            p.advance();
            try p.parseTerm();
            try p.emit(op);
        }
    }

    fn parseTerm(p: *Parser) Error!void {
        try p.parseUnary();
        while (true) {
            const op: Op = switch (p.tok.kind) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                // Implicit multiplication: `2x`, `3sin(x)`, `(x)(x)`.
                .number, .ident, .lparen => {
                    try p.parseUnary();
                    try p.emit(.mul);
                    continue;
                },
                else => return,
            };
            p.advance();
            try p.parseUnary();
            try p.emit(op);
        }
    }

    fn parseUnary(p: *Parser) Error!void {
        switch (p.tok.kind) {
            .minus => {
                p.advance();
                try p.parseUnary();
                try p.emit(.neg);
            },
            .plus => {
                p.advance();
                try p.parseUnary();
            },
            else => try p.parsePower(),
        }
    }

    fn parsePower(p: *Parser) Error!void {
        try p.parsePrimary();
        if (p.tok.kind == .caret) {
            p.advance();
            try p.parseUnary();
            try p.emit(.pow);
        }
    }

    fn parsePrimary(p: *Parser) Error!void {
        switch (p.tok.kind) {
            .number => {
                if (std.math.isNan(p.tok.number)) {
                    p.fail("Invalid number '{s}'", .{p.tokText()});
                    return error.InvalidFormula;
                }
                try p.emit(.{ .constant = p.tok.number });
                p.advance();
            },
            .ident => try p.parseIdent(),
            .lparen => {
                const open = p.tok;
                p.advance();
                try p.enterParen();
                try p.parseExpr();
                p.nesting -= 1;
                try p.expectClose(open);
            },
            .end => {
                p.fail("Unexpected end of formula", .{});
                return error.InvalidFormula;
            },
            .rparen => {
                p.fail("Expected a value before ')'", .{});
                return error.InvalidFormula;
            },
            .invalid => {
                p.fail("Invalid character '{s}'", .{p.tokText()});
                return error.InvalidFormula;
            },
            else => {
                p.fail("Expected a value, found '{s}'", .{p.tokText()});
                return error.InvalidFormula;
            },
        }
    }

    fn enterParen(p: *Parser) Error!void {
        p.nesting += 1;
        if (p.nesting > 32) {
            p.fail("Too many nested parentheses", .{});
            return error.InvalidFormula;
        }
    }

    fn expectClose(p: *Parser, open: Token) Error!void {
        if (p.tok.kind == .rparen) {
            p.advance();
            return;
        }
        if (p.tok.kind == .end) {
            p.diag.set(open.start, 1, "Missing ')' for '(' at position {d}", .{open.start + 1});
        } else {
            p.fail("Expected ')', found '{s}'", .{p.tokText()});
        }
        return error.InvalidFormula;
    }

    fn parseIdent(p: *Parser) Error!void {
        const name_tok = p.tok;
        const name = p.tokText();
        p.advance();

        if (std.meta.stringToEnum(Func, name)) |f| {
            if (p.tok.kind != .lparen) {
                p.diag.set(name_tok.start, name.len, "Function '{s}' needs arguments, e.g. {s}(x)", .{ name, name });
                return error.InvalidFormula;
            }
            const open = p.tok;
            p.advance();
            try p.enterParen();
            var count: u8 = 0;
            if (p.tok.kind != .rparen) {
                while (true) {
                    try p.parseExpr();
                    count += 1;
                    if (p.tok.kind != .comma) break;
                    p.advance();
                }
            }
            p.nesting -= 1;
            try p.expectClose(open);
            if (count != f.arity()) {
                p.diag.set(name_tok.start, name.len, "'{s}' takes {d} argument{s}, got {d}", .{
                    name, f.arity(), if (f.arity() == 1) "" else "s", count,
                });
                return error.InvalidFormula;
            }
            try p.emit(.{ .call = f });
            return;
        }

        for (constants) |c| {
            if (std.mem.eql(u8, c.name, name)) return p.emit(.{ .constant = c.value });
        }

        if (std.mem.eql(u8, name, "x")) {
            if (!p.options.allow_x) {
                p.diag.set(name_tok.start, name.len, "Range must be a constant (x is not allowed here)", .{});
                return error.InvalidFormula;
            }
            p.prog.uses_x = true;
            return p.emit(.x);
        }

        p.diag.set(name_tok.start, name.len, "Unknown name '{s}'", .{name});
        return error.InvalidFormula;
    }
};

// ---------------------------------------------------------------------------

fn expectEval(src: []const u8, x: f64, expected: f64) !void {
    var d: Diagnostic = .{};
    const prog = compile(src, .{}, &d) catch |err| {
        std.debug.print("compile '{s}' failed: {s}\n", .{ src, d.message() });
        return err;
    };
    try std.testing.expectApproxEqAbs(expected, prog.eval(x), 1e-9);
}

fn expectError(src: []const u8, options: Options, msg_part: []const u8) !void {
    var d: Diagnostic = .{};
    if (compile(src, options, &d)) |_| {
        std.debug.print("expected '{s}' to fail\n", .{src});
        return error.TestUnexpectedResult;
    } else |_| {
        if (std.mem.indexOf(u8, d.message(), msg_part) == null) {
            std.debug.print("'{s}': message '{s}' lacks '{s}'\n", .{ src, d.message(), msg_part });
            return error.TestUnexpectedResult;
        }
    }
}

test "arithmetic and precedence" {
    try expectEval("1 + 2 * 3", 0, 7);
    try expectEval("(1 + 2) * 3", 0, 9);
    try expectEval("2 ^ 3 ^ 2", 0, 512);
    try expectEval("-2 ^ 2", 0, -4);
    try expectEval("2 ^ -1", 0, 0.5);
    try expectEval("7 % 3", 0, 1);
    try expectEval("-1 % 3", 0, 2);
    try expectEval("10 / 4 - 1", 0, 1.5);
    try expectEval("1.5e2 + .5", 0, 150.5);
}

test "variable, constants, functions" {
    try expectEval("sin(x)", std.math.pi / 2.0, 1);
    try expectEval("2*pi", 0, std.math.tau);
    try expectEval("tau - 2pi", 0, 0);
    try expectEval("max(x, 3)", 5, 5);
    try expectEval("clamp(x, -1, 1)", 4, 1);
    try expectEval("sign(sin(x))", 4, -1);
    try expectEval("frac(x)", 2.25, 0.25);
    try expectEval("atan2(1, 1)", 0, std.math.pi / 4.0);
}

test "implicit multiplication" {
    try expectEval("2x", 3, 6);
    try expectEval("3sin(x)", std.math.pi / 2.0, 3);
    try expectEval("(x+1)(x-1)", 3, 8);
    try expectEval("2x^2", 3, 18);
    try expectEval("2e", 0, 2 * std.math.e);
}

test "errors" {
    try expectError("", .{}, "Enter an expression");
    try expectError("sin(x", .{}, "Missing ')'");
    try expectError("1 +", .{}, "Unexpected end");
    try expectError("1 + )", .{}, "before ')'");
    try expectError("x)", .{}, "Unmatched ')'");
    try expectError("foo(x)", .{}, "Unknown name 'foo'");
    try expectError("y", .{}, "Unknown name 'y'");
    try expectError("sin", .{}, "needs arguments");
    try expectError("pow(x)", .{}, "takes 2 arguments, got 1");
    try expectError("1 $ 2", .{}, "Invalid character '$'");
    try expectError("2*x", .{ .allow_x = false }, "x is not allowed");
}

test "error positions" {
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidFormula, compile("sin(x) + foo", .{}, &d));
    try std.testing.expectEqual(@as(usize, 9), d.pos);
    try std.testing.expectEqual(@as(usize, 3), d.len);
}

test "deep nesting is rejected, not crashed" {
    var buf: [200]u8 = undefined;
    @memset(buf[0..100], '(');
    buf[100] = 'x';
    @memset(buf[101..200], ')');
    try expectError(buf[0..200], .{}, "nested");
}
