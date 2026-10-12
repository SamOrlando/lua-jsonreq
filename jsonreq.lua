--- jsonreq: JSON over HTTP(S) requests and JSON-RPC 2.0 client helpers.
-- Works on Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT.
local _M = {
	_VERSION     = 'json-request 0.1.0',
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

-- Transports are loaded lazily so plain-HTTP users do not need luasec.
local http_request, https_request, ltn12
local function get_transport(https)
	ltn12 = ltn12 or require("ltn12")
	if https then
		https_request = https_request or require("ssl.https").request
		return https_request
	end
	http_request = http_request or require("socket.http").request
	return http_request
end

local function is_https(url) return lower(url:sub(1, 8)) == "https://" end

local function copy(t, into)
	into = into or {}
	if t then for k, v in pairs(t) do into[k] = v end end
	return into
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
local function request_handler_http(self, payload, headers, resource, method)
	local url = (self.url or "") .. (resource or "")
	local transport = self.transport or get_transport(is_https(url))
	ltn12 = ltn12 or require("ltn12")
	local response_body = {}
	local rtbl = {
		url = url,
		method = method or "POST",
		headers = headers,
		source = (payload and payload ~= "") and ltn12.source.string(payload) or nil,
		sink = ltn12.sink.table(response_body),
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
		transport = opt.transport, -- optional function(rtbl) -> res, code, headers (luasocket style)
		next_id = 0,
	}
	local obj = setmetatable(tbl, _M.meta)
	-- obj.proxy.method(a, b) -> obj:rpc("method", {a, b})
	tbl.proxy = setmetatable({}, {
		__index = function(_, key)
			return function(...) return obj:rpc(key, { ... }) end
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
	local p = copy(params)
	copy(self.params, p)
	if id == nil then
		self.next_id = (self.next_id or 0) + 1
		id = self.next_id
	end
	local rpc_tbl = { jsonrpc = "2.0", method = method, id = id }
	if next(p) ~= nil then rpc_tbl.params = p end
	copy(self.root, rpc_tbl)
	return rpc_tbl
end

function mm:rpc_string(method, params, id)
	return safe_encode(self:rpc_table(method, params, id))
end

function mm:rpc(method, params, id, headers, resource)
	if not self.enabled then return nil, "disabled" end
	local payload, err = self:rpc_string(method, params, id)
	if not payload then return nil, err end
	local h = build_headers(self, headers, "application/json", #payload)
	return self.request_handler(self, payload, h, resource or "", "POST")
end

function mm:call(payload, headers, resource, method)
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
	return self.request_handler(self, payload, h, resource or "", method or "POST")
end

function mm:get(resource, headers) return self:call(nil, headers, resource, "GET") end
function mm:post(resource, payload, headers) return self:call(payload, headers, resource, "POST") end
function mm:put(resource, payload, headers) return self:call(payload, headers, resource, "PUT") end
function mm:patch(resource, payload, headers) return self:call(payload, headers, resource, "PATCH") end
function mm:update(resource, payload, headers) return self:call(payload, headers, resource, "UPDATE") end -- legacy, non-standard verb
function mm:delete(resource, headers) return self:call(nil, headers, resource, "DELETE") end

return _M
