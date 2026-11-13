# roadrunner_cowmachine

Run [cowmachine](https://github.com/zotonic/cowmachine) applications, such
as [Zotonic](https://github.com/zotonic/zotonic), on
[Roadrunner](https://github.com/arizona-framework/roadrunner).

cowmachine runs on Cowboy by default, and lets you pick its HTTP server.
`roadrunner_cowmachine` is a cowmachine server: set it in your config, and
your listeners, middlewares, controllers, and WebSocket handlers run on
Roadrunner as they are.

## 🚧 Status

roadrunner_cowmachine is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version
in your deps if you need stability across upgrades.

## Installation

Add it next to `cowmachine` in your `rebar.config` (latest version on
[Hex](https://hex.pm/packages/roadrunner_cowmachine)):

```erlang
{deps, [
    cowmachine,
    roadrunner_cowmachine
]}.
```

Make it cowmachine's server in your `sys.config`:

```erlang
[{cowmachine, [
    {server, roadrunner_cowmachine}
]}].
```

## Starting a listener

Start listeners with `cowmachine_server:start_listener/2`, as you would on
Cowboy:

```erlang
{ok, _} = cowmachine_server:start_listener(my_listener, #{
    port => 8000,
    middlewares => [my_dispatcher, cowmachine],
    env => #{cowmachine_controller => my_controller}
}).
```

It takes the options you already use with cowmachine:

- `port` and `ip`, with `ipv6_v6only` for an IPv6 address
- `tls` with the `ssl` server options for HTTPS
- `backlog`, `max_connections`, `num_acceptors` and `request_timeout`
- `middlewares` and `env`
- `metrics_callback`, with `metrics_req_filter` and
  `metrics_resp_headers_filter`, called once per request with the same
  metrics as Cowboy's
- `options`: the server's own options, here any
  [Roadrunner listener option](https://hexdocs.pm/roadrunner/roadrunner_listener.html#t:opts/0)

```erlang
{ok, _} = cowmachine_server:start_listener(my_listener, #{
    port => 8000,
    middlewares => [my_dispatcher, cowmachine],
    options => #{max_concurrent_requests => 10_000}
}).
```

## Writing code for any server

Middlewares get a request map shaped like Cowboy's, so matching on it
(`#{path := Path}`, `#{bindings := Bindings}`) works on every server, and
controllers use `cowmachine_req` as always.

For the raw request, use `cowmachine_cowreq`, which has the same functions
as `cowboy_req`:

```erlang
execute(Req0, Env) ->
    case cowmachine_cowreq:header(~"x-api-key", Req0) of
        undefined -> {stop, cowmachine_cowreq:reply(401, Req0)};
        _Key -> {ok, Req0, Env}
    end.
```

Code that calls `cowboy_req` to send a response or read the body runs on
Cowboy only.

## Sponsors

roadrunner_cowmachine is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](https://github.com/arizona-framework/roadrunner_cowmachine/blob/main/CONTRIBUTING.md) for development setup,
testing guidelines, and contribution workflow.

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

roadrunner_cowmachine is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/roadrunner_cowmachine).

See [LICENSE.md](https://github.com/arizona-framework/roadrunner_cowmachine/blob/main/LICENSE.md) for more information.
