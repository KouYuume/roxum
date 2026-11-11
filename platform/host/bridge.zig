const model = @import("bridge/model.zig");

test {
    @import("std").testing.refAllDecls(model);
}
const request = @import("bridge/request.zig");
const response = @import("bridge/response.zig");

/// The bridge reaches the host allocator (through the request fiber's
/// allocator context), so a test that needs both takes it from here: one
/// file cannot belong to two modules.
pub const host_allocator = @import("allocator/host_allocator.zig");

pub const Parser = request.Parser;
pub const RequestLine = request.RequestLine;
pub const Header = request.Header;
pub const HttpMethod = request.HttpMethod;
pub const HttpRequestBodyTag = request.HttpRequestBodyTag;
pub const RocHost = request.RocHost;
pub const RequestHost = request.RequestHost;
pub const RemoteAddress = request.RemoteAddress;
pub const RequestError = request.RequestError;
pub const RequestMetadata = request.Metadata;
pub const RequestMetadataHeader = request.MetadataHeader;
pub const requestFromMetadata = request.requestFromMetadata;
pub const requestFromParsed = request.requestFromParsed;
pub const requestFromParsedStream = request.requestFromParsedStream;
pub const validateParsedRequestHead = request.validateParsedHead;

pub const ModelRoot = model.ModelRoot;
pub const Application = model.Application;
pub const ListenOptions = model.ListenOptions;
pub const ListenLimits = model.Limits;
pub const ListenThreads = model.Threads;
pub const ListenCount = model.Count;
pub const Timeouts = model.Timeouts;
pub const InitResultTag = model.InitResultTag;
pub const decrefErasedCallable = model.decrefErasedCallable;
pub const RocErasedCallable = model.RocErasedCallable;
pub const allocateErasedCallable = model.allocateErasedCallable;
pub const erasedCallableCapturePtr = model.erasedCallableCapturePtr;
pub const isUniqueBox = model.isUniqueBox;
pub const allocateBox = model.allocateBox;
pub const decrefBox = model.decrefBox;
pub const rocInit = model.rocInit;
pub const rocHandle = model.rocHandle;

pub const HttpResponse = response.HttpResponse;
pub const HttpResponseBody = response.HttpResponseBody;
pub const HttpResponseBodyTag = response.HttpResponseBodyTag;
pub const HttpResponseHeaderList = response.HttpResponseHeaderList;
pub const GeneratedRocStr = response.RocStr;
pub const RocByteList = response.RocByteList;
pub const OwnedResponseEncoder = response.OwnedResponseEncoder;
pub const WrittenHead = response.WrittenHead;
pub const writeBodyPart = response.writeBodyPart;
pub const writeBodyEnd = response.writeBodyEnd;
pub const chunked_terminator = response.chunked_terminator;
pub const maximum_response_extra_headers = response.maximum_extra_headers;
pub const ResponseExtraRoom = response.ExtraRoom;
pub const responseExtraRoom = response.extraRoom;
pub const ResponseExtraHeader = response.ExtraHeader;
pub const ResponseEncodeError = response.EncodeError;
pub const ResponseHttpVersion = response.HttpVersion;
pub const ResponseConnection = response.ResponseConnection;
pub const ResponseRequestSemantics = response.RequestSemantics;
pub const ResponseAdvanceError = response.AdvanceError;
pub const ResponseWriteError = response.WriteError;
pub const ResponseBuffer = response.ResponseBuffer;
pub const HeadScratch = response.HeadScratch;
