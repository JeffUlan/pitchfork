# Configuration

Most of Pitchfork configuration is directly inherited from Unicorn, however several
options have been removed, and a few added.

## Basic configurations

### `worker_processes`

```ruby
worker_processes 16
```

Sets the number of desired worker processes.
Each worker process will serve exactly one client at a time.

### `listen`

By default pitchfork listen to port 8080.

```ruby
listen 2007
listen "/path/to/.pitchfork.sock", backlog: 64
listen 8080, tcp_nopush: true
```

Adds an address to the existing listener set. May be specified more
than once. address may be an Integer port number for a TCP port, an
`IP_ADDRESS:PORT` for TCP listeners or a pathname for UNIX domain sockets.

```ruby
listen 3000 # listen to port 3000 on all TCP interfaces
listen "127.0.0.1:3000"  # listen to port 3000 on the loopback interface
listen "/path/to/.pitchfork.sock" # listen on the given Unix domain socket
listen "[::1]:3000" # listen to port 3000 on the IPv6 loopback interface
```

When using Unix domain sockets, be sure:
1) the path matches the one used by nginx
2) uses the same filesystem namespace as the nginx process
For systemd users using PrivateTmp=true (for either nginx or pitchfork),
this means Unix domain sockets must not be placed in /tmp

The following options may be specified (but are generally not needed):

- `backlog: number of clients`

  This is the backlog of the listen() syscall.

  Some operating systems allow negative values here to specify the
  maximum allowable value.  In most cases, this number is only
  recommendation and there are other OS-specific tunables and
  variables that can affect this number.  See the listen(2)
  syscall documentation of your OS for the exact semantics of
  this.

  If you are running pitchfork on multiple machines, lowering this number
  can help your load balancer detect when a machine is overloaded
  and give requests to a different machine.

  Default: `1024`

  Note: with the Linux kernel, the net.core.somaxconn sysctl defaults
  to 128, capping this value to 128.  Raising the sysctl allows a
  larger backlog (which may not be desirable with multiple,
  load-balanced machines).

- `rcvbuf: bytes, sndbuf: bytes`

  Maximum receive and send buffer sizes (in bytes) of sockets.

  These correspond to the SO_RCVBUF and SO_SNDBUF settings which
  can be set via the setsockopt(2) syscall.  Some kernels
  (e.g. Linux 2.4+) have intelligent auto-tuning mechanisms and
  there is no need (and it is sometimes detrimental) to specify them.

  See the socket API documentation of your operating system
  to determine the exact semantics of these settings and
  other operating system-specific knobs where they can be
  specified.

  Defaults: operating system defaults

- `tcp_nodelay: false`

  Enables Nagle's algorithm on TCP sockets if +false+.

  Default: +true+ (Nagle's algorithm disabled)

  Setting this to +false+ can help in situation where the network between
  pitchfork and the reverse proxy may be congested. In most case it's not
  necessary.

  This has no effect on UNIX sockets.

- `tcp_nopush: true or false`

  Enables/disables TCP_CORK in Linux or TCP_NOPUSH in FreeBSD

  This prevents partial TCP frames from being sent out and reduces
  wakeups in nginx if it is on a different machine.
  Since pitchfork is only designed for applications that send the response body
  quickly without keepalive, sockets will always be flushed on close to prevent delays.

  This has no effect on UNIX sockets.

  Default: `false` (disabled)

- `ipv6only: true or false`

  This option makes IPv6-capable TCP listeners IPv6-only and unable
  to receive IPv4 queries on dual-stack systems.
  A separate IPv4-only listener is required if this is true.

  Enabling this option for the IPv6-only listener and having a
  separate IPv4 listener is recommended if you wish to support IPv6
  on the same TCP port.  Otherwise, the value of `env["REMOTE_ADDR"]`
  will appear as an ugly IPv4-mapped-IPv6 address for IPv4 clients
  (e.g `:ffff:10.0.0.1` instead of just `10.0.0.1`).

  Default: Operating-system dependent

- `reuseport: true or false`

  This enables multiple, independently-started pitchfork instances to
  bind to the same port (as long as all the processes enable this).

  This option must be used when pitchfork first binds the listen socket.

  Note: there is a chance of connections being dropped if
  one of the pitchfork instances is stopped while using this.

  This is supported on *BSD systems and Linux 3.9 or later.

  ref: https://lwn.net/Articles/542629/

  Default: `false` (unset)

- `umask: mode`

  Sets the file mode creation mask for UNIX sockets.
  If specified, this is usually in octal notation.

  Typically UNIX domain sockets are created with more liberal
  file permissions than the rest of the application.
  By default, we create UNIX domain sockets to be readable and writable by
  all local users to give them the same accessibility as locally-bound TCP listeners.

  This has no effect on TCP listeners.

  Default: `0000` (world-read/writable)

- `tcp_defer_accept: Integer`

  Defer `accept()` until data is ready (Linux-only)

  For Linux 2.6.32 and later, this is the number of retransmits to
  defer an `accept()` for if no data arrives, but the client will
  eventually be accepted after the specified number of retransmits
  regardless of whether data is ready.

  For Linux before 2.6.32, this is a boolean option, and
  accepts are _always_ deferred indefinitely if no data arrives.

  Specifying `true` is synonymous for the default value(s) below,
  and `false` or `nil` is synonymous for a value of zero.

  A value of `1` is a good optimization for local networks and trusted clients.
  There is no good reason to ever disable this with a +zero+ value with pitchfork.

  Default: `1`

### `timeout`

```ruby
timeout 10
```

Sets the timeout of worker processes to a number of seconds.
Workers handling the request/app.call/response cycle taking longer than
this time period will be forcibly killed (via `SIGKILL`).

This timeout mecanism shouldn't be routinely relying on, and should
instead be considered as a last line of defense in case you application
is impacted by bugs causing unexpectedly slow response time, or fully stuck
processes.

Make sure to read the guide on [application timeouts](Application_Timeouts.md).

This configuration defaults to a (too) generous 20 seconds, it is
highly recommended to set a stricter one based on your application
profile.

This timeout is enforced by the master process itself and not subject
to the scheduling limitations by the worker process.
Due the low-complexity, low-overhead implementation, timeouts of less
than 3.0 seconds can be considered inaccurate and unsafe.

For running Pitchfork behind nginx, it is recommended to set
"fail_timeout=0" for in your nginx configuration like this
to have nginx always retry backends that may have had workers
SIGKILL-ed due to timeouts.

```
   upstream pitchfork_backend {
     # for UNIX domain socket setups:
     server unix:/path/to/.pitchfork.sock fail_timeout=0;

     # for TCP setups
     server 192.168.0.7:8080 fail_timeout=0;
     server 192.168.0.8:8080 fail_timeout=0;
     server 192.168.0.9:8080 fail_timeout=0;
   }
```

See https://nginx.org/en/docs/http/ngx_http_upstream_module.html
for more details on nginx upstream configuration.

### `logger`

```ruby
logger Logger.new("path/to/logs")
```

Replace the default logger by the provided one.
The passed logger must respond to the standard Ruby Logger interface.
The default Logger will log its output to STDERR.

## Callbacks

Because pitchfork several callbacks around the lifecycle of workers.
It is often necessary to use these callbacks to close inherited connection after fork.

Note that when reforking is available, the `pitchfork` master process won't load your application
at all. As such for hooks executed in the master, you may need to explicitly load the parts of your
application that are used in hooks.

`pitchfork` also don't attempt to rescue hook errors. Raising from a worker hook will crash the worker,
and raising from a master hook will bring the whole cluster down.

### `before_fork`

```ruby
before_fork do |server, worker|
  Database.disconnect!
end
```

Called in the context of the parent or mold.
For most protocols connections can be closed after fork, but some
stateful protocols require to close connections before fork.

That is the case for instance of many SQL databases protocols.

### `after_fork`

```ruby
after_fork do |server, worker|
  NetworkClient.disconnect!
end
```

Called in the worker after forking. Generally used to close inherited connections
or to restart backgrounds threads for libraries that don't do it automatically.

### `after_promotion`

```ruby
after_promotion do |server, mold|
  NetworkClient.disconnect!
  4.times { GC.start } # promote surviving objects to oldgen
  GC.compact
end
```

Called in the worker after it was promoted into a mold. Generally used to shutdown
open connections and file descriptors, as well as to perform memory optimiations
such as compacting the heap, trimming memory etc.

### `after_worker_ready`

Called by a worker process after it has been fully loaded, directly before it
starts responding to requests:

```ruby
after_worker_ready do |server, worker|
  server.logger.info("worker #{worker.nr} ready")
end
```

### `after_worker_exit`

Called in the master process after a worker exits.

```ruby
after_worker_exit do |server, worker, status|
  # status is a Process::Status instance for the exited worker process
  unless status.success?
    server.logger.error("worker process failure: #{status.inspect}")
  end
end
```

## Reforking

### `refork_after`

```ruby
refork_after [50, 100, 1000]
```

Sets a number of requests threshold for triggering an automatic refork.
The limit is per-worker, for instance with `refork_after [50]` a refork is triggered
once at least one worker processed `50` requests.

Each element is a limit for the next generation. On the example above a new generation
is triggered when a worker has processed 50 requests, then the second generation when
a worker from the new generation processed an additional 100 requests and finally after another
1000 requests.

Generally speaking Copy-on-Write efficiency tend to degrade fast during the early requests,
and then less and less frequently.

As such you likely want to refork exponentially less and less over time.

By default automatic reforking isn't enabled.

Make sure to read the [fork safety guide](FORK_SAFETY.md) before enabling reforking.

### `mold_selector`

Sets the mold selector implementation.

```ruby
mold_selector do |server|
  candidate = server.children.workers.sample # return an random worker
  server.logger.info("worker=#{worker.nr} pid=#{worker.pid} selected as new mold")
  candidate
end
```

The has access to `server.children` a `Pitchfork::Children` instance.
This object can be used to introspect the state of the cluster and select the most
appropriate worker to be used as the new mold from which workers will be reforked.

The default implementation selects the worker with the least
amount of shared memory. This heuristic aim to select the most
warmed up worker.

This should be considered a very advanced API and it is discouraged
to use it unless you are confident you have a clear understanding
of pitchfork's architecture.

## Rack Features

### `default_middleware`

Sets whether to add Pitchfork's default middlewares. Defaults to `true`.

### `early_hints`

Sets whether to enable the proposed early hints Rack API. Defaults to `false`.

If enabled, Rails 5.2+ will automatically send a 103 Early Hint for all the `javascript_include_tag` and `stylesheet_link_tag`
in your response. See: https://api.rubyonrails.org/v5.2/classes/ActionDispatch/Request.html#method-i-send_early_hints
See also https://tools.ietf.org/html/rfc8297

## Advanced Tuning Configurations

Make sure to read the tuning guide before tweaking any of these.
Also note that most of these options are inherited from Unicorn, so
most guides on how to tune Unicorn likely apply here.

### `rewindable_input`

Toggles making `env["rack.input"]` rewindable.
Disabling rewindability can improve performance by lowering I/O and memory usage for applications that accept uploads.
Keep in mind that the Rack 1.x spec requires `env["rack.input"]` to be rewindable, but the Rack 2.x spec does not.

`rewindable_input` defaults to `true` for compatibility.
Setting it to `false` may be safe for applications and frameworks developed for Rack 2.x and later.

### `client_body_buffer_size`

The maximum size in bytes to buffer in memory before resorting to a temporary file.
Default is `112` kilobytes.
This option has no effect if `rewindable_input` is set to `false`.

### `check_client_connection`

When enabled, pitchfork will check the client connection by writing
the beginning of the HTTP headers before calling the application.

This will prevent calling the application for clients who have
disconnected while their connection was queued.

This only affects clients connecting over Unix domain sockets
and TCP via loopback (`127.*.*.*`).
It is unlikely to detect disconnects if the client is on a remote host (even on a fast LAN).

This option cannot be used in conjunction with `tcp_nopush`.