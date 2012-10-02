local ffi = require( "ffi" )
local dump = require( "etc/dump" ).dumpstring
local expat = require( "ffi/expat" )
local files = require( "etc/winapi-files" )
local outdir = "../ffi/winapi/"

if ffi.os == "Windows" then
   xmldir = (os.getenv("ProgramW6432") or os.getenv("ProgramFiles")).."/rohitab.com/API Monitor/API/"
else
   xmldir = "/Users/malkia/Downloads/API Monitor (rohitab.com)/API/"
end

local function fixpath(name)
   local fixed, pb = {}
   for i = 1, #name do
      local b = name:byte(i)
      if b == 92 then -- \
	 b = 47 -- /
      end
      if b >= 65 and b <= 90 then -- >=A && <= Z
	 b = b + 32 -- A->a
      end
      if b ~= pb or pb ~= 47 then
	 fixed[#fixed+1] = string.char(b)
      end
      pb = b
   end
   return table.concat(fixed)
end

local function filter_const(id)
   if id:sub(1,6)=="const " then
      return id:sub(7)
   end
   return id
end

local function filter_brackets(id, prefix, suffix)
   id = id:gsub("-","_")
   if id:sub(1,1)=="[" and id:sub(-1)=="]" then
      return (prefix or "") .. id:sub(2,-2) .. (suffix or "")
   end
   return id
end

local function fixname(id)
   return filter_brackets(filter_const(id),"WINAPI_")
end

local function normalize(t)
   for index = 1, #t do
      for k,v in pairs(t[index]) do
	 t[k] = t[k] or {}
	 local p = t[k]
	 p[#p+1] = normalize(v)
      end
      t[index] = nil
   end
   return t
end

local function parse(buffer, filename)
   local stack = {{}}
   local startElementHandler = ffi.cast(
      "XML_StartElementHandler",
      function(udata, name, attr)
	 local kv, index = {}, 0
	 while attr[index] ~= nil do
	    local key   = ffi.string(attr[index+0])
	    local value = ffi.string(attr[index+1])
	    index = index + 2
	    assert( kv[key] == nil )
	    kv[key] = (key == 'Filename') and fixpath(value) or fixname(value)
	 end
	 stack[#stack+1] = kv
      end)
   local endElementHandler = ffi.cast(
      "XML_EndElementHandler",
      function(udata, name)
	 local parent = stack[#stack-1]
	 parent[#parent+1] = { [ffi.string(name)] = stack[#stack] }
	 stack[#stack] = nil
      end)
   local parser = ffi.gc(expat.XML_ParserCreate(nil), expat.XML_ParserFree)
   expat.XML_SetElementHandler(parser, startElementHandler, endElementHandler)
   local status = expat.XML_Parse(parser, buffer, ffi.sizeof(buffer)-1, 1)
   startElementHandler:free()
   endElementHandler:free()
   if status == expat.XML_STATUS_ERROR then
      local ec = expat.XML_GetErrorCode(parser)
      local es = ffi.string(expat.XML_ErrorString(ec))
      local ln = expat.XML_GetCurrentLineNumber(parser)
      local cn = expat.XML_GetCurrentColumnNumber(parser)
      print(
	 '\nexpat error=' .. tonumber(ec) .. ' \"' .. es .. 
	    '\" in file: ' .. filename .. ':' .. ln .. ':' .. cn ..
	    '\n' ) --.. ffi.string(buffer)) 
      return nil
   end
   assert(stack[2]==nil and stack[1][2]==nil)
   return normalize(stack[1][1].ApiMonitor)
end

local stack = {}
for _, filename in ipairs( files ) do
   local file = assert(io.open(xmldir .. filename))
   local contents = file:read('*all')
   file:close()
   local buffer = ffi.new( "char[?]", contents:len()+1, contents )
   assert(stack[filename]==nil)
   filename = fixpath(filename)
   stack[filename] = parse(buffer, filename)
end


--print(os.execute("ls -la "..outdir))

local function dirname(filename)
   local p = 0
   for i=1, #filename do
      if filename:byte(i) == 47 then p = i end
   end
   return filename:sub(1, p)
end

local folders = {}


for header, library in pairs(stack) do
   local header_dir = dirname(header)
   if folders[header_dir] == nil then
      folders[header_dir] = true
      -- cygwin's mkdir
      print(os.execute( "e:/bin/mkdir -p " .. outdir .. header_dir ))
   end

   local luaname = header:gsub("%..*", "%.lua")
   print( luaname )
   local luafile = io.open(outdir..luaname, "wt")
   for _, depend in ipairs(library.Include or {}) do
      local requiredFilename = depend.Filename:gsub("%..*", "")
      luafile:write('require( \"ffi/winapi/' .. requiredFilename .. '\" )\n')
   end
   luafile:write('local ffi = require( \"ffi\" )\n')
   luafile:write('ffi.cdef ['..'[\n')
   for _, header in ipairs(library.Headers or {}) do
      for _, var in ipairs(header.Variable or {}) do
	 if var.Enum then
	    luafile:write('  typedef enum ' .. var.Name .. ' {\n');
	    for _, enum in ipairs( var.Enum[1].Set ) do
	       luafile:write('    ' .. enum.Name .. ' = ' .. enum.Value .. ',\n' )
	    end
	    luafile:write('  } ' .. var.Name .. ';\n');
	 elseif var.Type == 'Alias' then
	    luafile:write('  typedef '.. var.Base .. ' ' .. var.Name .. ';\n')
	 elseif var.Type == 'Pointer' then
	    if var.Base .. '*' ~= var.Name then
	       luafile:write('  typedef '.. var.Base .. ' ' .. var.Name .. ';\n')
	    end
	 elseif var.Type == 'Struct' then
	    luafile:write('  typedef struct ' .. var.Name .. ' {\n');
	    for _, enum in ipairs( var.Field ) do
	       local type = enum.Type or enum.TYPE
	       luafile:write('    ' .. type .. ' ' .. enum.Name .. ',\n' )
	    end
	    luafile:write('  } ' .. var.Name .. ';\n\n');
	 elseif var.Type == 'Union' then
	    luafile:write('  typedef union ' .. var.Name .. ' {\n');
	    for _, enum in ipairs( var.Field ) do
	       luafile:write('    ' .. tostring(enum.Type) .. ' ' .. enum.Name .. ',\n' )
	    end
	    luafile:write('  } ' .. var.Name .. ';\n\n');
	 end
--	 luafile:write(' /* ' .. dump(var) .. ' */\n')
      end
   end
   local dll
   for _, module in ipairs(library.Module or {}) do
      local modname = module.Name ~= "*" and module.Name or header
      local name = modname:gsub("%..*", "%.lua"):lower()
      local file = outdir .. name
      print( file, header )

      local return_type_width = 0
      local api_name_width = 0
      for _, api in ipairs(module.Api) do
	 local return_type = api.Return[1].Type
	 return_type_width = math.max( #return_type, return_type_width )
	 api_name_width = math.max( #api.Name, api_name_width )
      end

      for _, api in ipairs(module.Api) do
	 local return_type = api.Return[1].Type
	 luafile:write(
	    '  ' .. return_type .. string.rep(' ', return_type_width - #return_type + 1) .. 
	    api.Name .. '(' .. string.rep(' ', api_name_width - #api.Name + 1))
	 local comma = ''
	 for _, param in ipairs(api.Param or {}) do
	    luafile:write( comma .. param.Type .. ' ' .. param.Name )
	    comma = ', '
	 end
	 luafile:write( ');\n')
      end
      dll = module.Name
   end 
   luafile:write(']'..']\n')
   if dll then
      luafile:write('return ffi.load( \"' .. dll ..'\" )\n')
   end
   luafile:close()
end
