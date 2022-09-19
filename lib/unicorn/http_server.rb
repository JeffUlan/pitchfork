# -*- encoding: binary -*-

# This is the process manager of Unicorn. This manages worker
# processes which in turn handle the I/O and application process.
# Listener sockets are started in the master process and shared with
# forked worker children.
#
# Users do not need to know the internals of this class, but reading the
# {source}[https://yhbt.net/unicorn.git/tree/lib/unicorn/http_server.rb]
# is education for programmers wishing to learn how unicorn works.
# See Unicorn::Configurator for information on how to configure unicorn.
class Unicorn::HttpServer
  # :stopdoc:
  attr_accessor :app, :timeout, :worker_processes,
                :before_fork, :after_fork,
                :listener_opts,
                :orig_app, :config, :ready_pipe, :user,
                :default_middleware, :early_hints
  attr_writer   :after_worker_exit, :after_worker_ready

  attr_reader :logger
  include Unicorn::SocketHelper
  include Unicorn::HttpResponse

  # all bound listener sockets
  # note: this is public used by raindrops, but not recommended for use
  # in new projects
  LISTENERS = []

  # listeners we have yet to bind
  NEW_LISTENERS = []

  # :startdoc:
  # This Hash is considered a stable interface and changing its contents
  # will allow you to switch between different installations of Unicorn
  # or even different installations of the same applications without
  # downtime.  Keys of this constant Hash are described as follows:
  #
  # * 0 - the path to the unicorn executable
  # * :argv - a deep copy of the ARGV array the executable originally saw
  # * :cwd - the working directory of the application, this is where
  # you originally started Unicorn.
  # TODO: Can we get rid of this?
  START_CTX = {
    :argv => ARGV.map(&:dup),
    0 => $0.dup,
  }
  # We favor ENV['PWD'] since it is (usually) symlink aware for Capistrano
  # and like systems
  START_CTX[:cwd] = begin
    a = File.stat(pwd = ENV['PWD'])
    b = File.stat(Dir.pwd)
    a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
  rescue
    Dir.pwd
  end
  # :stopdoc:

  # Creates a working server on host:port (strange things happen if
  # port isn't a Number).  Use HttpServer::run to start the server and
  # HttpServer.run.join to join the thread that's processing
  # incoming requests on the socket.
  def initialize(app, options = {})
    @app = app
    @default_middleware = true
    options = options.dup
    @ready_pipe = options.delete(:ready_pipe)
    @init_listeners = options[:listeners] ? options[:listeners].dup : []
    options[:use_defaults] = true
    self.config = Unicorn::Configurator.new(options)
    self.listener_opts = {}

    # We use @self_pipe differently in the master and worker processes:
    #
    # * The master process never closes or reinitializes this once
    # initialized.  Signal handlers in the master process will write to
    # it to wake up the master from IO.select in exactly the same manner
    # djb describes in https://cr.yp.to/docs/selfpipe.html
    #
    # * The workers immediately close the pipe they inherit.  See the
    # Unicorn::Worker class for the pipe workers use.
    @self_pipe = []
    @workers = {} # hash maps PIDs to Workers
    @sig_queue = [] # signal queue used for self-piping
    @pid = nil

    # we try inheriting listeners first, so we bind them later.
    # we don't write the pid file until we've bound listeners in case
    # unicorn was started twice by mistake.  Even though our #pid= method
    # checks for stale/existing pid files, race conditions are still
    # possible (and difficult/non-portable to avoid) and can be likely
    # to clobber the pid if the second start was in quick succession
    # after the first, so we rely on the listener binding to fail in
    # that case.  Some tests (in and outside of this source tree) and
    # monitoring tools may also rely on pid files existing before we
    # attempt to connect to the listener(s)
    config.commit!(self, :skip => [:listeners, :pid])
    @orig_app = app
    # list of signals we care about and trap in master.
    @queue_sigs = [
      :QUIT, :INT, :TERM, :USR1, :TTIN, :TTOU ]

    @worker_data = if worker_data = ENV['UNICORN_WORKER']
      worker_data = worker_data.split(',').map!(&:to_i)
      worker_data[1] = worker_data.slice!(1..2).map do |i|
        IO.for_fd(i)
      end
      worker_data
    end
  end

  # Runs the thing.  Returns self so you can run join on it
  def start
    inherit_listeners!
    # this pipe is used to wake us up from select(2) in #join when signals
    # are trapped.  See trap_deferred.
    @self_pipe.replace(Unicorn.pipe)
    @master_pid = @worker_data ? Process.ppid : $$

    # setup signal handlers before writing pid file in case people get
    # trigger happy and send signals as soon as the pid file exists.
    # Note that signals don't actually get handled until the #join method
    @queue_sigs.each { |sig| trap(sig) { @sig_queue << sig; awaken_master } }
    trap(:CHLD) { awaken_master }

    build_app!
    bind_new_listeners!

    spawn_missing_workers
    self
  end

  # replaces current listener set with +listeners+.  This will
  # close the socket if it will not exist in the new listener set
  def listeners=(listeners)
    cur_names, dead_names = [], []
    listener_names.each do |name|
      if name.start_with?('/')
        # mark unlinked sockets as dead so we can rebind them
        (File.socket?(name) ? cur_names : dead_names) << name
      else
        cur_names << name
      end
    end
    set_names = listener_names(listeners)
    dead_names.concat(cur_names - set_names).uniq!

    LISTENERS.delete_if do |io|
      if dead_names.include?(sock_name(io))
        (io.close rescue nil).nil? # true
      else
        set_server_sockopt(io, listener_opts[sock_name(io)])
        false
      end
    end

    (set_names - cur_names).each { |addr| listen(addr) }
  end

  def stdout_path=(path); redirect_io($stdout, path); end
  def stderr_path=(path); redirect_io($stderr, path); end

  def logger=(obj)
    Unicorn::HttpRequest::DEFAULTS["rack.logger"] = @logger = obj
  end

  # add a given address to the +listeners+ set, idempotently
  # Allows workers to add a private, per-process listener via the
  # after_fork hook.  Very useful for debugging and testing.
  # +:tries+ may be specified as an option for the number of times
  # to retry, and +:delay+ may be specified as the time in seconds
  # to delay between retries.
  # A negative value for +:tries+ indicates the listen will be
  # retried indefinitely, this is useful when workers belonging to
  # different masters are spawned during a transparent upgrade.
  def listen(address, opt = {}.merge(listener_opts[address] || {}))
    address = config.expand_addr(address)
    return if String === address && listener_names.include?(address)

    delay = opt[:delay] || 0.5
    tries = opt[:tries] || 5
    begin
      io = bind_listen(address, opt)
      unless TCPServer === io || UNIXServer === io
        io.autoclose = false
        io = server_cast(io)
      end
      logger.info "listening on addr=#{sock_name(io)} fd=#{io.fileno}"
      LISTENERS << io
      io
    rescue Errno::EADDRINUSE => err
      logger.error "adding listener failed addr=#{address} (in use)"
      raise err if tries == 0
      tries -= 1
      logger.error "retrying in #{delay} seconds " \
                   "(#{tries < 0 ? 'infinite' : tries} tries left)"
      sleep(delay)
      retry
    rescue => err
      logger.fatal "error adding listener addr=#{address}"
      raise err
    end
  end

  # monitors children and receives signals forever
  # (or until a termination signal is sent).  This handles signals
  # one-at-a-time time and we'll happily drop signals in case somebody
  # is signalling us too often.
  def join
    respawn = true
    last_check = time_now

    proc_name 'master'
    logger.info "master process ready" # test_exec.rb relies on this message
    if @ready_pipe
      begin
        @ready_pipe.syswrite($$.to_s)
      rescue => e
        logger.warn("grandparent died too soon?: #{e.message} (#{e.class})")
      end
      @ready_pipe = @ready_pipe.close rescue nil
    end
    begin
      reap_all_workers
      case @sig_queue.shift
      when nil
        # avoid murdering workers after our master process (or the
        # machine) comes out of suspend/hibernation
        if (last_check + @timeout) >= (last_check = time_now)
          sleep_time = murder_lazy_workers
        else
          sleep_time = @timeout/2.0 + 1
          @logger.debug("waiting #{sleep_time}s after suspend/hibernation")
        end
        maintain_worker_count if respawn
        master_sleep(sleep_time)
      when :QUIT # graceful shutdown
        break
      when :TERM, :INT # immediate shutdown
        stop(false)
        break
      when :USR1 # rotate logs
        logger.info "master reopening logs..."
        Unicorn::Util.reopen_logs
        logger.info "master done reopening logs"
        soft_kill_each_worker(:USR1)
      when :TTIN
        respawn = true
        self.worker_processes += 1
      when :TTOU
        self.worker_processes -= 1 if self.worker_processes > 0
      end
    rescue => e
      Unicorn.log_error(@logger, "master loop error", e)
    end while true
    stop # gracefully shutdown all workers on our way out
    logger.info "master complete"
  end

  # Terminates all workers, but does not exit master process
  def stop(graceful = true)
    self.listeners = []
    limit = time_now + timeout
    until @workers.empty? || time_now > limit
      if graceful
        soft_kill_each_worker(:QUIT)
      else
        kill_each_worker(:TERM)
      end
      sleep(0.1)
      reap_all_workers
    end
    kill_each_worker(:KILL)
  end

  def rewindable_input
    Unicorn::HttpRequest.input_class.method_defined?(:rewind)
  end

  def rewindable_input=(bool)
    Unicorn::HttpRequest.input_class = bool ?
                                Unicorn::TeeInput : Unicorn::StreamInput
  end

  def client_body_buffer_size
    Unicorn::TeeInput.client_body_buffer_size
  end

  def client_body_buffer_size=(bytes)
    Unicorn::TeeInput.client_body_buffer_size = bytes
  end

  def check_client_connection
    Unicorn::HttpRequest.check_client_connection
  end

  def check_client_connection=(bool)
    Unicorn::HttpRequest.check_client_connection = bool
  end

  private

  # wait for a signal hander to wake us up and then consume the pipe
  def master_sleep(sec)
    @self_pipe[0].wait(sec) or return
    # 11 bytes is the maximum string length which can be embedded within
    # the Ruby itself and not require a separate malloc (on 32-bit MRI 1.9+).
    # Most reads are only one byte here and uncommon, so it's not worth a
    # persistent buffer, either:
    @self_pipe[0].read_nonblock(11, exception: false)
  end

  def awaken_master
    return if $$ != @master_pid
    @self_pipe[1].write_nonblock('.', exception: false) # wakeup master process from select
  end

  # reaps all unreaped workers
  def reap_all_workers
    begin
      wpid, status = Process.waitpid2(-1, Process::WNOHANG)
      wpid or return
      worker = @workers.delete(wpid) and worker.close rescue nil
      @after_worker_exit.call(self, worker, status)
    rescue Errno::ECHILD
      break
    end while true
  end

  def listener_sockets
    listener_fds = {}
    LISTENERS.each do |sock|
      sock.close_on_exec = false
      listener_fds[sock.fileno] = sock
    end
    listener_fds
  end

  def close_sockets_on_exec(sockets)
    (3..1024).each do |io|
      next if sockets.include?(io)
      io = IO.for_fd(io) rescue next
      io.autoclose = false
      io.close_on_exec = true
    end
  end

  # forcibly terminate all workers that haven't checked in in timeout seconds.  The timeout is implemented using an unlinked File
  def murder_lazy_workers
    next_sleep = @timeout - 1
    now = time_now.to_i
    @workers.dup.each_pair do |wpid, worker|
      tick = worker.tick
      0 == tick and next # skip workers that haven't processed any clients
      diff = now - tick
      tmp = @timeout - diff
      if tmp >= 0
        next_sleep > tmp and next_sleep = tmp
        next
      end
      next_sleep = 0
      logger.error "worker=#{worker.nr} PID:#{wpid} timeout " \
                   "(#{diff}s > #{@timeout}s), killing"
      kill_worker(:KILL, wpid) # take no prisoners for timeout violations
    end
    next_sleep <= 0 ? 1 : next_sleep
  end

  def after_fork_internal
    @self_pipe.each(&:close).clear # this is master-only, now
    @ready_pipe.close if @ready_pipe
    Unicorn::Configurator::RACKUP.clear
    @ready_pipe = @init_listeners = @before_fork = nil

    # The OpenSSL PRNG is seeded with only the pid, and apps with frequently
    # dying workers can recycle pids
    OpenSSL::Random.seed(rand.to_s) if defined?(OpenSSL::Random)
  end

  def spawn_missing_workers
    if @worker_data
      worker = Unicorn::Worker.new(*@worker_data)
      after_fork_internal
      worker_loop(worker)
      exit
    end

    worker_nr = -1
    until (worker_nr += 1) == @worker_processes
      @workers.value?(worker_nr) and next
      worker = Unicorn::Worker.new(worker_nr)
      before_fork.call(self, worker)

      pid = fork do
        after_fork_internal
        worker_loop(worker)
        exit
      end

      @workers[pid] = worker
      worker.atfork_parent
    end
  rescue => e
    @logger.error(e) rescue nil
    exit!
  end

  def maintain_worker_count
    (off = @workers.size - worker_processes) == 0 and return
    off < 0 and return spawn_missing_workers
    @workers.each_value { |w| w.nr >= worker_processes and w.soft_kill(:QUIT) }
  end

  # if we get any error, try to write something back to the client
  # assuming we haven't closed the socket, but don't get hung up
  # if the socket is already closed or broken.  We'll always ensure
  # the socket is closed at the end of this function
  def handle_error(client, e)
    code = case e
    when EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::ENOTCONN
      # client disconnected on us and there's nothing we can do
    when Unicorn::RequestURITooLongError
      414
    when Unicorn::RequestEntityTooLargeError
      413
    when Unicorn::HttpParserError # try to tell the client they're bad
      400
    else
      Unicorn.log_error(@logger, "app error", e)
      500
    end
    if code
      client.write_nonblock(err_response(code, @request.response_start_sent), exception: false)
    end
    client.close
  rescue
  end

  def e103_response_write(client, headers)
    response = if @request.response_start_sent
      "103 Early Hints\r\n"
    else
      "HTTP/1.1 103 Early Hints\r\n"
    end

    headers.each_pair do |k, vs|
      next if !vs || vs.empty?
      values = vs.to_s.split("\n".freeze)
      values.each do |v|
        response << "#{k}: #{v}\r\n"
      end
    end
    response << "\r\n".freeze
    response << "HTTP/1.1 ".freeze if @request.response_start_sent
    client.write(response)
  end

  def e100_response_write(client, env)
    # We use String#freeze to avoid allocations under Ruby 2.1+
    # Not many users hit this code path, so it's better to reduce the
    # constant table sizes even for Ruby 2.0 users who'll hit extra
    # allocations here.
    client.write(@request.response_start_sent ?
                 "100 Continue\r\n\r\nHTTP/1.1 ".freeze :
                 "HTTP/1.1 100 Continue\r\n\r\n".freeze)
    env.delete('HTTP_EXPECT'.freeze)
  end

  # once a client is accepted, it is processed in its entirety here
  # in 3 easy steps: read request, call app, write app response
  def process_client(client)
    @request = Unicorn::HttpRequest.new
    env = @request.read(client)

    if early_hints
      env["rack.early_hints"] = lambda do |headers|
        e103_response_write(client, headers)
      end
    end

    env["rack.after_reply"] = []

    status, headers, body = @app.call(env)

    begin
      return if @request.hijacked?

      if 100 == status.to_i
        e100_response_write(client, env)
        status, headers, body = @app.call(env)
        return if @request.hijacked?
      end
      @request.headers? or headers = nil
      http_response_write(client, status, headers, body, @request)
    ensure
      body.respond_to?(:close) and body.close
    end

    unless client.closed? # rack.hijack may've close this for us
      client.shutdown # in case of fork() in Rack app
      client.close # flush and uncork socket immediately, no keepalive
    end
  rescue => e
    handle_error(client, e)
  ensure
    env["rack.after_reply"].each(&:call) if env
  end

  def nuke_listeners!(readers)
    # only called from the worker, ordering is important here
    tmp = readers.dup
    readers.replace([false]) # ensure worker does not continue ASAP
    tmp.each { |io| io.close rescue nil } # break out of IO.select
  end

  # gets rid of stuff the worker has no business keeping track of
  # to free some resources and drops all sig handlers.
  # traps for USR1, USR2, and HUP may be set in the after_fork Proc
  # by the user.
  def init_worker_process(worker)
    worker.atfork_child
    # we'll re-trap :QUIT later for graceful shutdown iff we accept clients
    exit_sigs = [ :QUIT, :TERM, :INT ]
    exit_sigs.each { |sig| trap(sig) { exit!(0) } }
    exit!(0) if (@sig_queue & exit_sigs)[0]
    (@queue_sigs - exit_sigs).each { |sig| trap(sig, nil) }
    trap(:CHLD, 'DEFAULT')
    @sig_queue.clear
    proc_name "worker[#{worker.nr}]"
    START_CTX.clear
    @workers.clear

    after_fork.call(self, worker) # can drop perms and create listeners
    LISTENERS.each { |sock| sock.close_on_exec = true }

    worker.user(*user) if user.kind_of?(Array) && ! worker.switched
    @config = nil
    @after_fork = @listener_opts = @orig_app = nil
    readers = LISTENERS.dup
    readers << worker
    trap(:QUIT) { nuke_listeners!(readers) }
    readers
  end

  def reopen_worker_logs(worker_nr)
    logger.info "worker=#{worker_nr} reopening logs..."
    Unicorn::Util.reopen_logs
    logger.info "worker=#{worker_nr} done reopening logs"
    false
  rescue => e
    logger.error(e) rescue nil
    exit!(77) # EX_NOPERM in sysexits.h
  end

  if Unicorn.const_defined?(:Waiter)
    def prep_readers(readers)
      wtr = Unicorn::Waiter.prep_readers(readers)
      @timeout *= 500 # to milliseconds for epoll, but halved
      wtr
    end
  else
    require_relative 'select_waiter'
    def prep_readers(_readers)
      @timeout /= 2.0 # halved for IO.select
      Unicorn::SelectWaiter.new
    end
  end

  # runs inside each forked worker, this sits around and waits
  # for connections and doesn't die until the parent dies (or is
  # given a INT, QUIT, or TERM signal)
  def worker_loop(worker)
    readers = init_worker_process(worker)
    waiter = prep_readers(readers)
    reopen = false

    # this only works immediately if the master sent us the signal
    # (which is the normal case)
    trap(:USR1) { reopen = true }

    ready = readers.dup
    @after_worker_ready.call(self, worker)

    begin
      reopen = reopen_worker_logs(worker.nr) if reopen
      worker.tick = time_now.to_i
      while sock = ready.shift
        # Unicorn::Worker#accept_nonblock is not like accept(2) at all,
        # but that will return false
        client = sock.accept_nonblock(exception: false)
        client = false if client == :wait_readable
        if client
          process_client(client)
          worker.tick = time_now.to_i
        end
        break if reopen
      end

      # timeout so we can .tick and keep parent from SIGKILL-ing us
      worker.tick = time_now.to_i
      waiter.get_readers(ready, readers, @timeout)
    rescue => e
      redo if reopen && readers[0]
      Unicorn.log_error(@logger, "listen loop error", e) if readers[0]
    end while readers[0]
  end

  # delivers a signal to a worker and fails gracefully if the worker
  # is no longer running.
  def kill_worker(signal, wpid)
    Process.kill(signal, wpid)
  rescue Errno::ESRCH
    worker = @workers.delete(wpid) and worker.close rescue nil
  end

  # delivers a signal to each worker
  def kill_each_worker(signal)
    @workers.keys.each { |wpid| kill_worker(signal, wpid) }
  end

  def soft_kill_each_worker(signal)
    @workers.each_value { |worker| worker.soft_kill(signal) }
  end

  def load_config!
    loaded_app = app
    logger.info "reloading config_file=#{config.config_file}"
    config[:listeners].replace(@init_listeners)
    config.load
    config.commit!(self)
    soft_kill_each_worker(:QUIT)
    Unicorn::Util.reopen_logs
    self.app = @orig_app
    build_app!
    logger.info "done reloading config_file=#{config.config_file}"
  rescue StandardError, LoadError, SyntaxError => e
    Unicorn.log_error(@logger,
        "error reloading config_file=#{config.config_file}", e)
    self.app = loaded_app
  end

  # returns an array of string names for the given listener array
  def listener_names(listeners = LISTENERS)
    listeners.map { |io| sock_name(io) }
  end

  def build_app!
    if app.respond_to?(:arity) && (app.arity == 0 || app.arity == 2)
      if defined?(Gem) && Gem.respond_to?(:refresh)
        logger.info "Refreshing Gem list"
        Gem.refresh
      end
      self.app = app.arity == 0 ? app.call : app.call(nil, self)
    end
  end

  def proc_name(tag)
    $0 = ([ File.basename(START_CTX[0]), tag
          ]).concat(START_CTX[:argv]).join(' ')
  end

  def redirect_io(io, path)
    File.open(path, 'ab') { |fp| io.reopen(fp) } if path
    io.sync = true
  end

  def inherit_listeners!
    # inherit sockets from parents, they need to be plain Socket objects
    # before they become UNIXServer or TCPServer
    inherited = ENV['UNICORN_FD'].to_s.split(',')

    # emulate sd_listen_fds() for systemd
    sd_pid, sd_fds = ENV.values_at('LISTEN_PID', 'LISTEN_FDS')
    if sd_pid.to_i == $$ # n.b. $$ can never be zero
      # 3 = SD_LISTEN_FDS_START
      inherited.concat((3...(3 + sd_fds.to_i)).to_a)
    end
    # to ease debugging, we will not unset LISTEN_PID and LISTEN_FDS

    inherited.map! do |fd|
      io = Socket.for_fd(fd.to_i)
      io.autoclose = false
      io = server_cast(io)
      set_server_sockopt(io, listener_opts[sock_name(io)])
      logger.info "inherited addr=#{sock_name(io)} fd=#{io.fileno}"
      io
    end

    config_listeners = config[:listeners].dup
    LISTENERS.replace(inherited)

    # we start out with generic Socket objects that get cast to either
    # TCPServer or UNIXServer objects; but since the Socket
    # objects share the same OS-level file descriptor as the higher-level
    # *Server objects; we need to prevent Socket objects from being
    # garbage-collected
    config_listeners -= listener_names
    if config_listeners.empty? && LISTENERS.empty?
      config_listeners << Unicorn::Const::DEFAULT_LISTEN
      @init_listeners << Unicorn::Const::DEFAULT_LISTEN
      START_CTX[:argv] << "-l#{Unicorn::Const::DEFAULT_LISTEN}"
    end
    NEW_LISTENERS.replace(config_listeners)
  end

  # call only after calling inherit_listeners!
  # This binds any listeners we did NOT inherit from the parent
  def bind_new_listeners!
    NEW_LISTENERS.each { |addr| listen(addr) }.clear
    raise ArgumentError, "no listeners" if LISTENERS.empty?
  end

  # try to use the monotonic clock in Ruby >= 2.1, it is immune to clock
  # offset adjustments and generates less garbage (Float vs Time object)
  begin
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def time_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  rescue NameError, NoMethodError
    def time_now # Ruby <= 2.0
      Time.now
    end
  end
end
