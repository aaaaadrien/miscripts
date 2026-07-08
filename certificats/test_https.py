#! /usr/bin/env python3

import http.server
import ssl

CERT_FILE = "certs/www.test.lan/www.test.lan.crt"
KEY_FILE = "certs/www.test.lan/www.test.lan.key"
SERVER_ADDRESS = ('127.0.0.1', 5000)

class LtHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        print(post_data.decode('utf-8'))

httpd = http.server.HTTPServer(SERVER_ADDRESS, LtHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
