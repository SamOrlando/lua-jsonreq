# lua-jsonreq

JSON over HTTP(S) and JSON-RPC 2.0 client helpers for Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.

## Install

```sh
luarocks make rockspecs/lua-jsonreq-0.2.2-1.rockspec
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
api:patch("/items/1", { name = "z" })         -- PATCH (RFC 5789)
api:delete("/items/1")
api:get("/slow", nil, 120)                    -- per-call timeout (seconds)
```

`:patch` sends `PATCH`. There is no `:update`.

### Options for `jsonreq.new(opt)` (or a URL string)

| field | meaning |
|---|---|
| `url` | base URL; the `resource` argument is appended |
| `headers` | headers added to every request (per-call headers override). Stored as the table you pass |
| `params` | named params merged into every JSON-RPC object `params` (not into a positional array). Stored as the table you pass |
| `root` | extra members. On a JSON-RPC object it cannot set the protocol names. On `:call` it is written into the payload table you pass. Stored as the table you pass |
| `timeout` | request timeout in seconds (default `jsonreq.TIMEOUT` = 15), applied to both HTTP and HTTPS |
| `enabled` | `false` makes every call return `nil, "disabled"` |
| `transport` | luasocket-style `request(t)` function (for tests, proxies, timeouts) |
| `request_handler` | full replacement `function(self, payload, headers, resource, method, timeout)` |

### Timeouts

Precedence: per-call argument > client `opt.timeout` > `jsonreq.TIMEOUT` (15 s).
Per-call: last argument of `get(resource, headers, timeout)`, `delete(...)`,
`post/put/patch(resource, payload, headers, timeout)`, `call(payload, headers, resource, method, timeout)`
and `request(method, params, id, headers, resource, timeout)`. A timeout is returned as `nil, "timeout"`
for both HTTP and HTTPS (luasec's `"wantread"`/`"wantwrite"` are normalized), never thrown. Custom `transport`
functions receive the value as `t.timeout`.

### Return values

* success: `decoded_body, status, response_headers, raw_body` (`decoded_body` is `nil` for an empty body)
* transport error: `nil, error_message`
* non-JSON body: `nil, status, response_headers, raw_body, decode_error`
* encode error / disabled / rejected request: `nil, error_message`
* JSON-RPC response that breaks the 2.0 rules: `nil, status, response_headers, raw_body, error_message`

Errors are returned, never thrown. A JSON-RPC **error object** that follows the spec is a successful response: read `body.error`.

Every call sets `Content-Type` to `application/json` and `Content-Length` to the body size in bytes, including GET and DELETE (`Content-Length` is `0` when there is no body). Those two exact keys replace yours. Any other spelling, such as `content-type`, is copied through unchanged. Header tables you pass are not modified.

### JSON-RPC 2.0

`:request(method, params, id, headers, resource, timeout)` posts one request object. `:rpc` is the same function.

* `method` is a string.
* `params` is an array or an object. An empty Lua table is omitted (`{}` cannot be told from `[]`). Pass `json.empty_array` (lua-cjson) to send `"params":[]`.
* `client.params` is merged into named parameters and overrides the same key. Merging it into a positional array returns an error and sends nothing. The params table you pass to `:request` is not modified.
* A missing `id` is an integer, starting at 1 for each client. Pass a string, an integer (`0` is kept), or `jsonreq.json.null`. Fractional numbers are rejected.
* A notification has no `id`. Call `:notify(method, params, headers, resource, timeout)`, or pass `false` as the id. An empty body is success. A normal call with an empty body returns `jsonreq: empty response`.
* `client.root` may add members on the request object. It cannot replace `jsonrpc`, `method`, `params`, or `id`. `:call` writes those members into the payload table you pass.
* A normal response must be one object with `"jsonrpc":"2.0"`, the same `id`, and exactly one of `result` or `error`. `error.code` is an integer and `error.message` is a string. `result` may be `false`, `0`, or `null`.
* A JSON `null` standing in for the unused member is accepted (`"error": null` beside a result, or `"result": null` beside an error). A real result beside a real error is rejected.
* `:validate_response(table)` checks that shape. It does not compare the id with a request.

This client does not send a batch or speak JSON-RPC 1.0.

### JSON-RPC responses

These build a response object. They do not send it. `id` is the request id to echo. Lua `nil` becomes JSON `null` (the id was not available, or the result is null). A response id does not use the client's request id counter. There is no `:response` or `:error` method. Post the string yourself with `:post` or `:call`.

```lua
local tbl = rpc:response_table(19, req.id)             -- {jsonrpc="2.0", result=19, id=req.id}
local raw = rpc:response_string(19, req.id)            -- encoded
api:post("/rpc", raw)

local err = rpc:error_table(-32601, "Method not found", req.id, { name = "add" })
local eraw = rpc:error_string(-32601, "Method not found", req.id)
```

`error.code` is an integer and `error.message` is a string. `data` is omitted when nil. The object has `error` and not `result`. `client.root` may add members and cannot set `jsonrpc`, `result`, `error`, or `id`.

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
