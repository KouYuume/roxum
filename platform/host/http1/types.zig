pub const Span = struct {
    start: u32,
    len: u32,

    pub fn slice(self: Span, bytes: []const u8) []const u8 {
        const start: usize = self.start;
        return bytes[start .. start + self.len];
    }
};

pub const HttpVersion = enum {
    http_1_0,
    http_1_1,
};

pub const TargetForm = enum {
    origin,
    absolute,
    authority,
    asterisk,
};

pub const RequestLine = struct {
    method: Span,
    target: Span,
    target_form: TargetForm,
    version: HttpVersion,
};

pub const Header = struct {
    name: Span,
    value: Span,
};

pub const FeedResultTag = enum {
    need_more,
    head_complete,
    err,
};

pub const FeedResult = union(FeedResultTag) {
    need_more,
    head_complete: HeadCompletion,
    err: ParseError,
};

pub const ParseError = enum {
    invalid_line_ending,
    input_too_large,
    invalid_method,
    invalid_request_target,
    invalid_target_form,
    invalid_http_version,
    unsupported_http_version,
    invalid_header_name,
    invalid_header_value,
    obsolete_line_folding,
    too_many_headers,
    missing_host,
    duplicate_host,
    invalid_host,
    invalid_content_length,
    content_length_overflow,
    duplicate_content_length,
    conflicting_message_framing,
    invalid_transfer_encoding,
    unsupported_transfer_coding,
    transfer_encoding_on_http_1_0,
};

pub const HeadCompletion = struct {
    head_length: u32,
    consumed: usize,
};
