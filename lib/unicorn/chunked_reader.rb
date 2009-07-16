# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

require 'unicorn'
require 'unicorn_http'

module Unicorn
  class ChunkedReader

    def initialize(env, input, buf)
      @env, @input, @buf = env, input, buf
      @chunk_left = 0
      parse_chunk_header
    end

    def readpartial(max, buf = Z.dup)
      while @input && @chunk_left <= 0 && ! parse_chunk_header
        @buf << @input.readpartial(Const::CHUNK_SIZE, buf)
      end

      if @input
        begin
          @buf << @input.read_nonblock(Const::CHUNK_SIZE, buf)
        rescue Errno::EAGAIN, Errno::EINTR
        end
      end

      max = @chunk_left if max > @chunk_left
      buf.replace(last_block(max) || Z)
      @chunk_left -= buf.size
      (0 == buf.size && @input.nil?) and raise EOFError
      buf
    end

  private

    def last_block(max = nil)
      rv = @buf
      if max && rv && max < rv.size
        @buf = rv[max - rv.size, rv.size - max]
        return rv[0, max]
      end
      @buf = Z.dup
      rv
    end

    def parse_chunk_header
      buf = @buf
      # ignoring chunk-extension info for now, I haven't seen any use for it
      # (or any users, and TE:chunked sent by clients is rare already)
      # if there was not enough data in buffer to parse length of the chunk
      # then just return
      if buf.sub!(/\A(?:\r\n)?([a-fA-F0-9]{1,8})[^\r]*?\r\n/, Z)
        @chunk_left = $1.to_i(16)
        if 0 == @chunk_left # EOF
          buf.sub!(/\A\r\n(?:\r\n)?/, Z) # cleanup for future requests
          if trailer = @env[Const::HTTP_TRAILER]
            tp = TrailerParser.new(trailer)
            while ! tp.execute!(@env, buf)
              buf << @input.readpartial(Const::CHUNK_SIZE)
            end
          end
          @input = nil
        end
        return @chunk_left
      end

      buf.size > 256 and
          raise HttpParserError,
                "malformed chunk, chunk-length not found in buffer: " \
                "#{buf.inspect}"
      nil
    end

  end

end
