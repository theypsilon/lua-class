local error, getmetatable, io, pairs, rawget, rawset, setmetatable, tostring, type =
    _G.error, _G.getmetatable, _G.io, _G.pairs, _G.rawget, _G.rawset, _G.setmetatable, _G.tostring, _G.type

-- class library table

local class = {}

-- metatable for declaring classes

setmetatable(class, { __call = function(f, ...)
    local params = class.split_params({...})
    return class.new(params.mixin, params.string and params.string[1] or nil)
end})

-- private functions

local function call_or_index(t, f, key)
    if type(f) == 'function' then return f(t, key) else return rawget(t, key) end
end

local function accumulate_index(klass, old_index)
    local new_index = klass.__index
    function klass.__index(t, key)
        return call_or_index(t, new_index, key) or call_or_index(t, old_index, key)
    end
end

local function inherit(klass, base)
    local init  = klass._init
    local index = klass.__index

    for k,v in pairs(base) do klass[k] = v end

    if base.__index and base.__index == base then 
        klass.__index = index
    elseif base.__index ~= base and index ~= base.__index then 
        accumulate_index(klass, index) 
    end

    if init and base._init and init  ~= base._init   then
        function klass._init() 
            error('this class needs to define the _init method,'
                ..' cause his multiple bases define the same')
        end
    end
end

local function is_a_helper(class1, class2)
    if not class1 then return false end
    if class1 == class2 then return true end
    local bases = rawget(class1,'_base')
    for _,b in ipairs(bases) do
        if is_a_helper(b, class2) then return true end
    end

    return false
end

local function new_finalizable(klass)
    if not class.is_class(klass) then error 'bad class' end

    local udata = newproxy(true)
    local umeta = getmetatable(udata)
    setmetatable(umeta, klass)
    umeta.__index    = umeta
    umeta.__newindex = umeta
    umeta.__gc       = function(self) klass.__gc(self) end
    umeta.__userdata = udata
    return udata
end

local function metacall(klass)
    return function(t, ...)
        local dtor = rawget(klass, '__gc')
        local obj = dtor and new_finalizable(klass) or setmetatable({}, klass)

        local ctor = rawget(klass, '_init')
        if ctor then 
            local res = ctor(obj,...)
            if res then 
                obj = res
                if class.get_class(obj) ~= klass then setmetatable(obj, klass) end
            end
        end

        if not rawget(klass, '__tostring') then
            klass.__tostring = class.tostring
        end
        return obj
    end
end

local function apply_bases(klass, base)
    if class.is_mixin(base) then base = {base} end

    for _,b in ipairs(base) do
        if not class.is_mixin(b) then
            error("must derive from a class/mixin",3)
        end        
        inherit(klass, b)
    end

    return base
end

local function local_name_of(t, level)
    local idx = 1

    while true do
        local ln, lv = debug.getlocal(level, idx)
        if lv == t then return ln  end
        if not ln  then return "nil" end
        idx = 1 + idx
    end
    return "wtf"
end

local function metanewindex(t, k, v)
    getmetatable(t).__newindex  = nil
    if not rawget(t, '_name') then rawset(t, '_name', local_name_of(t, 3) or '<none>') end
    t[k] = v
end

local function get_metaindex(klass)
    local index = rawget(klass, '__index')
    if index then
        return function(t, key)
            if not rawget(t, '_name') then rawset(t, '_name', local_name_of(t, 3) or '<none>') end
            return rawget(t, key) or index(t, key) 
        end
    else
        return klass
    end
end

-- class public methods

function class.new(base, name)
    local klass     = {}
    local metaklass = {__call = metacall(klass)}
    setmetatable(klass, metaklass)

    if base then klass._base = apply_bases(klass, base) end

    klass.__index = get_metaindex(klass)
    klass.is_a    = class.is_a
    klass._name   = name

    if not name then metaklass.__newindex = metanewindex end

    return klass
end

function class.is_a(obj, klass)
    return is_a_helper(class.get_class(obj), klass)
end

function class.get_class(obj)
    local meta = getmetatable(obj)
    if type(meta.__userdata) == 'userdata' then meta = getmetatable(meta) end
    if class.is_class(meta) then return meta end
    return nil
end

function class.tostring(obj)
    local mt = getmetatable(obj)
    local name = rawget(mt,'_name')
    setmetatable(obj,nil)
    local str = tostring(obj)
    setmetatable(obj,mt)
    if name then str = name ..str:gsub('table','') end
    return str
end

function class.is_mixin(mixin)
    if type(mixin) ~= 'table' then return false end
    local any = false

    for k,_ in pairs(mixin) do
        if type(k) ~= 'string' then return false end
        any = true
    end
    return any
end

function class.is_class(c)
    return class.is_mixin(c) and c.__index and getmetatable(c)
        and (c.new or getmetatable(c).__call)
end

function class.make_finalizable(obj, finfunc)
    if type(obj) ~= 'table' then error 'this object cannot be finalizable' end
    local klass = getmetatable   (obj)
    local udata = new_finalizable(klass)
    local umeta = getmetatable   (udata)

    if finfunc then umeta.__gc = finfunc end

    for k, v in pairs(obj) do
        umeta[k] = v
        obj  [k] = nil
    end

    setmetatable(obj, umeta)
end

function class.split_params(param)
    local result = {}
    if class.is_mixin(param) then
        result.mixin  = {param}
    elseif type(param) == 'table' then
        for _,subparam in ipairs(param) do
            for k, subresult in pairs(class.split_params(subparam)) do
                if not result[k] then result[k] = subresult
                else for _, v in ipairs(subresult) do
                    table.insert(result[k], v) 
                end end
            end
        end
    else
        result[type(param)] = {param}
    end
    return result
end

-- property mixin

local prop_history = {}
local function property_access(suffix, safefunc)
    return function(self, key, value)
        local klass = class.get_class(self)
        local f     = klass[suffix..key]
        if f and not prop_history[f] then
            prop_history[f] = true
            local result = f(self, value)
            prop_history[f] = nil
            return result
        else
            local  result = safefunc(self, '__'..key, value)
            return result and result or klass[key]
        end
    end
end

class.properties = {}
class.properties.__index    = property_access('get_', rawget)
class.properties.__newindex = property_access('set_', rawset)

-- gc class (WARNING: Lua's GC is non-deterministic)

class.gc = class('gc')
function class.gc:_init(callback) self.callback = callback end
function class.gc:__gc (        ) self.callback()          end


local exports = {
    class      = class,
    properties = class.properties,
    gc         = class.gc,
}

return exports