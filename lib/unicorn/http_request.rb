require 'stringio'

# compiled extension
require 'unicorn/http11'

module Unicorn
  class HttpRequest

    attr_accessor :logger

    # default parameters we merge into the request env for Rack handlers
    DEFAULTS = {
      "rack.errors" => $stderr,
      "rack.multiprocess" => true,
      "rack.multithread" => false,
      "rack.run_once" => false,
      "rack.version" => [1, 0].freeze,
      "SCRIPT_NAME" => "".freeze,

      # some applications (like Echo) may want to change this to true
      # We disable streaming by default since some (arguably broken)
      # applications may not ever read the entire body and be confused
      # when it receives a response after nothing has been sent to it.
      Const::STREAM_INPUT => false,
      # this is not in the Rack spec, but some apps may rely on it
      "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}".freeze
    }

    NULL_IO = StringIO.new(Z)
    DECHUNKER = ChunkedReader.new
    LOCALHOST = '127.0.0.1'.freeze

    # Being explicitly single-threaded, we have certain advantages in
    # not having to worry about variables being clobbered :)
    BUFFER = ' ' * Const::CHUNK_SIZE # initial size, may grow
    PARSER = HttpParser.new
    PARAMS = Hash.new

    def initialize(logger = Configurator::DEFAULT_LOGGER)
      @logger = logger
    end

    # Does the majority of the IO processing.  It has been written in
    # Ruby using about 8 different IO processing strategies.
    #
    # It is currently carefully constructed to make sure that it gets
    # the best possible performance for the common case: GET requests
    # that are fully complete after a single read(2)
    #
    # Anyone who thinks they can make it faster is more than welcome to
    # take a crack at it.
    #
    # returns an environment hash suitable for Rack if successful
    # This does minimal exception trapping and it is up to the caller
    # to handle any socket errors (e.g. user aborted upload).
    def read(socket)
      PARAMS.clear
      PARSER.reset

      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      PARAMS[Const::REMOTE_ADDR] =
                    TCPSocket === socket ? socket.peeraddr.last : LOCALHOST

      # short circuit the common case with small GET requests first
      PARSER.execute(PARAMS, socket.readpartial(Const::CHUNK_SIZE, BUFFER)) and
          return handle_body(socket)

      data = BUFFER.dup # socket.readpartial will clobber BUFFER

      # Parser is not done, queue up more data to read and continue parsing
      # an Exception thrown from the PARSER will throw us out of the loop
      begin
        data << socket.readpartial(Const::CHUNK_SIZE, BUFFER)
        PARSER.execute(PARAMS, data) and return handle_body(socket)
      end while true
      rescue HttpParserError => e
        @logger.error "HTTP parse error, malformed request " \
                      "(#{PARAMS[Const::HTTP_X_FORWARDED_FOR] ||
                          PARAMS[Const::REMOTE_ADDR]}): #{e.inspect}"
        @logger.error "REQUEST DATA: #{data.inspect}\n---\n" \
                      "PARAMS: #{PARAMS.inspect}\n---\n"
        raise e
    end

    private

    # Handles dealing with the rest of the request
    # returns a Rack environment if successful
    def handle_body(socket)
      PARAMS[Const::RACK_INPUT] = if (body = PARAMS.delete(:http_body))
        length = PARAMS[Const::CONTENT_LENGTH].to_i

        if te = PARAMS[Const::HTTP_TRANSFER_ENCODING]
          if /chunked/i =~ te
            socket = DECHUNKER.reopen(socket, body)
            length = body = nil
          end
        end

        inp = TeeInput.new(socket, length, body)
        DEFAULTS[Const::STREAM_INPUT] ? inp : inp.consume
      else
        NULL_IO.closed? ? NULL_IO.reopen(Z) : NULL_IO
      end

      PARAMS.update(DEFAULTS)
    end

  end
end
