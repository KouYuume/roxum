const std = @import("std");

const token_table = buildTokenTable();
const pchar_table = buildPcharTable();
const path_table = buildPathTable();
const query_table = buildQueryTable();
const userinfo_table = buildUserInfoTable();
const path_plain_table = withoutPercent(path_table);
const query_plain_table = withoutPercent(query_table);
const reg_name_plain_table = buildRegNamePlainTable();
const field_value_table = buildFieldValueTable();
const field_vector_length: usize = 16;
const field_unrolled_length: usize = 4 * field_vector_length;
const FieldVector = @Vector(field_vector_length, u8);
const FieldMask = @Vector(field_vector_length, bool);

pub fn isToken(byte: u8) bool {
    return switch (byte) {
        '0'...'9',
        'A'...'Z',
        'a'...'z',
        '!',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '*',
        '+',
        '-',
        '.',
        '^',
        '_',
        '`',
        '|',
        '~',
        => true,
        else => false,
    };
}

/// The length of the leading run of token bytes.
pub fn tokenRun(bytes: []const u8) usize {
    return runIn(&token_table, bytes);
}

/// The length of the leading run of origin-form path bytes other than `%`
/// (which starts an escape) and `?` (which starts the query).
pub fn plainPathRun(bytes: []const u8) usize {
    return runIn(&path_plain_table, bytes);
}

/// The length of the leading run of query bytes other than `%`.
pub fn plainQueryRun(bytes: []const u8) usize {
    return runIn(&query_plain_table, bytes);
}

/// The length of the leading run of unescaped reg-name bytes; it stops at
/// `%` and at the `:` before a port.
pub fn regNameRun(bytes: []const u8) usize {
    return runIn(&reg_name_plain_table, bytes);
}

/// The length of the leading run of field-value bytes; it stops at CR, LF
/// and every other byte a field value cannot contain.
pub fn fieldValueRun(bytes: []const u8) usize {
    return runIn(&field_value_table, bytes);
}

/// The index of the last byte that is not SP or HTAB.
pub fn lastNonWhitespace(bytes: []const u8) ?usize {
    var index = bytes.len;
    while (index > 0) {
        index -= 1;
        if (!isOptionalWhitespace(bytes[index])) return index;
    }
    return null;
}

fn runIn(table: *const [256]bool, bytes: []const u8) usize {
    for (bytes, 0..) |byte, index| {
        if (!table[byte]) return index;
    }
    return bytes.len;
}

pub fn validateAndCopyToken(output: []u8, bytes: []const u8) bool {
    if (output.len != bytes.len) return false;
    for (bytes, 0..) |byte, index| {
        if (!token_table[byte]) return false;
        output[index] = byte;
    }
    return true;
}

pub fn isFieldValue(byte: u8) bool {
    return byte == '\t' or byte == ' ' or
        (byte >= 0x21 and byte <= 0x7e) or
        byte >= 0x80;
}

pub fn isFieldValueSlice(bytes: []const u8) bool {
    var index: usize = 0;

    while (bytes.len - index >= field_unrolled_length) {
        const block_0: FieldVector = bytes[index..][0..field_vector_length].*;
        const block_1: FieldVector = bytes[index + field_vector_length ..][0..field_vector_length].*;
        const block_2: FieldVector = bytes[index + 2 * field_vector_length ..][0..field_vector_length].*;
        const block_3: FieldVector = bytes[index + 3 * field_vector_length ..][0..field_vector_length].*;
        const invalid = invalidFieldBytes(block_0) |
            invalidFieldBytes(block_1) |
            invalidFieldBytes(block_2) |
            invalidFieldBytes(block_3);
        if (@reduce(std.builtin.ReduceOp.Or, invalid)) return false;
        index += field_unrolled_length;
    }

    while (bytes.len - index >= field_vector_length) {
        const block: FieldVector = bytes[index..][0..field_vector_length].*;
        if (@reduce(std.builtin.ReduceOp.Or, invalidFieldBytes(block))) return false;
        index += field_vector_length;
    }

    for (bytes[index..]) |byte| {
        if (!isFieldValue(byte)) return false;
    }
    return true;
}

pub fn validateAndCopyFieldValue(output: []u8, bytes: []const u8) bool {
    if (output.len != bytes.len) return false;
    var index: usize = 0;

    while (bytes.len - index >= field_unrolled_length) {
        const block_0: FieldVector = bytes[index..][0..field_vector_length].*;
        const block_1: FieldVector = bytes[index + field_vector_length ..][0..field_vector_length].*;
        const block_2: FieldVector = bytes[index + 2 * field_vector_length ..][0..field_vector_length].*;
        const block_3: FieldVector = bytes[index + 3 * field_vector_length ..][0..field_vector_length].*;
        const invalid = invalidFieldBytes(block_0) |
            invalidFieldBytes(block_1) |
            invalidFieldBytes(block_2) |
            invalidFieldBytes(block_3);
        if (@reduce(std.builtin.ReduceOp.Or, invalid)) return false;
        output[index..][0..field_vector_length].* = block_0;
        output[index + field_vector_length ..][0..field_vector_length].* = block_1;
        output[index + 2 * field_vector_length ..][0..field_vector_length].* = block_2;
        output[index + 3 * field_vector_length ..][0..field_vector_length].* = block_3;
        index += field_unrolled_length;
    }

    while (bytes.len - index >= field_vector_length) {
        const block: FieldVector = bytes[index..][0..field_vector_length].*;
        if (@reduce(std.builtin.ReduceOp.Or, invalidFieldBytes(block))) return false;
        output[index..][0..field_vector_length].* = block;
        index += field_vector_length;
    }

    for (bytes[index..], index..) |byte, output_index| {
        if (!isFieldValue(byte)) return false;
        output[output_index] = byte;
    }
    return true;
}

fn invalidFieldBytes(block: FieldVector) FieldMask {
    const below_space = block < @as(FieldVector, @splat(0x20));
    const not_tab = block != @as(FieldVector, @splat('\t'));
    const is_delete = block == @as(FieldVector, @splat(0x7f));
    return (below_space & not_tab) | is_delete;
}

pub fn isOptionalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

pub fn isQuotedText(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or
        (byte >= ']' and byte <= '~') or byte >= 0x80;
}

pub fn isQuotedPair(byte: u8) bool {
    return byte == '\t' or byte == ' ' or
        (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80;
}

pub fn isHexDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'A'...'F', 'a'...'f' => true,
        else => false,
    };
}

pub fn isSchemeFirst(byte: u8) bool {
    return isAlpha(byte);
}

pub fn isSchemeRest(byte: u8) bool {
    return isAlpha(byte) or isDigit(byte) or
        byte == '+' or byte == '-' or byte == '.';
}

pub fn isRequestTarget(byte: u8) bool {
    if (isAlpha(byte) or isDigit(byte)) return true;

    return switch (byte) {
        '-',
        '.',
        '_',
        '~',
        ':',
        '/',
        '?',
        '[',
        ']',
        '@',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        '=',
        '%',
        => true,
        else => false,
    };
}

pub fn isPchar(byte: u8) bool {
    return pchar_table[byte];
}

pub fn isPathByte(byte: u8) bool {
    return path_table[byte];
}

pub fn isQueryByte(byte: u8) bool {
    return query_table[byte];
}

pub fn isUserInfoByte(byte: u8) bool {
    return userinfo_table[byte];
}

pub fn isRegNameUnescaped(byte: u8) bool {
    return isRegNameUnescapedScalar(byte);
}

fn isRegNameUnescapedScalar(byte: u8) bool {
    if (isAlpha(byte) or isDigit(byte)) return true;

    return switch (byte) {
        '-',
        '.',
        '_',
        '~',
        '!',
        '$',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        ';',
        '=',
        => true,
        else => false,
    };
}

pub fn isIpvFutureValue(byte: u8) bool {
    return isRegNameUnescaped(byte) or byte == ':';
}

fn isAlpha(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z');
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn buildTokenTable() [256]bool {
    var table = @as([256]bool, @splat(false));
    for ('0'..'9' + 1) |byte| table[byte] = true;
    for ('A'..'Z' + 1) |byte| table[byte] = true;
    for ('a'..'z' + 1) |byte| table[byte] = true;
    for ("!#$%&'*+-.^_`|~") |byte| table[byte] = true;
    return table;
}

fn buildPcharTable() [256]bool {
    var table = @as([256]bool, @splat(false));
    for (0..table.len) |value| {
        const byte: u8 = @intCast(value);
        table[value] = isRegNameUnescapedScalar(byte) or
            byte == ':' or byte == '@' or byte == '%';
    }
    return table;
}

fn buildPathTable() [256]bool {
    var table = pchar_table;
    table['/'] = true;
    return table;
}

fn buildQueryTable() [256]bool {
    var table = path_table;
    table['?'] = true;
    return table;
}

fn buildFieldValueTable() [256]bool {
    var table = @as([256]bool, @splat(false));
    for (0..table.len) |value| table[value] = isFieldValue(@intCast(value));
    return table;
}

fn withoutPercent(table: [256]bool) [256]bool {
    var result = table;
    result['%'] = false;
    return result;
}

fn buildRegNamePlainTable() [256]bool {
    var table = @as([256]bool, @splat(false));
    for (0..table.len) |value| table[value] = isRegNameUnescapedScalar(@intCast(value));
    return table;
}

fn buildUserInfoTable() [256]bool {
    var table = @as([256]bool, @splat(false));
    for (0..table.len) |value| {
        const byte: u8 = @intCast(value);
        table[value] = isRegNameUnescapedScalar(byte) or
            byte == ':' or byte == '%';
    }
    return table;
}

test "token accepts every RFC 9110 tchar punctuation" {
    const punctuation = "!#$%&'*+-.^_`|~";

    for (punctuation) |byte| {
        try std.testing.expect(isToken(byte));
    }
}

test "token validation copy preserves valid bytes and rejects invalid bytes" {
    var output: [8]u8 = undefined;
    try std.testing.expect(validateAndCopyToken(&output, "AZaz09!~"));
    try std.testing.expectEqualStrings("AZaz09!~", &output);
    try std.testing.expect(!validateAndCopyToken(&output, "Bad Name"));
}

test "token table agrees with scalar classification for every byte" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const input = [1]u8{byte};
        var output: [1]u8 = undefined;
        try std.testing.expectEqual(
            isToken(byte),
            validateAndCopyToken(&output, &input),
        );
    }
}

test "field value byte classes cover their boundaries" {
    try std.testing.expect(!isFieldValue(0x08));
    try std.testing.expect(isFieldValue(0x09));
    try std.testing.expect(!isFieldValue(0x0a));
    try std.testing.expect(!isFieldValue(0x1f));
    try std.testing.expect(isFieldValue(0x20));
    try std.testing.expect(isFieldValue(0x21));
    try std.testing.expect(isFieldValue(0x7e));
    try std.testing.expect(!isFieldValue(0x7f));
    try std.testing.expect(isFieldValue(0x80));
    try std.testing.expect(isFieldValue(0xff));
}

test "field value slice validates below at and above vector boundary" {
    const lengths = [_]usize{ 15, 16, 17, 63, 64, 65 };
    for (lengths) |length| {
        var bytes = @as([65]u8, @splat('a'));
        try std.testing.expect(isFieldValueSlice(bytes[0..length]));

        const positions = [_]usize{ 0, length - 1 };
        for (positions) |position| {
            bytes[position] = '\r';
            try std.testing.expect(!isFieldValueSlice(bytes[0..length]));
            bytes[position] = 'a';
        }
    }
}

test "field value validation copy covers vector boundary" {
    const lengths = [_]usize{ 15, 16, 17, 63, 64, 65 };
    for (lengths) |length| {
        var input = @as([65]u8, @splat('a'));
        var output: [65]u8 = undefined;

        try std.testing.expect(validateAndCopyFieldValue(
            output[0..length],
            input[0..length],
        ));
        try std.testing.expectEqualSlices(
            u8,
            input[0..length],
            output[0..length],
        );

        input[length - 1] = '\r';
        try std.testing.expect(!validateAndCopyFieldValue(
            output[0..length],
            input[0..length],
        ));
    }
}

test "vector field validation agrees with scalar classification" {
    const positions = [_]usize{ 0, 15, 16, 63, 64 };
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        for (positions) |position| {
            var input = @as([65]u8, @splat('a'));
            var output: [65]u8 = undefined;
            input[position] = byte;

            const expected = isFieldValue(byte);
            try std.testing.expectEqual(
                expected,
                isFieldValueSlice(&input),
            );
            try std.testing.expectEqual(
                expected,
                validateAndCopyFieldValue(&output, &input),
            );
        }
    }
}

test "validation copy rejects mismatched output lengths" {
    var output: [2]u8 = undefined;
    try std.testing.expect(!validateAndCopyToken(output[0..1], "ok"));
    try std.testing.expect(!validateAndCopyFieldValue(output[0..1], "ok"));
}

test "quoted text excludes delimiters and control boundaries" {
    try std.testing.expect(isQuotedText('\t'));
    try std.testing.expect(isQuotedText(' '));
    try std.testing.expect(isQuotedText('!'));
    try std.testing.expect(!isQuotedText('"'));
    try std.testing.expect(isQuotedText('#'));
    try std.testing.expect(isQuotedText('['));
    try std.testing.expect(!isQuotedText('\\'));
    try std.testing.expect(isQuotedText(']'));
    try std.testing.expect(isQuotedText('~'));
    try std.testing.expect(!isQuotedText(0x7f));
    try std.testing.expect(isQuotedText(0x80));
}

test "quoted pair byte class covers its boundaries" {
    try std.testing.expect(!isQuotedPair(0x08));
    try std.testing.expect(isQuotedPair(0x09));
    try std.testing.expect(!isQuotedPair(0x0a));
    try std.testing.expect(!isQuotedPair(0x1f));
    try std.testing.expect(isQuotedPair(0x20));
    try std.testing.expect(isQuotedPair(0x21));
    try std.testing.expect(isQuotedPair(0x7e));
    try std.testing.expect(!isQuotedPair(0x7f));
    try std.testing.expect(isQuotedPair(0x80));
}

test "plain runs agree with per-byte classification for every byte" {
    // Each run function must stop exactly where the per-byte rules would stop
    // treating a byte as an ordinary member of the run.
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const bytes = [_]u8{ byte, 0 };
        try std.testing.expectEqual(@intFromBool(isToken(byte)), tokenRun(&bytes));
        try std.testing.expectEqual(@intFromBool(isPathByte(byte) and byte != '%'), plainPathRun(&bytes));
        try std.testing.expectEqual(@intFromBool(isQueryByte(byte) and byte != '%'), plainQueryRun(&bytes));
        try std.testing.expectEqual(@intFromBool(isRegNameUnescaped(byte)), regNameRun(&bytes));
        try std.testing.expectEqual(@intFromBool(isFieldValue(byte)), fieldValueRun(&bytes));
    }
}

test "plain runs stop at escapes and delimiters" {
    try std.testing.expectEqual(@as(usize, 0), plainPathRun(""));
    try std.testing.expectEqual(@as(usize, 4), plainPathRun("/a/b?q"));
    try std.testing.expectEqual(@as(usize, 2), plainPathRun("/a%20"));
    try std.testing.expectEqual(@as(usize, 4), plainQueryRun("a?b=%"));
    try std.testing.expectEqual(@as(usize, 9), regNameRun("127.0.0.1:8080"));
    try std.testing.expectEqual(@as(usize, 7), tokenRun("x-token: v"));
    try std.testing.expectEqual(@as(usize, 5), fieldValueRun("a b\t \r\n"));
}

test "last non-whitespace byte" {
    try std.testing.expectEqual(@as(?usize, null), lastNonWhitespace(""));
    try std.testing.expectEqual(@as(?usize, null), lastNonWhitespace(" \t"));
    try std.testing.expectEqual(@as(?usize, 0), lastNonWhitespace("a"));
    try std.testing.expectEqual(@as(?usize, 1), lastNonWhitespace("ab \t"));
}
