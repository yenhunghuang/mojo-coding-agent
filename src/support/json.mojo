"""Small strict JSON reader. Values own JSON text; no recursive object hierarchy.

This favors readable code over high throughput. Parsing is depth-bounded, strings
support surrogate pairs, and object keys must be unique. Numbers retain their
original spelling (no lossy float conversion).
"""
from std.collections import List
from std.collections.string import chr


def quote(text: String) -> String:
    var result = String('"')
    for ch in text.codepoint_slices():
        if ch == '"':
            result += '\\"'
        elif ch == "\\":
            result += "\\\\"
        elif Int(ch.as_bytes()[0]) < 32:
            var digits = String("0123456789abcdef")
            var byte = Int(ch.as_bytes()[0])
            result += (
                "\\u00"
                + String(digits[byte=byte // 16])
                + String(digits[byte=byte % 16])
            )
        else:
            result += ch
    return result + '"'


struct Parser:
    var source: String
    var pos: Int

    def __init__(out self, source: String):
        self.source = source
        self.pos = 0

    def peek(self) -> Int:
        if self.pos >= self.source.byte_length():
            return -1
        return Int(self.source.as_bytes()[self.pos])

    def space(mut self):
        while (
            self.peek() == 32
            or self.peek() == 9
            or self.peek() == 10
            or self.peek() == 13
        ):
            self.pos += 1

    def expect(mut self, byte: Int) raises:
        if self.peek() != byte:
            raise Error("Invalid JSON at byte " + String(self.pos))
        self.pos += 1

    def hex4(mut self) raises -> Int:
        var value = 0
        for _ in range(4):
            var c = self.peek()
            var digit = -1
            if c >= 48 and c <= 57:
                digit = c - 48
            elif c >= 65 and c <= 70:
                digit = c - 55
            elif c >= 97 and c <= 102:
                digit = c - 87
            if digit < 0:
                raise Error("Invalid JSON Unicode escape")
            value = value * 16 + digit
            self.pos += 1
        return value

    def string(mut self) raises -> String:
        self.expect(34)
        var result = String()
        while self.peek() != 34:
            var byte = self.peek()
            if byte < 32:
                raise Error(
                    "Unterminated string or unescaped control character"
                )
            if byte != 92:
                var ch = self.source[byte=self.pos]
                result += ch
                self.pos += ch.byte_length()
                continue
            self.pos += 1
            var escape = self.peek()
            self.pos += 1
            if escape == 34 or escape == 92 or escape == 47:
                result += chr(escape)
            elif escape == 98:
                result += "\b"
            elif escape == 102:
                result += "\f"
            elif escape == 110:
                result += "\n"
            elif escape == 114:
                result += "\r"
            elif escape == 116:
                result += "\t"
            elif escape == 117:
                var code = self.hex4()
                if code >= 0xD800 and code <= 0xDBFF:
                    self.expect(92)
                    self.expect(117)
                    var low = self.hex4()
                    if low < 0xDC00 or low > 0xDFFF:
                        raise Error("Invalid JSON surrogate pair")
                    code = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00
                elif code >= 0xDC00 and code <= 0xDFFF:
                    raise Error("Unpaired JSON surrogate")
                result += chr(code)
            else:
                raise Error("Invalid JSON escape")
        self.expect(34)
        return result^

    def digits(mut self) raises:
        var start = self.pos
        while self.peek() >= 48 and self.peek() <= 57:
            self.pos += 1
        if self.pos == start:
            raise Error("Expected JSON number digits")

    def value(mut self, depth: Int = 0) raises:
        if depth > 64:
            raise Error("JSON nesting exceeds 64")
        self.space()
        var c = self.peek()
        if c == 34:
            _ = self.string()
        elif c == 123 or c == 91:
            self.pos += 1
            var closing = 93
            if c == 123:
                closing = 125
            self.space()
            var keys = List[String]()
            if self.peek() != closing:
                while True:
                    if c == 123:
                        var key = self.string()
                        for previous in keys:
                            if previous == key:
                                raise Error("Duplicate JSON object key")
                        keys.append(key^)
                        self.space()
                        self.expect(58)
                    self.value(depth + 1)
                    self.space()
                    if self.peek() != 44:
                        break
                    self.pos += 1
                    self.space()
            self.expect(closing)
        elif c == 116 or c == 102 or c == 110:
            var literal = String("null")
            if c == 116:
                literal = "true"
            elif c == 102:
                literal = "false"
            for byte in literal.as_bytes():
                self.expect(Int(byte))
        else:
            if self.peek() == 45:
                self.pos += 1
            if self.peek() == 48:
                self.pos += 1
            else:
                self.digits()
            if self.peek() == 46:
                self.pos += 1
                self.digits()
            if self.peek() == 101 or self.peek() == 69:
                self.pos += 1
                if self.peek() == 43 or self.peek() == 45:
                    self.pos += 1
                self.digits()


struct Json(Copyable, Movable):
    var raw: String

    def __init__(out self, raw: String = "null"):
        self.raw = raw

    @staticmethod
    def parse(text: String) raises -> Json:
        var parser = Parser(text)
        parser.value()
        parser.space()
        if parser.pos != text.byte_length():
            raise Error("Trailing data after JSON value")
        return Json(String(text.strip()))

    @staticmethod
    def text(value: String) -> Json:
        return Json(quote(value))

    def is_null(self) -> Bool:
        return self.raw == "null"

    def string(self) raises -> String:
        var parser = Parser(self.raw)
        return parser.string()

    def integer(self) raises -> Int:
        # Tool limits are positive and small. Reject floats, bools and overflow.
        var value = 0
        if self.raw.byte_length() == 0:
            raise Error("Expected positive integer")
        for byte in self.raw.as_bytes():
            if byte < 48 or byte > 57 or value > 100000000:
                raise Error("Expected bounded positive integer")
            value = value * 10 + Int(byte) - 48
        return value

    def get(self, key: String, default: String = "null") raises -> Json:
        var parser = Parser(self.raw)
        parser.expect(123)
        parser.space()
        while parser.peek() != 125:
            var name = parser.string()
            parser.space()
            parser.expect(58)
            parser.space()
            var start = parser.pos
            parser.value()
            if name == key:
                return Json(String(self.raw[byte = start : parser.pos]))
            parser.space()
            if parser.peek() != 44:
                break
            parser.pos += 1
            parser.space()
        return Json(default)

    def items(self) raises -> List[Json]:
        var result = List[Json]()
        var parser = Parser(self.raw)
        parser.expect(91)
        parser.space()
        while parser.peek() != 93:
            var start = parser.pos
            parser.value()
            result.append(Json(String(self.raw[byte = start : parser.pos])))
            parser.space()
            if parser.peek() != 44:
                break
            parser.pos += 1
            parser.space()
        return result^

    def add(mut self, key: String, value: Json):
        # Builder-only operation: callers add each key once to an object.
        var prefix = String(self.raw[byte = 0 : self.raw.byte_length() - 1])
        if prefix != "{":
            prefix += ","
        self.raw = prefix + quote(key) + ":" + value.raw + "}"

    def append(mut self, value: Json):
        var prefix = String(self.raw[byte = 0 : self.raw.byte_length() - 1])
        if prefix != "[":
            prefix += ","
        self.raw = prefix + value.raw + "]"


def boolean(value: Bool) -> Json:
    if value:
        return Json("true")
    return Json("false")
