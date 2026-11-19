--- jsonreq: JSON over HTTP(S) requests and JSON-RPC 2.0 client helpers.
-- Works on Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.
local _M = {
	_VERSION     = 'json-request 0.1.1',
	_DESCRIPTION = 'JSON-Request (jsonreq) : handles general JSON HTTP/anything request with headers and JSONRPC functions.',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2024 - MIT Cheese Please',
}

local type, pairs, next, tostring, pcall, require, setmetatable, rawget, print =
	type, pairs, next, tostring, pcall, require, setmetatable, rawget, print
local lower, concat = string.lower, table.concat

-- JSON backend: lua-cjson preferred, dkjson fallback. Replaceable via _M.json.
local function load_json()
	local ok, lib = pcall(require, "cjson")
	if ok then return lib end
	ok, lib = pcall(require, "dkjson")
	if ok then return lib end
	error("jsonreq: no JSON library found (install lua-cjson or dkjson)", 3)
end
_M.json = load_json()

_M.verbose = false -- when true, prints method/url and payload (may expose secrets)

local function is_https(url) return lower(url:sub(1, 8)) == "https://" end

_M.TIMEOUT = 30 -- default request timeout in seconds (client opt.timeout / per-call override)

-- Transports are loaded lazily so plain-HTTP users do not need luasec.
local http_mod, https_mod, ltn12
local function get_module(https)
	if https then
		https_mod = https_mod or require("ssl.https")
		return https_mod
	end
	http_mod = http_mod or require("socket.http")
	return http_mod
end

-- Default transport: luasocket/luasec request with rtbl.timeout applied.
-- Both modules read their TIMEOUT field per connection (luasec forbids a
-- custom 'create'), so it is set for the duration of this blocking call.
local function default_transport(rtbl)
	local mod = get_module(is_https(rtbl.url))
	local old = mod.TIMEOUT
	mod.TIMEOUT = rtbl.timeout or _M.TIMEOUT
	local ok, res, code, h = pcall(mod.request, rtbl)
	mod.TIMEOUT = old
	if not ok then return nil, tostring(res) end
	-- luasec reports TLS-level timeouts as "wantread"/"wantwrite"
	if not res and (code == "wantread" or code == "wantwrite") then code = "timeout" end
	return res, code, h
end
_M.default_transport = default_transport


local function copy(t, into)
	into = into or {}
	if t then for k, v in pairs(t) do into[k] = v end end
	return into
end

-- Pass as the id argument, or call :notify, to omit id. A request with no id is a notification.
local NOTIFY = {}
_M.notification = NOTIFY

local reserved_member = { jsonrpc = true, method = true, params = true, id = true }

local function is_integer(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n % 1 == 0
end

local function is_json_null(v)
	local n = _M.json.null
	return n ~= nil and v == n
end

local function has_array_mt(t)
	if type(t) ~= "table" then return false end
	local mt = getmetatable(t)
	if mt == nil then return false end
	local j = _M.json
	if j.empty_array_mt ~= nil and mt == j.empty_array_mt then return true end
	if j.array_mt ~= nil and mt == j.array_mt then return true end
	return false
end

-- "array", "sparse", "object", "empty", or "bad" (mixed or non-JSON keys).
local function classify(t)
	local maxk, count, has_string = 0, 0, false
	for k in pairs(t) do
		count = count + 1
		if type(k) == "number" and k >= 1 and is_integer(k) then
			if k > maxk then maxk = k end
		elseif type(k) == "string" then
			has_string = true
		else
			return "bad"
		end
	end
	if has_string and maxk > 0 then return "bad" end
	if count == 0 then
		if has_array_mt(t) then return "array" end
		return "empty"
	end
	if has_string then return "object" end
	if maxk ~= count then return "sparse" end
	return "array"
end

local function copy_params(t)
	local out = copy(t)
	if has_array_mt(t) then setmetatable(out, getmetatable(t)) end
	return out
end

-- Returns the params value (nil means omit the member) and an error string.
-- Named client params merge only into an object. An empty Lua table is omitted,
-- because Lua cannot tell {} from []. Pass json.empty_array to send [].
local function build_params(user_params, injected)
	if injected ~= nil and type(injected) ~= "table" then
		return nil, "jsonreq: client params must be a table"
	end
	injected = injected or {}
	local empty_array = _M.json.empty_array
	if user_params == nil then
		user_params = {}
	elseif empty_array ~= nil and user_params == empty_array then
		if next(injected) ~= nil then
			return nil, "jsonreq: cannot inject named params into positional params"
		end
		return empty_array
	elseif type(user_params) ~= "table" then
		return nil, "jsonreq: params must be an array or an object"
	end

	local kind = classify(user_params)
	if kind == "bad" then
		return nil, "jsonreq: params must be an array or an object"
	end
	if kind == "array" or kind == "sparse" then
		if next(injected) ~= nil then
			return nil, "jsonreq: cannot inject named params into positional params"
		end
		return copy_params(user_params)
	end

	local out = copy_params(user_params)
	copy(injected, out)
	kind = classify(out)
	if kind == "bad" then
		return nil, "jsonreq: params must be an array or an object"
	end
	if kind == "empty" then return nil end
	return out
end

-- Returns sent_id, omit_id, err. omit_id is true for a notification.
local function resolve_id(self, id)
	if id == nil then
		self.next_id = (self.next_id or 0) + 1
		return self.next_id, false
	end
	if id == false or id == NOTIFY then return nil, true end
	if is_json_null(id) or type(id) == "string" or is_integer(id) then
		return id, false
	end
	if type(id) == "number" then
		return nil, false, "jsonreq: id number must be an integer"
	end
	return nil, false, "jsonreq: id must be a string, integer, or null"
end

local function ids_equal(a, b)
	if is_json_null(a) or is_json_null(b) then
		return is_json_null(a) and is_json_null(b)
	end
	return type(a) == type(b) and a == b
end

local function response_is_array(t)
	if type(t) ~= "table" or #t == 0 then return false end
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
	end
	return true
end

-- Error string, or nil. A JSON null placeholder for the unused result or error
-- member is one outcome. A real result next to a real error is not.
local function validate_response(resp, sent_id)
	if type(resp) ~= "table" or response_is_array(resp) then
		return "jsonreq: response must be an object"
	end
	if resp.jsonrpc ~= "2.0" then
		return "jsonreq: response jsonrpc must be \"2.0\""
	end
	if resp.id == nil then
		return "jsonreq: response missing id"
	end
	if not ids_equal(resp.id, sent_id) then
		return "jsonreq: response id does not match request"
	end
	local result_set = resp.result ~= nil and not is_json_null(resp.result)
	local error_set = type(resp.error) == "table"
	if error_set and result_set then
		return "jsonreq: response contains both result and error"
	end
	if error_set then
		if not is_integer(resp.error.code) then
			return "jsonreq: error.code must be an integer"
		end
		if type(resp.error.message) ~= "string" then
			return "jsonreq: error.message must be a string"
		end
		return nil
	end
	if resp.result == nil then
		return "jsonreq: response missing result"
	end
end

local function pack_proxy_args(proxy, ...)
	local n = select("#", ...)
	local start_at = 1
	if n > 0 and select(1, ...) == proxy then start_at = 2 end
	local null = _M.json.null
	local out = {}
	for i = start_at, n do
		local v = select(i, ...)
		if v == nil then v = null end
		out[i - start_at + 1] = v
	end
	return out
end

local function safe_decode(s)
	if s == nil or s == "" then return nil end
	local json = _M.json
	local ok, res, _, err = pcall(json.decode, s)
	if not ok then return nil, "json decode error: " .. tostring(res) end
	if res == nil and err then return nil, "json decode error: " .. tostring(err) end -- dkjson style
	return res
end

local function safe_encode(v)
	local ok, res = pcall(_M.json.encode, v)
	if not ok then return nil, "json encode error: " .. tostring(res) end
	return res
end

_M.meta = { methods = {} }
local mm = _M.meta.methods
_M.meta.__index = mm

--- Default HTTP request handler.
-- Returns: decoded_body, status_code, response_headers, raw_body
-- On transport failure: nil, error_message
-- On non-JSON body: nil, status_code, response_headers, raw_body, decode_error
local function request_handler_http(self, payload, headers, resource, method, timeout)
	local url = (self.url or "") .. (resource or "")
	local transport = self.transport or default_transport
	ltn12 = ltn12 or require("ltn12")
	local response_body = {}
	local rtbl = {
		url = url,
		method = method or "POST",
		headers = headers,
		source = (payload and payload ~= "") and ltn12.source.string(payload) or nil,
		sink = ltn12.sink.table(response_body),
		timeout = timeout or self.timeout or _M.TIMEOUT,
	}
	if _M.verbose then
		print(rtbl.method .. " -> " .. url)
		if payload then print(payload) end
	end

	local res, code, rheaders = transport(rtbl)
	if not res then return nil, tostring(code) end

	local raw = concat(response_body)
	local body, err = safe_decode(raw)
	if err then return nil, code, rheaders, raw, err end
	return body, code, rheaders, raw
end
_M.request_handler_http = request_handler_http

_M.new = function(opt)
	opt = opt or {}
	if type(opt) == "string" then opt = { url = opt } end

	local tbl = {
		enabled = opt.enabled ~= false,
		params = copy(opt.params), -- injected params (for jsonrpc)
		root = copy(opt.root),     -- injected root table items
		url = opt.url,             -- base url/uri
		headers = copy(opt.headers), -- injected headers on calls (for auth, etc)
		request_handler = opt.request_handler or request_handler_http,
		timeout = opt.timeout,     -- seconds; nil -> jsonreq.TIMEOUT (30)
		transport = opt.transport, -- optional function(rtbl) -> res, code, headers (luasocket style)
		next_id = 0,
	}
	local obj = setmetatable(tbl, _M.meta)
	-- obj.proxy.method(a, b) -> obj:rpc("method", {a, b})
	-- A nil argument is sent as JSON null. Colon calls drop the proxy receiver.
	tbl.proxy = setmetatable({}, {
		__index = function(proxy, key)
			return function(...) return obj:rpc(key, pack_proxy_args(proxy, ...)) end
		end,
		-- backward compat: obj:proxy() returns the proxy table
		__call = function(self) return self end,
	})
	return obj
end

-- Build per-call headers: instance defaults < per-call headers; content-type
-- only set if the caller did not provide one (case-insensitive).
local function build_headers(self, headers, ctype, len)
	local h = copy(self.headers)
	if type(headers) == "table" then copy(headers, h) end
	local has_ct = false
	for k in pairs(h) do
		local lk = type(k) == "string" and lower(k)
		if lk == "content-length" then h[k] = nil
		elseif lk == "content-type" then has_ct = true end
	end
	if not has_ct then h["content-type"] = ctype end
	h["content-length"] = tostring(len)
	return h
end

function mm:rpc_table(method, params, id)
	if type(method) ~= "string" then
		return nil, "jsonreq: method must be a string"
	end
	local params_value, perr = build_params(params, self.params)
	if perr then return nil, perr end
	if self.root ~= nil and type(self.root) ~= "table" then
		return nil, "jsonreq: root must be a table"
	end
	if self.root then
		for k in pairs(self.root) do
			if reserved_member[k] then
				return nil, "jsonreq: root cannot override '" .. tostring(k) .. "'"
			end
		end
	end
	local sent_id, omit, ierr = resolve_id(self, id)
	if ierr then return nil, ierr end

	local rpc_tbl = { jsonrpc = "2.0", method = method }
	if params_value ~= nil then rpc_tbl.params = params_value end
	if not omit then rpc_tbl.id = sent_id end
	if self.root then
		for k, v in pairs(self.root) do rpc_tbl[k] = v end
	end
	return rpc_tbl
end

function mm:rpc_string(method, params, id)
	local rpc_tbl, err = self:rpc_table(method, params, id)
	if not rpc_tbl then return nil, err end
	return safe_encode(rpc_tbl)
end

function mm:rpc(method, params, id, headers, resource, timeout)
	if not self.enabled then return nil, "disabled" end
	local rpc_tbl, err = self:rpc_table(method, params, id)
	if not rpc_tbl then return nil, err end
	local payload, eerr = safe_encode(rpc_tbl)
	if not payload then return nil, eerr end
	local h = build_headers(self, headers, "application/json", #payload)
	local body, code, rheaders, raw, derr = self.request_handler(
		self, payload, h, resource or "", "POST", timeout)
	-- Transport failure keeps nil, message. A notification does not require a body.
	if type(code) ~= "number" or derr then
		return body, code, rheaders, raw, derr
	end
	if rpc_tbl.id == nil then
		return body, code, rheaders, raw
	end
	if body == nil then
		return nil, code, rheaders, raw, "jsonreq: empty response"
	end
	local verr = validate_response(body, rpc_tbl.id)
	if verr then return nil, code, rheaders, raw, verr end
	return body, code, rheaders, raw
end

function mm:notify(method, params, headers, resource, timeout)
	return self:rpc(method, params, NOTIFY, headers, resource, timeout)
end

function mm:call(payload, headers, resource, method, timeout)
	if not self.enabled then return nil, "disabled" end
	if type(payload) == "table" then
		payload = copy(self.root, copy(payload))
	end
	if payload ~= nil and type(payload) ~= "string" then
		local err
		payload, err = safe_encode(payload)
		if not payload then return nil, err end
	end
	payload = payload or ""
	local h = build_headers(self, headers, "application/json", #payload)
	return self.request_handler(self, payload, h, resource or "", method or "POST", timeout)
end

function mm:get(resource, headers, timeout) return self:call(nil, headers, resource, "GET", timeout) end
function mm:post(resource, payload, headers, timeout) return self:call(payload, headers, resource, "POST", timeout) end
function mm:put(resource, payload, headers, timeout) return self:call(payload, headers, resource, "PUT", timeout) end
function mm:patch(resource, payload, headers, timeout) return self:call(payload, headers, resource, "PATCH", timeout) end
mm.update = mm.patch -- legacy name; UPDATE is not an HTTP method, sends PATCH (RFC 5789)
function mm:delete(resource, headers, timeout) return self:call(nil, headers, resource, "DELETE", timeout) end

return _M
