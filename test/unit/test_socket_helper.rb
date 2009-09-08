# -*- encoding: binary -*-

require 'test/test_helper'
require 'tempfile'

class TestSocketHelper < Test::Unit::TestCase
  include Unicorn::SocketHelper
  attr_reader :logger
  GET_SLASH = "GET / HTTP/1.0\r\n\r\n".freeze

  def setup
    @log_tmp = Tempfile.new 'logger'
    @logger = Logger.new(@log_tmp.path)
    @test_addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    GC.disable
  end

  def teardown
    GC.enable
  end

  def test_bind_listen_tcp
    port = unused_port @test_addr
    @tcp_listener_name = "#@test_addr:#{port}"
    @tcp_listener = bind_listen(@tcp_listener_name)
    assert TCPServer === @tcp_listener
    assert_equal @tcp_listener_name, sock_name(@tcp_listener)
  end

  def test_bind_listen_options
    port = unused_port @test_addr
    tcp_listener_name = "#@test_addr:#{port}"
    tmp = Tempfile.new 'unix.sock'
    unix_listener_name = tmp.path
    File.unlink(tmp.path)
    [ { :backlog => 5 }, { :sndbuf => 4096 }, { :rcvbuf => 4096 },
      { :backlog => 16, :rcvbuf => 4096, :sndbuf => 4096 }
    ].each do |opts|
      assert_nothing_raised do
        tcp_listener = bind_listen(tcp_listener_name, opts)
        assert TCPServer === tcp_listener
        tcp_listener.close
        unix_listener = bind_listen(unix_listener_name, opts)
        assert UNIXServer === unix_listener
        unix_listener.close
      end
    end
    #system('cat', @log_tmp.path)
  end

  def test_bind_listen_unix
    old_umask = File.umask(0777)
    tmp = Tempfile.new 'unix.sock'
    @unix_listener_path = tmp.path
    File.unlink(@unix_listener_path)
    @unix_listener = bind_listen(@unix_listener_path)
    assert UNIXServer === @unix_listener
    assert_equal @unix_listener_path, sock_name(@unix_listener)
    assert File.readable?(@unix_listener_path), "not readable"
    assert File.writable?(@unix_listener_path), "not writable"
    assert_equal 0777, File.umask
    ensure
      File.umask(old_umask)
  end

  def test_bind_listen_unix_idempotent
    test_bind_listen_unix
    a = bind_listen(@unix_listener)
    assert_equal a.fileno, @unix_listener.fileno
    unix_server = server_cast(@unix_listener)
    assert UNIXServer === unix_server
    a = bind_listen(unix_server)
    assert_equal a.fileno, unix_server.fileno
    assert_equal a.fileno, @unix_listener.fileno
  end

  def test_bind_listen_tcp_idempotent
    test_bind_listen_tcp
    a = bind_listen(@tcp_listener)
    assert_equal a.fileno, @tcp_listener.fileno
    tcp_server = server_cast(@tcp_listener)
    assert TCPServer === tcp_server
    a = bind_listen(tcp_server)
    assert_equal a.fileno, tcp_server.fileno
    assert_equal a.fileno, @tcp_listener.fileno
  end

  def test_bind_listen_unix_rebind
    test_bind_listen_unix
    new_listener = bind_listen(@unix_listener_path)
    assert UNIXServer === new_listener
    assert new_listener.fileno != @unix_listener.fileno
    assert_equal sock_name(new_listener), sock_name(@unix_listener)
    assert_equal @unix_listener_path, sock_name(new_listener)
    pid = fork do
      client = server_cast(new_listener).accept
      client.syswrite('abcde')
      exit 0
    end
    s = UNIXSocket.new(@unix_listener_path)
    IO.select([s])
    assert_equal 'abcde', s.sysread(5)
    pid, status = Process.waitpid2(pid)
    assert status.success?
  end

  def test_server_cast
    assert_nothing_raised do
      test_bind_listen_unix
      test_bind_listen_tcp
    end
    unix_listener_socket = Socket.for_fd(@unix_listener.fileno)
    assert Socket === unix_listener_socket
    @unix_server = server_cast(unix_listener_socket)
    assert_equal @unix_listener.fileno, @unix_server.fileno
    assert UNIXServer === @unix_server
    assert File.socket?(@unix_server.path)
    assert_equal @unix_listener_path, sock_name(@unix_server)

    tcp_listener_socket = Socket.for_fd(@tcp_listener.fileno)
    assert Socket === tcp_listener_socket
    @tcp_server = server_cast(tcp_listener_socket)
    assert_equal @tcp_listener.fileno, @tcp_server.fileno
    assert TCPServer === @tcp_server
    assert_equal @tcp_listener_name, sock_name(@tcp_server)
  end

  def test_sock_name
    test_server_cast
    sock_name(@unix_server)
  end

end
