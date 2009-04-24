# Copyright (c) 2009 Eric Wong
require 'test/test_helper'

include Unicorn

class UploadTest < Test::Unit::TestCase

  def setup
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port
    @hdr = {'Content-Type' => 'text/plain', 'Content-Length' => '0'}
    @bs = 4096
    @count = 256
    @server = nil

    # we want random binary data to test 1.9 encoding-aware IO craziness
    @random = File.open('/dev/urandom','rb')
    @sha1 = Digest::SHA1.new
    @sha1_app = lambda do |env|
      input = env['rack.input']
      resp = { :pos => input.pos, :size => input.stat.size }
      begin
        loop { @sha1.update(input.sysread(@bs)) }
      rescue EOFError
      end
      resp[:sha1] = @sha1.hexdigest
      [ 200, @hdr.merge({'X-Resp' => resp.inspect}), [] ]
    end
  end

  def teardown
    redirect_test_io { @server.stop(true) } if @server
    @random.close
  end

  def test_put
    start_server(@sha1_app)
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times do
      buf = @random.sysread(@bs)
      @sha1.update(buf)
      sock.syswrite(buf)
    end
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal length, resp[:size]
    assert_equal 0, resp[:pos]
    assert_equal @sha1.hexdigest, resp[:sha1]
  end

  def test_put_trickle_small
    @count, @bs = 2, 128
    start_server(@sha1_app)
    assert_equal 256, length
    sock = TCPSocket.new(@addr, @port)
    hdr = "PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n"
    @count.times do
      buf = @random.sysread(@bs)
      @sha1.update(buf)
      hdr << buf
      sock.syswrite(hdr)
      hdr = ''
      sleep 0.6
    end
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal length, resp[:size]
    assert_equal 0, resp[:pos]
    assert_equal @sha1.hexdigest, resp[:sha1]
    assert_equal StringIO, resp[:class]
  end

  def test_tempfile_unlinked
    spew_path = lambda do |env|
      if orig = env['HTTP_X_OLD_PATH']
        assert orig != env['rack.input'].path
      end
      assert_equal length, env['rack.input'].size
      [ 200, @hdr.merge('X-Tempfile-Path' => env['rack.input'].path), [] ]
    end
    start_server(spew_path)
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(' ' * @bs) }
    path = sock.read[/^X-Tempfile-Path: (\S+)/, 1]
    sock.close

    # send another request to ensure we hit the next request
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("PUT / HTTP/1.0\r\nX-Old-Path: #{path}\r\n" \
                  "Content-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(' ' * @bs) }
    path2 = sock.read[/^X-Tempfile-Path: (\S+)/, 1]
    sock.close
    assert path != path2

    # make sure the next request comes in so the unlink got processed
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("GET ?lasdf\r\n\r\n\r\n\r\n")
    sock.sysread(4096) rescue nil
    sock.close

    assert ! File.exist?(path)
  end

  def test_put_keepalive_truncates_small_overwrite
    start_server(@sha1_app)
    sock = TCPSocket.new(@addr, @port)
    to_upload = length + 1
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{to_upload}\r\n\r\n")
    @count.times do
      buf = @random.sysread(@bs)
      @sha1.update(buf)
      sock.syswrite(buf)
    end
    sock.syswrite('12345') # write 4 bytes more than we expected
    @sha1.update('1')

    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal to_upload, resp[:size]
    assert_equal 0, resp[:pos]
    assert_equal @sha1.hexdigest, resp[:sha1]
  end

  def test_put_excessive_overwrite_closed
    start_server(lambda { |env| [ 200, @hdr, [] ] })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    assert_raise(Errno::ECONNRESET, Errno::EPIPE) do
      ::Unicorn::Const::CHUNK_SIZE.times { sock.syswrite(buf) }
    end
  end

  def test_put_handler_closed_file
    nr = '0'
    start_server(lambda { |env|
      env['rack.input'].close
      resp = { :nr => nr.succ! }
      [ 200, @hdr.merge({ 'X-Resp' => resp.inspect}), [] ]
    })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal '1', resp[:nr]

    # server still alive?
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal '2', resp[:nr]
  end

  def test_renamed_file_not_closed
    start_server(lambda { |env|
      new_tmp = Tempfile.new('unicorn_test')
      input = env['rack.input']
      File.rename(input.path, new_tmp.path)
      resp = {
        :inode => input.stat.ino,
        :size => input.stat.size,
        :new_tmp => new_tmp.path,
        :old_tmp => input.path,
      }
      [ 200, @hdr.merge({ 'X-Resp' => resp.inspect}), [] ]
    })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    new_tmp = File.open(resp[:new_tmp])
    assert_equal resp[:inode], new_tmp.stat.ino
    assert_equal length, resp[:size]
    assert ! File.exist?(resp[:old_tmp])
    assert_equal resp[:size], new_tmp.stat.size
  end

  # Despite reading numerous articles and inspecting the 1.9.1-p0 C
  # source, Eric Wong will never trust that we're always handling
  # encoding-aware IO objects correctly.  Thus this test uses shell
  # utilities that should always operate on files/sockets on a
  # byte-level.
  def test_uncomfortable_with_onenine_encodings
    # POSIX doesn't require all of these to be present on a system
    which('curl') or return
    which('sha1sum') or return
    which('dd') or return

    start_server(@sha1_app)

    tmp = Tempfile.new('dd_dest')
    assert(system("dd", "if=#{@random.path}", "of=#{tmp.path}",
                        "bs=#{@bs}", "count=#{@count}"),
           "dd #@random to #{tmp}")
    sha1_re = %r!\b([a-f0-9]{40})\b!
    sha1_out = `sha1sum #{tmp.path}`
    assert $?.success?, 'sha1sum ran OK'

    assert_match(sha1_re, sha1_out)
    sha1 = sha1_re.match(sha1_out)[1]
    resp = `curl -isSfN -T#{tmp.path} http://#@addr:#@port/`
    assert $?.success?, 'curl ran OK'
    assert_match(%r!\b#{sha1}\b!, resp)
  end

  private

  def length
    @bs * @count
  end

  def start_server(app)
    redirect_test_io do
      @server = HttpServer.new(app, :listeners => [ "#{@addr}:#{@port}" ] )
      @server.start
    end
  end

end
