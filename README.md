# lua-jsonreq

JSON over HTTP(S) and JSON-RPC 2.0 client helpers for Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.

## Install

```sh
luarocks make rockspecs/lua-jsonreq-0.1.0-1.rockspec
```

Requires `luasocket` and a JSON library (`lua-cjson`, falling back to `dkjson`).
HTTPS URLs also need `luasec`; it is only loaded when an `https://` URL is used.

## Usage

```lua
local jsonreq = require("jsonreq")

-- JSON-RPC 2.0
local rpc = jsonreq.new({ url = "http://localhost:8545", headers = { Authorization = "Bearer ..." } })
local res, code = rpc:rpc("add", { 1, 2 })   -- POST {"jsonrpc":"2.0","method":"add","params":[1,2],"id":1}
print(res.result)
print(rpc.proxy.add(1, 2).result)             -- same, via proxy (rpc:proxy().add(1, 2) also works)

-- REST
local api = jsonreq.new("https://api.example.com")
local body, code, headers, raw = api:get("/items")
api:post("/items", { name = "x" })
api:put("/items/1", { name = "y" })
api:patch("/items/1", { name = "z" })
api:delete("/items/1")
api:update("/items/1", { name = "z" })        -- alias of patch(): sends PATCH
api:get("/slow", nil, 120)                    -- per-call timeout (seconds)
```

`update()` is kept for backward compatibility but is an alias of `patch()`:
`UPDATE` is not an HTTP method, `PATCH` is (RFC 5789).

### Options for `jsonreq.new(opt)` (or a URL string)

| field | meaning |
|---|---|
| `url` | base URL; the `resource` argument is appended |
| `headers` | headers added to every request (per-call headers override) |
| `params` | params merged into every JSON-RPC `params` |
| `root` | fields merged into every JSON-RPC envelope / table payload |
| `timeout` | request timeout in seconds (default `jsonreq.TIMEOUT` = 30), applied to both HTTP and HTTPS |
| `enabled` | `false` makes every call return `nil, "disabled"` |
| `transport` | luasocket-style `request(t)` function (for tests, proxies, timeouts) |
| `request_handler` | full replacement `function(self, payload, headers, resource, method)` |

### Timeouts

Precedence: per-call argument > client `opt.timeout` > `jsonreq.TIMEOUT` (30 s).
Per-call: last argument of `get(resource, headers, timeout)`, `delete(...)`,
`post/put/patch(resource, payload, headers, timeout)`, `call(payload, headers, resource, method, timeout)`
and `rpc(method, params, id, headers, resource, timeout)`. A timeout is returned as `nil, "timeout"`
for both HTTP and HTTPS (luasec's `"wantread"`/`"wantwrite"` are normalized), never thrown. Custom `transport`
functions receive the value as `t.timeout`.

### Return values

* success: `decoded_body, status, response_headers, raw_body` (`decoded_body` is `nil` for an empty body)
* transport error: `nil, error_message`
* non-JSON body: `nil, status, response_headers, raw_body, decode_error`
* encode error / disabled: `nil, error_message`

Errors are returned, never thrown. JSON-RPC errors are in `body.error`.

### HTTPS certificates

HTTPS uses luasec's default client config, which is `verify = "none"`: certificates are
**not** verified (this is why self-signed devices such as Hue bridges work, but it offers
no protection against MITM). Behaviour is unchanged from 0.0.2.

Module settings: `jsonreq.verbose = true` prints method, URL and payload (may expose secrets);
`jsonreq.json` can be replaced with any table exposing `encode`/`decode`.

## Tests

```sh
lua tests/test.lua
```

No network needed; a fake transport is used.

## License

MIT
