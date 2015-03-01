# -*- encoding: binary -*-

# :enddoc:
# Frequently used constants when constructing requests or responses.
# Many times the constant just refers to a string with the same
# contents.  Using these constants gave about a 3% to 10% performance
# improvement over using the strings directly.  Symbols did not really
# improve things much compared to constants.
module Unicorn::Const
  # default TCP listen host address (0.0.0.0, all interfaces)
  DEFAULT_HOST = "0.0.0.0"

  # default TCP listen port (8080)
  DEFAULT_PORT = 8080

  # default TCP listen address and port (0.0.0.0:8080)
  DEFAULT_LISTEN = "#{DEFAULT_HOST}:#{DEFAULT_PORT}"

  # The basic request body size we'll try to read at once (16 kilobytes).
  CHUNK_SIZE = 16 * 1024

  # Maximum request body size before it is moved out of memory and into a
  # temporary file for reading (112 kilobytes).  This is the default
  # value of client_body_buffer_size.
  MAX_BODY = 1024 * 112

  # :stopdoc:
  EXPECT_100_RESPONSE = "HTTP/1.1 100 Continue\r\n\r\n"
  EXPECT_100_RESPONSE_SUFFIXED = "100 Continue\r\n\r\nHTTP/1.1 "

  HTTP_RESPONSE_START = ['HTTP', '/1.1 ']
  HTTP_EXPECT = "HTTP_EXPECT"

  # :startdoc:
end
require_relative 'version'
