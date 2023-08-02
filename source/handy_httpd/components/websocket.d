/**
 * Defines components for dealing with websocket connections.
 */
module handy_httpd.components.websocket;

import handy_httpd.components.handler;
import handy_httpd.components.request;
import handy_httpd.components.response;
import streams;
import slf4d;

import std.format;
import std.typecons;
import std.uuid;
import core.thread;

class WebSocketException : Exception {
    import std.exception : basicExceptionCtors;
    import streams.primitives;
    mixin basicExceptionCtors;
}

struct WebSocketTextMessage {
    string payload;
}

struct WebSocketBinaryMessage {
    ubyte[] payload;
}

struct WebSocketCloseMessage {
    ushort statusCode;
    string message;
}

/**
 * An abstract class defining methods for handling incoming websocket messages.
 * You may override any of the methods defined within this class to "listen"
 * for those messages.
 */
abstract class WebSocketMessageHandler {
    void handleTextMessage(WebSocketTextMessage msg) {}
    void handleBinaryMessage(WebSocketBinaryMessage msg) {}
    void handleCloseMessage(WebSocketCloseMessage msg) {}
}

struct WebSocketConnection {
    immutable UUID id;
}

/**
 * A special HttpRequestHandler implementation that exclusively handles
 * websocket connection handshakes.
 */
class WebSocketHandler : HttpRequestHandler {
    void handle(ref HttpRequestContext ctx) {
        infoF!"Websocket request: %s %s, Headers: %s"(methodToName(ctx.request.method), ctx.request.url, ctx.request.headers);
        string origin = ctx.request.getHeader("origin");
        string key = ctx.request.getHeader("Sec-WebSocket-Key");
        if (key is null) {
            ctx.response.setStatus(HttpStatus.BAD_REQUEST);
            ctx.response.writeBodyString("Missing Sec-WebSocket-Key header.");
            return;
        }
        ctx.response.setStatus(HttpStatus.SWITCHING_PROTOCOLS);
        ctx.response.addHeader("Upgrade", "websocket");
        ctx.response.addHeader("Connection", "Upgrade");
        ctx.response.addHeader("Sec-WebSocket-Accept", createSecWebSocketAcceptHeader(key));
        ctx.response.flushHeaders();

        info("Starting websocket thread...");
        new WebSocketThread(ctx.request.inputStream, ctx.response.outputStream).start();
    }
}

/**
 * A separate thread that manages persistent websocket connections and relays
 * incoming messages to registered websocket message handlers.
 */
class WebSocketThread : Thread {
    private InputStream!ubyte inputStream;
    private OutputStream!ubyte outputStream;

    this(InputStream!ubyte input, OutputStream!ubyte output) {
        super(&this.run);
        this.inputStream = input;
        this.outputStream = output;
    }

    private void run() {
        while (true) {
            info("Waiting for message...");
            WebSocketFrame frame = receiveWebSocketFrame(this.inputStream);
            infoF!"Got frame: %s"(frame);
            WebSocketFrame resp = WebSocketFrame(
                true,
                WebSocketFrameOpcode.TEXT_FRAME,
                cast(ubyte[]) "Hello world"
            );
            sendWebSocketFrame(this.outputStream, resp);
        }
    }
}

/**
 * An enumeration of valid opcodes for websocket data frames.
 * https://datatracker.ietf.org/doc/html/rfc6455#section-5.2
 */
enum WebSocketFrameOpcode : ubyte {
    CONTINUATION = 0,
    TEXT_FRAME = 1,
    BINARY_FRAME = 2,
    // 0x3-7 reserved for future non-control frames.
    CONNECTION_CLOSE = 8,
    PING = 9,
    PONG = 10
    // 0xB-F are reserved for further control frames.
}

/**
 * An enumeration of possible closing status codes for websocket connections,
 * as per https://datatracker.ietf.org/doc/html/rfc6455#section-7.4
 */
enum WebSocketCloseStatusCode : ushort {
    NORMAL = 1000,
    GOING_AWAY = 1001,
    PROTOCOL_ERROR = 1002,
    UNACCEPTABLE_DATA = 1003,
    NO_CODE = 1005,
    CLOSED_ABNORMALLY = 1006,
    INCONSISTENT_DATA = 1007,
    POLICY_VIOLATION = 1008,
    MESSAGE_TOO_BIG = 1009,
    EXTENSION_NEGOTIATION_FAILURE = 1010,
    UNEXPECTED_CONDITION = 1011,
    TLS_HANDSHAKE_FAILURE = 1015
}

private string createSecWebSocketAcceptHeader(string key) {
    import std.digest.sha : sha1Of;
    import std.base64;
    ubyte[20] hash = sha1Of(key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    return Base64.encode(hash);
}

unittest {
    string result = createSecWebSocketAcceptHeader("dGhlIHNhbXBsZSBub25jZQ==");
    assert(result == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

/**
 * Internal intermediary structure used to hold the results of parsing a
 * websocket frame.
 */
private struct WebSocketFrame {
    immutable bool finalFragment;
    immutable WebSocketFrameOpcode opcode;
    const ubyte[] payload;
}

/**
 * Sends a websocket frame to a byte output stream.
 * Params:
 *   stream = The stream to write to.
 *   frame = The frame to write.
 */
private void sendWebSocketFrame(S)(S stream, WebSocketFrame frame) if (isByteOutputStream!S) {
    ubyte finAndOpcode = frame.opcode;
    if (frame.finalFragment) {
        finAndOpcode |= 128;
    }
    writeDataOrThrow(stream, finAndOpcode);
    if (frame.payload.length < 126) {
        writeDataOrThrow(stream, cast(ubyte) frame.payload.length);
    } else if (frame.payload.length <= ushort.max) {
        writeDataOrThrow(stream, cast(ubyte) 126);
        writeDataOrThrow(stream, cast(ushort) frame.payload.length);
    } else {
        writeDataOrThrow(stream, cast(ubyte) 127);
        writeDataOrThrow(stream, cast(ulong) frame.payload.length);
    }
    StreamResult result = stream.writeToStream(cast(ubyte[]) frame.payload);
    if (result.hasError) {
        throw new WebSocketException(cast(string) result.error.message);
    } else if (result.count != frame.payload.length) {
        throw new WebSocketException(format!"Wrote %d bytes instead of expected %d."(result.count, frame.payload.length));
    }
}

/**
 * Receives a websocket frame from a byte input stream.
 * Params:
 *   stream = The stream to receive from.
 * Returns: The frame that was received.
 */
private WebSocketFrame receiveWebSocketFrame(S)(S stream) if (isByteInputStream!S) {
    auto finalAndOpcode = parseFinAndOpcode(&stream);
    immutable bool finalFragment = finalAndOpcode.finalFragment;
    immutable ubyte opcode = finalAndOpcode.opcode;
    immutable bool isControlFrame = (
        opcode == WebSocketFrameOpcode.CONNECTION_CLOSE ||
        opcode == WebSocketFrameOpcode.PING ||
        opcode == WebSocketFrameOpcode.PONG
    );

    immutable ubyte maskAndLength = readDataOrThrow!(ubyte)(&stream);
    immutable bool payloadMasked = (maskAndLength & 128) > 0;
    immutable ubyte initialPayloadLength = maskAndLength & 127;
    ulong payloadLength = readPayloadLength(initialPayloadLength, &stream);
    if (isControlFrame && payloadLength > 125) {
        throw new WebSocketException("Control frame payload is too large.");
    }

    ubyte[4] maskingKey;
    if (payloadMasked) maskingKey = readDataOrThrow!(ubyte[4])(&stream);
    debugF!"Receiving websocket frame: (FIN=%s,OP=%d,MASK=%s,LENGTH=%d)"(
        finalFragment,
        opcode,
        payloadMasked,
        payloadLength
    );
    ubyte[] buffer = readPayload(payloadLength, &stream);
    if (payloadMasked) unmaskData(buffer, maskingKey);

    return WebSocketFrame(
        finalFragment,
        cast(WebSocketFrameOpcode) opcode,
        buffer
    );
}

/**
 * Parses the `finalFragment` flag and opcode from a websocket frame's first
 * header byte.
 * Params:
 *   stream = The stream to read a byte from.
 */
private auto parseFinAndOpcode(S)(S stream) if (isByteInputStream!S) {
    immutable ubyte firstByte = readDataOrThrow!(ubyte)(stream);
    immutable bool finalFragment = (firstByte & 128) > 0;
    immutable bool reserved1 = (firstByte & 64) > 0;
    immutable bool reserved2 = (firstByte & 32) > 0;
    immutable bool reserved3 = (firstByte & 16) > 0;
    immutable ubyte opcode = firstByte & 15;

    if (reserved1 || reserved2 || reserved3) {
        throw new WebSocketException("Reserved header bits are set.");
    }

    if (!validateOpcode(opcode)) {
        throw new WebSocketException(format!"Invalid opcode: %d"(opcode));
    }

    return tuple!("finalFragment", "opcode")(finalFragment, opcode);
}

private bool validateOpcode(ubyte opcode) {
    import std.traits : EnumMembers;
    static foreach (member; EnumMembers!WebSocketFrameOpcode) {
        if (opcode == member) return true;
    }
    return false;
}

/**
 * Reads the payload length of a websocket frame, given an initial 7-bit length
 * value read from the second byte of the frame's header. This may throw a
 * websocket exception if the length format is invalid.
 * Params:
 *   initialLength = The initial 7-bit length value.
 *   stream = The stream to read from.
 * Returns: The complete payload length.
 */
private ulong readPayloadLength(S)(ubyte initialLength, S stream) if (isByteInputStream!S) {
    if (initialLength == 126) {
        return readDataOrThrow!(ushort)(stream);
    } else if (initialLength == 127) {
        return readDataOrThrow!(ulong)(stream);
    }
    return initialLength;
}

/**
 * Reads the payload of a websocket frame, or throws a websocket exception if
 * the payload can't be read in its entirety.
 * Params:
 *   payloadLength = The length of the payload.
 *   stream = The stream to read from.
 * Returns: The payload data that was read.
 */
private ubyte[] readPayload(S)(ulong payloadLength, S stream) if (isByteInputStream!S) {
    ubyte[] buffer = new ubyte[payloadLength];
    StreamResult readResult = stream.readFromStream(buffer);
    if (readResult.hasError) {
        throw new WebSocketException(cast(string) readResult.error.message);
    } else if (readResult.count != payloadLength) {
        throw new WebSocketException(format!"Read %d bytes instead of expected %d for message payload."(readResult.count, payloadLength));
    }
    return buffer;
}

/**
 * Helper function to read data from a byte stream, or throw a websocket
 * exception if reading fails for any reason.
 * Params:
 *   stream = The stream to read from.
 * Returns: The value that was read.
 */
private T readDataOrThrow(T, S)(S stream) if (isByteInputStream!S) {
    auto dIn = dataInputStreamFor(stream);
    DataReadResult!T result = dIn.readFromStream!T();
    if (result.hasError) {
        throw new WebSocketException(cast(string) result.error.message);
    }
    return result.value;
}

private void writeDataOrThrow(T, S)(S stream, T data) if (isByteOutputStream!S) {
    auto dOut = dataOutputStreamFor(stream);
    OptionalStreamError err = dOut.writeToStream(data);
    if (err.present) {
        throw new WebSocketException(cast(string) err.value.message);
    }
}

/**
 * Applies a 4-byte mask to a websocket frame's payload bytes.
 * Params:
 *   buffer = The buffer containing the payload.
 *   mask = The mask to apply.
 */
private void unmaskData(ubyte[] buffer, ubyte[4] mask) {
    for (size_t i = 0; i < buffer.length; i++) {
        buffer[i] = buffer[i] ^ mask[i % 4];
    }
}

unittest {
    import slf4d;
    import slf4d.default_provider;

    // auto provider = new shared DefaultProvider(true, Levels.TRACE);
    // configureLoggingProvider(provider);

    ubyte[] example1 = [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f];
    WebSocketFrame frame1 = receiveWebSocketFrame(arrayInputStreamFor(example1));
    assert(frame1.finalFragment);
    assert(frame1.opcode == WebSocketFrameOpcode.TEXT_FRAME);
    assert(cast(string) frame1.payload == "Hello");

    ubyte[] example2 = [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58];
    WebSocketFrame frame2 = receiveWebSocketFrame(arrayInputStreamFor(example2));
    assert(frame2.finalFragment);
    assert(frame2.opcode == WebSocketFrameOpcode.TEXT_FRAME);
    assert(cast(string) frame2.payload == "Hello");

    ubyte[] example3 = [0x01, 0x03, 0x48, 0x65, 0x6c];
    WebSocketFrame frame3 = receiveWebSocketFrame(arrayInputStreamFor(example3));
    assert(!frame3.finalFragment);
    assert(frame3.opcode == WebSocketFrameOpcode.TEXT_FRAME);
    assert(cast(string) frame3.payload == "Hel");

    ubyte[] example4 = [0x80, 0x02, 0x6c, 0x6f];
    WebSocketFrame frame4 = receiveWebSocketFrame(arrayInputStreamFor(example4));
    assert(frame4.finalFragment);
    assert(frame4.opcode == WebSocketFrameOpcode.CONTINUATION);
    assert(cast(string) frame4.payload == "lo");

    ubyte[] pingExample = [0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f];
    WebSocketFrame pingFrame = receiveWebSocketFrame(arrayInputStreamFor(pingExample));
    assert(pingFrame.finalFragment);
    assert(pingFrame.opcode == WebSocketFrameOpcode.PING);
    assert(cast(string) pingFrame.payload == "Hello");

    ubyte[] pongExample = [0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58];
    WebSocketFrame pongFrame = receiveWebSocketFrame(arrayInputStreamFor(pongExample));
    assert(pongFrame.finalFragment);
    assert(pongFrame.opcode == WebSocketFrameOpcode.PONG);
    assert(cast(string) pongFrame.payload == "Hello");

    ubyte[] binaryExample1 = new ubyte[256];
    // Populate the data with some expected values.
    for (int i = 0; i < binaryExample1.length; i++) binaryExample1[i] = cast(ubyte) i % ubyte.max;
    ubyte[] binaryExample1Full = cast(ubyte[]) [0x82, 0x7E, 0x00, 0x01] ~ binaryExample1;
    WebSocketFrame binaryFrame1 = receiveWebSocketFrame(arrayInputStreamFor(binaryExample1Full));
    assert(binaryFrame1.finalFragment);
    assert(binaryFrame1.opcode == WebSocketFrameOpcode.BINARY_FRAME);
    assert(binaryFrame1.payload == binaryExample1);

    ubyte[] binaryExample2 = new ubyte[65_536];
    for (int i = 0; i < binaryExample2.length; i++) binaryExample2[i] = cast(ubyte) i % ubyte.max;
    ubyte[] binaryExample2Full = cast(ubyte[]) [0x82, 0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00] ~ binaryExample2;
    WebSocketFrame binaryFrame2 = receiveWebSocketFrame(arrayInputStreamFor(binaryExample2Full));
    assert(binaryFrame2.finalFragment);
    assert(binaryFrame2.opcode == WebSocketFrameOpcode.BINARY_FRAME);
    assert(binaryFrame2.payload == binaryExample2);
}
