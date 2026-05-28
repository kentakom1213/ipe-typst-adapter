----------------------------------------------------------------------
-- Typst ipelet
----------------------------------------------------------------------

label = "Typst"

about = [[
Insert and edit Typst-rendered labels as regeneratable Ipe groups.
]]

local CUSTOM_KEY = "ipe-typst"
local KIND = "ipe-typst-label"
local VERSION = 1
local os = _G.os
local io = _G.io
local math = _G.math
local string = _G.string
local table = _G.table
local ipairs = _G.ipairs
local pcall = _G.pcall
local tonumber = _G.tonumber
local tostring = _G.tostring
local type = _G.type

local function warn(model, text, details)
  local ok = pcall(function () model:warning(text, details) end)
  if not ok then
    ipeui.messageBox(model.ui:win(), "warning", text, details, "ok")
  end
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

local function remove_tree(path)
  os.execute("rm -rf " .. shell_quote(path))
end

----------------------------------------------------------------------
-- Renderer layer
----------------------------------------------------------------------

function make_temp_dir()
  local base = os.getenv("TMPDIR") or "/tmp"
  for _ = 1, 20 do
    local name = string.format("%s/ipe-typst-%d-%06d",
      base, os.time(), math.random(0, 999999))
    local ok = os.execute("mkdir " .. shell_quote(name))
    if ok == true or ok == 0 then return name end
  end
  return nil, "Could not create a temporary directory."
end

function run_command(cmd)
  local dir, err = make_temp_dir()
  if not dir then return false, "", err or "" end
  local stdout_path = dir .. "/stdout.txt"
  local stderr_path = dir .. "/stderr.txt"
  local full = cmd .. " > " .. shell_quote(stdout_path) ..
    " 2> " .. shell_quote(stderr_path)
  local ok, reason, code = os.execute(full)
  local stdout = read_file(stdout_path) or ""
  local stderr = read_file(stderr_path) or ""
  remove_tree(dir)
  if ok == true or ok == 0 then
    return true, stdout, stderr
  end
  if type(ok) == "number" then code = ok end
  return false, stdout, stderr, reason, code
end

local function command_exists(name)
  local ok = run_command("command -v " .. shell_quote(name))
  return ok
end

local function ensure_external_commands()
  if not command_exists("typst") then
    return nil, "`typst` was not found in PATH.",
      "Please install Typst and make sure `typst` is executable from Ipe."
  end
  if not command_exists("svgtoipe") then
    return nil, "`svgtoipe` was not found in PATH.",
      "Please install svgtoipe and make sure `svgtoipe` is executable from Ipe."
  end
  return true
end

function make_typst_document(source, options)
  options = options or {}
  local width = options.page_width or "auto"
  local height = options.page_height or "auto"
  local text_size = options.text_size or "10pt"
  local fill = options.fill or "none"
  return string.format([[
#set page(width: %s, height: %s, margin: 0pt, fill: %s)
#set text(size: %s)

%s
]], width, height, fill, text_size, source)
end

function render_typst_to_ipe(source, options)
  local ok, text, details = ensure_external_commands()
  if not ok then return nil, text, details end

  local dir, err = make_temp_dir()
  if not dir then return nil, "Could not create temporary files.", err end

  local typ_path = dir .. "/label.typ"
  local svg_path = dir .. "/label.svg"
  local ipe_path = dir .. "/label.ipe"
  local doc = make_typst_document(source, options)

  local wrote, write_err = write_file(typ_path, doc)
  if not wrote then
    remove_tree(dir)
    return nil, "Could not write Typst source.", write_err
  end

  local cmd = "typst compile " .. shell_quote(typ_path) .. " " .. shell_quote(svg_path)
  ok, _, err = run_command(cmd)
  if not ok then
    local details_text = (err or "")
    if details_text ~= "" then details_text = details_text .. "\n\n" end
    details_text = details_text .. "Temporary directory: " .. dir
    return nil, "Typst compilation failed.", details_text
  end

  cmd = "svgtoipe " .. shell_quote(svg_path) .. " " .. shell_quote(ipe_path)
  ok, _, err = run_command(cmd)
  if not ok then
    local details_text = (err or "")
    if details_text ~= "" then details_text = details_text .. "\n\n" end
    details_text = details_text .. "Temporary directory: " .. dir
    return nil, "svgtoipe conversion failed.", details_text
  end

  local imported, load_err = ipe.Document(ipe_path)
  remove_tree(dir)
  if not imported then
    return nil, "Could not load generated Ipe file.", load_err
  end
  if #imported < 1 then
    return nil, "Generated Ipe file has no pages.", nil
  end

  local elements = {}
  for _, obj in imported[1]:objects() do
    elements[#elements + 1] = obj
  end
  if #elements == 0 then
    return nil, "Generated Ipe file has no objects.", nil
  end

  return ipe.Group(elements)
end

----------------------------------------------------------------------
-- Object layer
----------------------------------------------------------------------

local function encode_metadata(meta)
  local source = meta.source or ""
  return table.concat({
    CUSTOM_KEY,
    "kind=" .. KIND,
    "version=" .. tostring(VERSION),
    "source-length=" .. tostring(#source),
    source,
  }, "\n")
end

function attach_typst_metadata(obj, meta)
  obj:setCustom(encode_metadata(meta))
  return obj
end

function read_typst_metadata(obj)
  local custom = obj:getCustom()
  if not custom or custom == "" then return nil end
  local header, rest = custom:match("^([^\n]*)\n(.*)$")
  if header ~= CUSTOM_KEY then return nil end

  local kind = rest:match("kind=([^\n]*)")
  local version = tonumber(rest:match("version=([^\n]*)"))
  local source_len = tonumber(rest:match("source%-length=(%d+)"))
  local source = rest:match("source%-length=%d+\n(.*)$")
  if source_len and source then source = source:sub(1, source_len) end
  if kind ~= KIND or not source then return nil end
  return { kind = kind, version = version or VERSION, source = source }
end

function get_selected_typst_object(model)
  local p = model:page()
  local selection = model:selection()
  if not selection or #selection == 0 then
    return nil, "No Typst label selected.", "Select one Typst label first."
  end
  if #selection ~= 1 then
    return nil, "Please select exactly one Typst label.", nil
  end

  local index = selection[1]
  local obj = p[index]
  local meta = read_typst_metadata(obj)
  if not meta or meta.kind ~= KIND then
    return nil, "Selected object is not a Typst label.",
      "Typst labels are stored as group objects with ipe-typst custom data."
  end
  return index, obj, meta
end

function replace_object_preserving_transform(model, old_index, old_obj, new_obj)
  new_obj:setMatrix(old_obj:matrix())
  local p = model:page()
  local layer = p:layerOf(old_index)

  local t = {
    label = "replace Typst label",
    pno = model.pno,
    vno = model.vno,
    original = p:clone(),
    final = p:clone(),
    undo = _G.revertOriginal,
    redo = _G.revertFinal,
  }
  t.final:replace(old_index, new_obj)
  t.final:setLayerOf(old_index, layer)
  t.final:deselectAll()
  t.final:setSelect(old_index, 2)
  model:register(t)
end

----------------------------------------------------------------------
-- UI layer
----------------------------------------------------------------------

local function typst_source_dialog(model, title, initial)
  local d = ipeui.Dialog(model.ui:win(), title)
  d:add("source", "text", { syntax = "latex" }, 1, 1)
  d:set("source", initial or "$ G = (V, E) $")
  d:addButton("ok", "&Ok", "accept")
  d:addButton("cancel", "&Cancel", "reject")
  d:setStretch("row", 1, 1)
  d:setStretch("column", 1, 1)
  if not d:execute({ 560, 320 }) then return nil end
  local source = d:get("source")
  if not source or source:match("^%s*$") then return nil end
  return source
end

function insert_typst_label(model)
  local source = typst_source_dialog(model, "Insert Typst Label", "$ G = (V, E) $")
  if not source then return end

  local obj, err, details = render_typst_to_ipe(source, {})
  if not obj then
    warn(model, err, details)
    return
  end
  attach_typst_metadata(obj, { source = source })

  local pos = ipe.Vector(0, 0)
  local ok, ui_pos = pcall(function () return model.ui:pos() end)
  if ok and ui_pos then pos = ui_pos end
  obj:setMatrix(ipe.Translation(pos))
  model:creation("create Typst label", obj)
end

function edit_typst_label(model)
  local index, old_obj, meta_or_err, details = get_selected_typst_object(model)
  if not index then
    warn(model, old_obj, meta_or_err)
    return
  end

  local source = typst_source_dialog(model, "Edit Typst Label", meta_or_err.source)
  if not source then return end

  local new_obj, err, render_details = render_typst_to_ipe(source, {})
  if not new_obj then
    warn(model, err, render_details)
    return
  end
  attach_typst_metadata(new_obj, { source = source })
  replace_object_preserving_transform(model, index, old_obj, new_obj)
end

function rerender_typst_label(model)
  local index, old_obj, meta_or_err, details = get_selected_typst_object(model)
  if not index then
    warn(model, old_obj, meta_or_err)
    return
  end

  local new_obj, err, render_details = render_typst_to_ipe(meta_or_err.source, {})
  if not new_obj then
    warn(model, err, render_details)
    return
  end
  attach_typst_metadata(new_obj, meta_or_err)
  replace_object_preserving_transform(model, index, old_obj, new_obj)
end

methods = {
  { label = "Insert Typst Label...", run = insert_typst_label },
  { label = "Edit Typst Label...", run = edit_typst_label },
  { label = "Re-render Typst Label", run = rerender_typst_label },
}
