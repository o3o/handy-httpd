#!/usr/bin/env dub
/+ dub.sdl:
    dependency "handy-httpd" path="../../"
+/
module examples.websocket.server;

import handy_httpd;
import handy_httpd.components.websocket;
import handy_httpd.handlers.path_delegating_handler;
import handy_httpd.handlers.file_resolving_handler;
import slf4d;

class MyWebSocketHandler : WebSocketMessageHandler {
    override void onConnectionEstablished(WebSocketConnection conn) {
        infoF!"Connection established with id %s"(conn.getId());
    }

    override void onTextMessage(WebSocketTextMessage msg) {
        infoF!"Got TEXT: %s"(msg.payload);
        msg.conn.sendTextMessage("Hey yourself!");
    }

    override void onCloseMessage(WebSocketCloseMessage msg) {
        infoF!"Closed: %d, %s"(msg.statusCode, msg.message);
    }
}

void main() {
    ServerConfig cfg = ServerConfig.defaultValues();
    cfg.workerPoolSize = 3;
    cfg.workerPoolManagerIntervalMs = 5000;
    PathDelegatingHandler pdh = new PathDelegatingHandler();
    WebSocketHandler handler = new WebSocketHandler(new MyWebSocketHandler());
    pdh.addMapping(Method.GET, "/ws", handler);
    pdh.addMapping("/**", new FileResolvingHandler("site"));
    new HttpServer(pdh, cfg).start();
}