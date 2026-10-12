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
	eq(last.req.headers["content-length"], tostring(#last.body))
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
	local t, last = fake(200, '{"result":"pong"}')
	local c = jr.new({ url = "http://h", transport = t })
	eq(c.proxy.ping(1).result, "pong"); eq(json.decode(last.body).method, "ping")
	eq(c:proxy().echo().result, "pong"); eq(json.decode(last.body).method, "echo")
end)

test("REST verbs and resource", function()
	local t, last = fake(200, '[1,2]')
	local c = jr.new({ url = "http://h", transport = t })
	for _, v in ipairs({ "get", "delete" }) do
		local r = c[v](c, "/r"); eq(r[2], 2); eq(last.req.method, v:upper()); eq(last.req.url, "http://h/r")
	end
	for _, v in ipairs({ "post", "put", "patch", "update" }) do
		local p = { x = 1 }
		c[v](c, "/r", p); eq(last.req.method, v == "update" and "PATCH" or v:upper()); eq(json.decode(last.body).x, 1)
	end
end)

test("call does not mutate payload; per-call header overrides", function()
	local t, last = fake(200, '{}')
	local c = jr.new({ url = "http://h", transport = t, root = { r = 1 }, headers = { A = "inst" } })
	local p = { x = 1 }
	local h = { A = "call", ["Content-Type"] = "text/plain" }
	c:post("", p, h)
	eq(p.r, nil); eq(h["content-length"], nil)
	eq(last.req.headers.A, "call"); eq(last.req.headers["content-type"], nil)
	eq(last.req.headers["Content-Type"], "text/plain")
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
	c:get("/"); eq(last.req.timeout, 30); eq(jr.TIMEOUT, 30)
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
			eq(r, nil); assert(e); assert(dt < 2, "took " .. dt)
			eq(require("ssl.https").TIMEOUT, 60, "module TIMEOUT restored")
		end)
	end
	test("real connection refused returned", function()
		local srv = assert(socket.bind("127.0.0.1", 0)); local _, port = srv:getsockname(); srv:close()
		local r, e = jr.new({ url = "http://127.0.0.1:" .. port, timeout = 1 }):get("/")
		eq(r, nil); assert(e)
	end)
end

test("no globals leaked", function()
	for _, k in ipairs({ "mm", "verbose", "encode", "decode", "random_string", "json" }) do eq(rawget(_G, k), nil, k) end
end)

print(string.format("%s (%s): %d passed, %d failed", _VERSION, jit and jit.version or "PUC", pass, fail))
os.exit(fail == 0 and 0 or 1)
