-- Plain-Lua tests: lua tests/test.lua   (from repo root)
package.path = "./?.lua;" .. package.path
local jr = require("jsonreq")
local json = jr.json
local pass, fail = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

-- fake luasocket-style transport capturing the request
local function fake(status, body, fail_msg)
	local last = {}
	return function(r)
		last.req = r
		if r.source then
			local t = {}
			while true do local c = r.source(); if not c then break end; t[#t+1] = c end
			last.body = table.concat(t)
		end
		if fail_msg then return nil, fail_msg end
		if body then r.sink(body); r.sink(nil) end
		return 1, status, { ["x-test"] = "1" }
	end, last
end

test("new from string, enabled default", function()
	local c = jr.new("http://x"); eq(c.url, "http://x"); eq(c.enabled, true)
	eq(jr.new({ enabled = false }).enabled, false)
end)

test("rpc builds valid request and decodes", function()
	local t, last = fake(200, '{"jsonrpc":"2.0","result":3,"id":1}')
	local c = jr.new({ url = "http://h", transport = t })
	c.headers.Authorization = "Bearer z"
	local res, code, rh = c:rpc("add", { 1, 2 })
	eq(code, 200); eq(res.result, 3); eq(rh["x-test"], "1")
	local sent = json.decode(last.body)
	eq(sent.jsonrpc, "2.0"); eq(sent.method, "add"); eq(sent.id, 1); eq(sent.params[2], 2)
	eq(last.req.method, "POST"); eq(last.req.url, "http://h")
	eq(last.req.headers.Authorization, "Bearer z")
	eq(last.req.headers["Content-Type"], "application/json")
	eq(last.req.headers["Content-Length"], tostring(#last.body))
end)

test("rpc ids increment, params omitted when empty", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t })
	c:rpc("a"); local s = json.decode(last.body); eq(s.id, 1); eq(s.params, nil)
	c:rpc("b", nil, "custom"); eq(json.decode(last.body).id, "custom")
	c:rpc("c"); eq(json.decode(last.body).id, 2)
end)

test("rpc does not mutate caller params; injects params/root", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t, params = { token = "k" }, root = { extra = true } })
	local p = { a = 1 }
	c:rpc("m", p)
	eq(p.token, nil)
	local s = json.decode(last.body); eq(s.params.token, "k"); eq(s.extra, true)
end)

test("proxy works both ways", function()
	local last = {}
	local function t(r)
		last.req = r
		local buf = {}
		if r.source then
			while true do local c = r.source(); if not c then break end; buf[#buf + 1] = c end
		end
		last.body = table.concat(buf)
		local req = json.decode(last.body)
		r.sink(json.encode({ jsonrpc = "2.0", result = "pong", id = req.id }))
		r.sink(nil)
		return 1, 200, { ["x-test"] = "1" }
	end
	local c = jr.new({ url = "http://h", transport = t })
	eq(c.proxy.ping(1).result, "pong"); eq(json.decode(last.body).method, "ping")
	eq(c:proxy().echo().result, "pong"); eq(json.decode(last.body).method, "echo")
	eq(c:proxy():ping(4, 1).result, "pong"); eq(json.decode(last.body).params[1], 4)
end)

test("REST verbs and resource", function()
	local t, last = fake(200, '[1,2]')
	local c = jr.new({ url = "http://h", transport = t })
	for _, v in ipairs({ "get", "delete" }) do
		local r = c[v](c, "/r"); eq(r[2], 2); eq(last.req.method, v:upper()); eq(last.req.url, "http://h/r")
	end
	for _, v in ipairs({ "post", "put", "patch" }) do
		local p = { x = 1 }
		c[v](c, "/r", p); eq(last.req.method, v:upper()); eq(json.decode(last.body).x, 1)
	end
	eq(c.update, nil)
end)

test("call writes root into the payload; content headers use the given case", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t, root = { r = 1 }, headers = { A = "inst", ["content-type"] = "text/plain" } })
	local p = { x = 1 }
	local h = { A = "call", ["Content-Type"] = "text/csv", ["content-length"] = "1" }
	c:post("", p, h)
	eq(p.x, 1); eq(p.r, 1)
	eq(h.A, "call"); eq(h["Content-Type"], "text/csv"); eq(h["content-length"], "1")
	eq(c.headers["content-type"], "text/plain")
	eq(last.req.headers.A, "call")
	eq(last.req.headers["Content-Type"], "application/json")
	eq(last.req.headers["content-type"], "text/plain")
	eq(last.req.headers["Content-Length"], tostring(#last.body))
	eq(last.req.headers["content-length"], "1")
	local sent = json.decode(last.body)
	eq(sent.x, 1); eq(sent.r, 1)
end)

test("empty body, bad json, transport failure", function()
	local c = jr.new({ url = "http://h", transport = (fake(204, nil)) })
	local r, code = c:get("/"); eq(r, nil); eq(code, 204)
	c.transport = (fake(500, "<html>oops"))
	local r2, code2, _, raw, err = c:get("/"); eq(r2, nil); eq(code2, 500); eq(raw, "<html>oops"); assert(err)
	c.transport = (fake(nil, nil, "connection refused"))
	local r3, e3 = c:get("/"); eq(r3, nil); eq(e3, "connection refused")
end)

test("disabled client does nothing", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t, enabled = false })
	local r, e = c:rpc("x"); eq(r, nil); eq(e, "disabled"); eq(last.req, nil)
end)

test("encode error returned, not thrown", function()
	local c = jr.new({ url = "http://h", transport = (fake(200, '{}')) })
	local r, e = c:post("", { f = function() end }); eq(r, nil); assert(e:find("encode"))
end)

test("timeout: default, client, per-call", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t })
	c:get("/"); eq(last.req.timeout, 15); eq(jr.TIMEOUT, 15)
	c.timeout = 5; c:get("/"); eq(last.req.timeout, 5)
	c:get("/", nil, 1.5); eq(last.req.timeout, 1.5)
	c:post("/", {}, nil, 2); eq(last.req.timeout, 2)
	c:rpc("m", nil, nil, nil, nil, 3); eq(last.req.timeout, 3)
	eq(jr.new({ timeout = 7, url = "http://h", transport = t }):get("/") and last.req.timeout, 7)
end)

-- real slow server (needs luasocket); skipped if unavailable
local ok_sock, socket = pcall(require, "socket")
if ok_sock and jr.default_transport then
	test("real timeout returned, not thrown", function()
		local srv = assert(socket.bind("127.0.0.1", 0))
		local _, port = srv:getsockname()
		local c = jr.new({ url = "http://127.0.0.1:" .. port, timeout = 0.3 })
		local t0 = socket.gettime()
		local r, e = c:get("/") -- server accepts in backlog but never answers
		local dt = socket.gettime() - t0
		srv:close()
		eq(r, nil); assert(tostring(e):find("timeout"), "err: " .. tostring(e))
		assert(dt < 2, "took " .. dt)
		eq(require("socket.http").TIMEOUT, 60, "module TIMEOUT restored")
	end)
	if pcall(require, "ssl.https") then
		test("real https timeout returned, not thrown", function()
			local srv = assert(socket.bind("127.0.0.1", 0))
			local _, port = srv:getsockname()
			local t0 = socket.gettime()
			local r, e = jr.new({ url = "https://127.0.0.1:" .. port, timeout = 0.3 }):get("/")
			local dt = socket.gettime() - t0
			srv:close()
			eq(r, nil); eq(e, "timeout"); assert(dt < 2, "took " .. dt)
			eq(require("ssl.https").TIMEOUT, 60, "module TIMEOUT restored")
		end)
	end
	test("real connection refused returned", function()
		local srv = assert(socket.bind("127.0.0.1", 0)); local _, port = srv:getsockname(); srv:close()
		local r, e = jr.new({ url = "http://127.0.0.1:" .. port, timeout = 1 }):get("/")
		eq(r, nil); assert(e)
	end)
end

test("positional params stay an array; named injection does not apply", function()
	local t, last = fake(200, '{"jsonrpc":"2.0","result":true,"id":1}')
	local c = jr.new({ url = "http://h", transport = t, params = { token = "k" } })
	local p = { 10, 20 }
	local res, err = c:rpc("sum", p)
	eq(res, nil); assert(tostring(err):find("positional"), err)
	eq(p.token, nil); eq(p[1], 10); eq(last.req, nil)
	c.params = {}
	local res2 = c:rpc("sum", { 10, 20 })
	eq(res2.result, true)
	local sent = json.decode(last.body)
	eq(sent.params[1], 10); eq(sent.params[2], 20); eq(sent.params.token, nil)
end)

test("empty array params and omitted empty table", function()
	local raw = jr.new("http://h"):rpc_string("m", json.empty_array, 1)
	assert(raw:find('"params":[]', 1, true), raw)
	local omitted = json.decode(jr.new("http://h"):rpc_string("m", {}, 1))
	eq(omitted.params, nil); eq(omitted.id, 1)
end)

test("notification omits id and accepts an empty body", function()
	local t, last = fake(204, nil)
	local c = jr.new({ url = "http://h", transport = t })
	c:rpc("a")
	local res, code, _, _, err = c:notify("update", { 1, 2, 3 })
	eq(res, nil); eq(code, 204); eq(err, nil)
	local sent = json.decode(last.body)
	eq(sent.id, nil); eq(sent.method, "update"); eq(sent.params[3], 3); eq(sent.jsonrpc, "2.0")
	c:rpc("b", nil, false)
	eq(json.decode(last.body).id, nil)
	c:rpc("c")
	eq(json.decode(last.body).id, 2)
end)

test("root cannot replace protocol members", function()
	local t, last = fake(200, '{"jsonrpc":"2.0","result":true,"id":1}')
	local c = jr.new({ url = "http://h", transport = t, root = { trace = "abc" } })
	eq(json.decode(select(1, c:rpc_string("ping", { a = 1 }, 1))).trace, "abc")
	c.root.jsonrpc = "1.0"
	local res, err = c:rpc("ping")
	eq(res, nil); assert(tostring(err):find("jsonrpc"), err); eq(last.req, nil)
	eq(c.next_id, 0)
end)

test("rejects bad method, params, and id without sending", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t })
	local r, e = c:rpc(1, { "bar" }); eq(r, nil); assert(tostring(e):find("method"), e)
	r, e = c:rpc("m", "bar"); eq(r, nil); assert(tostring(e):find("params"), e)
	r, e = c:rpc("m", { 1 }, 1.5); eq(r, nil); assert(tostring(e):find("integer"), e)
	eq(last.req, nil)
	eq(json.decode(c:rpc_string("m", { 1 }, 0)).id, 0)
	eq(json.decode(c:rpc_string("m", { 1 }, json.null)).id, json.null)
end)

test("response must match the request", function()
	local c = jr.new({ url = "http://h", transport = fake(200, '{"jsonrpc":"2.0","result":1,"id":99}') })
	local res, code, _, _, err = c:rpc("m", { 1 }, 1)
	eq(res, nil); eq(code, 200); assert(tostring(err):find("does not match"), err)

	c.transport = fake(200, '{"jsonrpc":"2.0","result":1,"error":{"code":-32603,"message":"x"},"id":1}')
	res, code, _, _, err = c:rpc("m", { 1 }, 1)
	eq(res, nil); assert(tostring(err):find("both"), err)

	c.transport = fake(200, '{"result":1,"id":1}')
	res, _, _, _, err = c:rpc("m", { 1 }, 1)
	eq(res, nil); assert(tostring(err):find("2.0"), err)

	c.transport = fake(200, '[{"jsonrpc":"2.0","result":1,"id":1}]')
	res, _, _, _, err = c:rpc("m", { 1 }, 1)
	eq(res, nil); assert(tostring(err):find("object"), err)

	c.transport = fake(204, nil)
	res, code, _, _, err = c:rpc("m", { 1 }, 1)
	eq(res, nil); eq(code, 204); assert(tostring(err):find("empty response"), err)
end)

test("valid error object is returned; null placeholders are accepted", function()
	local c = jr.new({ url = "http://h" })
	c.transport = fake(200, '{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found","data":"no"},"id":"1"}')
	local res = c:rpc("missing", {}, "1")
	eq(res.error.code, -32601); eq(res.error.message, "Method not found"); eq(res.error.data, "no"); eq(res.result, nil)

	c.transport = fake(200, '{"jsonrpc":"2.0","result":7,"error":null,"id":1}')
	res = c:rpc("m", { 1 }, 1)
	eq(res.result, 7)

	c.transport = fake(200, '{"jsonrpc":"2.0","result":null,"error":{"code":-32601,"message":"nope"},"id":1}')
	res = c:rpc("m", { 1 }, 1)
	eq(res.error.code, -32601); eq(res.result, json.null)

	c.transport = fake(200, '{"jsonrpc":"2.0","result":false,"id":3}')
	res = c:rpc("m", { 1 }, 3)
	eq(res.result, false)
end)

test("proxy sends nil as null", function()
	local last = {}
	local function t(r)
		local buf = {}
		if r.source then
			while true do local ch = r.source(); if not ch then break end; buf[#buf + 1] = ch end
		end
		last.body = table.concat(buf)
		local req = json.decode(last.body)
		local result = req.params
		if result == nil then result = false end
		r.sink(json.encode({ jsonrpc = "2.0", result = result, id = req.id }))
		r.sink(nil)
		return 1, 200, {}
	end
	local c = jr.new({ url = "http://h", transport = t })
	local res = c.proxy.sum(nil, 5)
	eq(res.result[1], json.null); eq(res.result[2], 5)
	assert(last.body:find("%[null,5%]") or last.body:find("%[null, 5%]"), last.body)
end)

test("response_table is a result object", function()
	local c = jr.new("http://h")
	local before = c.next_id
	local t = c:response_table(19, 1)
	eq(t.jsonrpc, "2.0"); eq(t.result, 19); eq(t.id, 1); eq(t.error, nil); eq(c.next_id, before)
	eq(c:response_table(false, 0).result, false)
	eq(c:response_table(nil, nil).result, json.null)
	eq(c:response_table(nil, nil).id, json.null)
	local raw = c:response_string({ ok = true }, "9")
	local dec = json.decode(raw)
	eq(dec.result.ok, true); eq(dec.id, "9"); eq(dec.error, nil)
	local r, e = c:response_table(1, 1.5); eq(r, nil); assert(tostring(e):find("integer"), e)
	c.root = { trace = "abc" }
	eq(c:response_table(1, 1).trace, "abc")
	c.root.result = 5
	r, e = c:response_table(1, 1); eq(r, nil); assert(tostring(e):find("result"), e)
end)

test("error_table is an error response", function()
	local c = jr.new("http://h")
	local t = c:error_table(-32601, "Method not found", "1", { name = "nope" })
	eq(t.jsonrpc, "2.0"); eq(t.result, nil); eq(t.id, "1")
	eq(t.error.code, -32601); eq(t.error.message, "Method not found"); eq(t.error.data.name, "nope")
	local bare = c:error_table(-32700, "Parse error", nil)
	eq(bare.error.data, nil); eq(bare.id, json.null)
	local raw = c:error_string(-32600, "Invalid Request", 3)
	local dec = json.decode(raw)
	eq(dec.error.code, -32600); eq(dec.id, 3); eq(dec.result, nil); eq(dec.error.data, nil)
	local r, e = c:error_table(1.5, "x", 1); eq(r, nil); assert(tostring(e):find("code"), e)
	r, e = c:error_table(-32603, nil, 1); eq(r, nil); assert(tostring(e):find("message"), e)
	r, e = c:error_table(-32603, "x", false); eq(r, nil); assert(tostring(e):find("id"), e)
end)

test("response and error are builders", function()
	local c = jr.new("http://h")
	eq(c.response, nil); eq(c.error, nil)
	local raw = c:error_string(-32601, "no", 1)
	assert(not raw:find('"data"', 1, true), raw)
	local with_null = json.decode(c:error_string(-1, "m", 1, json.null))
	eq(with_null.error.data, json.null)
	c.root = { trace = "t", error = { code = 1, message = "x" } }
	local res, err = c:error_table(-32601, "nope", 5)
	eq(res, nil); assert(tostring(err):find("error"), err)

	local peer = jr.new("http://h")
	local payload = peer:response_string({ n = 2 }, 7)
	local epayload = peer:error_string(-32601, "Method not found", "abc")
	local srv = jr.new({
		url = "http://h",
		transport = function(r)
			local body = r.url:find("err", 1, true) and epayload or payload
			if r.sink then r.sink(body); r.sink(nil) end
			return 1, 200, {}
		end,
	})
	local body, code = srv:request("echo", { 1 }, 7)
	eq(code, 200); eq(body.result.n, 2); eq(body.id, 7)
	body, code = srv:request("echo", {}, "abc", nil, "err")
	eq(code, 200); eq(body.error.code, -32601); eq(body.result, nil); eq(body.error.data, nil)
end)

test("no globals leaked", function()
	for _, k in ipairs({ "mm", "verbose", "encode", "decode", "random_string", "json" }) do eq(rawget(_G, k), nil, k) end
end)

print(string.format("%s (%s): %d passed, %d failed", _VERSION, jit and jit.version or "PUC", pass, fail))
os.exit(fail == 0 and 0 or 1)
