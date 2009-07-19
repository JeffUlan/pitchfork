# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

# acts like tee(1) on an input input to provide a input-like stream
# while providing rewindable semantics through a File/StringIO
# backing store.  On the first pass, the input is only read on demand
# so your Rack application can use input notification (upload progress
# and like).  This should fully conform to the Rack::InputWrapper
# specification on the public API.  This class is intended to be a
# strict interpretation of Rack::InputWrapper functionality and will
# not support any deviations from it.

module Unicorn
  class TeeInput

    def initialize(input, size, body)
      @tmp = Unicorn::Util.tmpio

      if body
        @tmp.write(body)
        @tmp.seek(0)
      end
      @input = input
      @size = size # nil if chunked
    end

    # returns the size of the input.  This is what the Content-Length
    # header value should be, and how large our input is expected to be.
    # For TE:chunked, this requires consuming all of the input stream
    # before returning since there's no other way
    def size
      @size and return @size

      if @input
        buf = Z.dup
        while tee(Const::CHUNK_SIZE, buf)
        end
        @tmp.rewind
      end

      @size = @tmp.stat.size
    end

    def read(*args)
      @input or return @tmp.read(*args)

      length = args.shift
      if nil == length
        rv = @tmp.read || Z.dup
        tmp = Z.dup
        while tee(Const::CHUNK_SIZE, tmp)
          rv << tmp
        end
        rv
      else
        buf = args.shift || Z.dup
        diff = @tmp.stat.size - @tmp.pos
        if 0 == diff
          tee(length, buf)
        else
          @tmp.read(diff > length ? length : diff, buf)
        end
      end
    end

    # takes zero arguments for strict Rack::Lint compatibility, unlike IO#gets
    def gets
      @input or return @tmp.gets
      nil == $/ and return read

      orig_size = @tmp.stat.size
      if @tmp.pos == orig_size
        tee(Const::CHUNK_SIZE, Z.dup) or return nil
        @tmp.seek(orig_size)
      end

      line = @tmp.gets # cannot be nil here since size > pos
      $/ == line[-$/.size, $/.size] and return line

      # unlikely, if we got here, then @tmp is at EOF
      begin
        orig_size = @tmp.stat.size
        tee(Const::CHUNK_SIZE, Z.dup) or break
        @tmp.seek(orig_size)
        line << @tmp.gets
        $/ == line[-$/.size, $/.size] and return line
        # @tmp is at EOF again here, retry the loop
      end while true

      line
    end

    def each(&block)
      while line = gets
        yield line
      end

      self # Rack does not specify what the return value here
    end

    def rewind
      @tmp.rewind # Rack does not specify what the return value here
    end

  private

    # tees off a +length+ chunk of data from the input into the IO
    # backing store as well as returning it.  +buf+ must be specified.
    # returns nil if reading from the input returns nil
    def tee(length, buf)
      begin
        if @size
          left = @size - @tmp.stat.size
          0 == left and return nil
          if length >= left
            @input.readpartial(left, buf) == left and @input = nil
          elsif @input.nil?
            return nil
          else
            @input.readpartial(length, buf)
          end
        else # ChunkedReader#readpartial just raises EOFError when done
          @input.readpartial(length, buf)
        end
      rescue EOFError
        return @input = nil
      end
      @tmp.write(buf)
      buf
    end

  end
end
