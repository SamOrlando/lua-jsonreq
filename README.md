# lua-jsonreq

JSON over HTTP(S) and JSON-RPC 2.0 client helpers for Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.

## Install

```sh
luarocks make rockspecs/lua-jsonreq-0.1.1-1.rockspec
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
print(rpc.proxy.sum(nil, 5).result[1])        -- nil becomes JSON null
rpc:notify("log", { "ready" })                -- notification: no id, empty body is success

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
| `params` | named params merged into every JSON-RPC object `params` (not into a positional array) |
| `root` | extra request members. Cannot set `jsonrpc`, `method`, `params`, or `id` |
| `timeout` | request timeout in seconds (default `jsonreq.TIMEOUT` = 30), applied to both HTTP and HTTPS |
| `enabled` | `false` makes every call return `nil, "disabled"` |
| `transport` | luasocket-style `request(t)` function (for tests, proxies, timeouts) |
| `request_handler` | full replacement `function(self, payload, headers, resource, method, timeout)` |

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
* encode error / disabled / rejected request: `nil, error_message`
* JSON-RPC response that breaks the 2.0 rules: `nil, status, response_headers, raw_body, error_message`

Errors are returned, never thrown. A JSON-RPC **error object** that follows the spec is a successful response: read `body.error`.

### JSON-RPC 2.0

`:rpc(method, params, id, headers, resource, timeout)` posts one request object.

* `method` is a string.
* `params` is an array or an object. An empty Lua table is omitted (`{}` cannot be told from `[]`). Pass `json.empty_array` (lua-cjson) to send `"params":[]`.
* `client.params` is merged into named parameters and overrides the same key. Merging it into a positional array returns an error and sends nothing. The table you pass is not modified.
* A missing `id` is an integer, starting at 1 for each client. Pass a string, an integer (`0` is kept), or `jsonreq.json.null`. Fractional numbers are rejected.
* A notification has no `id`. Call `:notify(method, params, headers, resource, timeout)`, or pass `jsonreq.notification` or `false` as the id. An empty body is success. A normal call with an empty body returns `jsonreq: empty response`.
* `client.root` may add members. It cannot replace `jsonrpc`, `method`, `params`, or `id`.
* A normal response must be one object with `"jsonrpc":"2.0"`, the same `id`, and exactly one of `result` or `error`. `error.code` is an integer and `error.message` is a string. `result` may be `false`, `0`, or `null`.
* A JSON `null` standing in for the unused member is accepted (`"error": null` beside a result, or `"result": null` beside an error). A real result beside a real error is rejected.

This client does not send a batch or speak JSON-RPC 1.0.

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
