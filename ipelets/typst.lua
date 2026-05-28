----------------------------------------------------------------------
-- Typst ipelet
----------------------------------------------------------------------

label = "Typst"

about = [[
ipe-typst-adapter 0.1.0

Insert and edit Typst-rendered labels as regeneratable Ipe groups.
]]

local CUSTOM_KEY = "ipe-typst"
local KIND = "ipe-typst-label"
local IPELET_VERSION = "0.1.0"
local METADATA_VERSION = 1
local os = _G.os
local io = _G.io
local math = _G.math
local string = _G.string
local table = _G.table
local ipairs = _G.ipairs
local pairs = _G.pairs
local next = _G.next
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local tonumber = _G.tonumber
local tostring = _G.tostring
local type = _G.type
local dofile = _G.dofile

local config = {
  compile_command = "typst compile --format svg {input} {output}",
  svgtoipe_command = "svgtoipe {input} {output}",
  font_family = nil,
  text_size_pt = 10,
  shortcuts = {},
}

local function load_user_config()
  local home = os.getenv("HOME")
  if not home then return end
  local ok, user_config = pcall(dofile, home .. "/.ipe/ipe-typst.lua")
  if ok and type(user_config) == "table" then
    for k, v in pairs(user_config) do
      config[k] = v
    end
  end
end

load_user_config()

local function shortcut_value(value)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function configure_shortcuts()
  if type(shortcuts) ~= "table" then return end

  local ipelet_name = name or "typst"
  local configured = config.shortcuts
  if type(configured) ~= "table" then configured = {} end

  local mappings = {
    { method = 1, value = configured.insert or config.insert_shortcut or config.shortcut },
    { method = 2, value = configured.edit or config.edit_shortcut },
    { method = 3, value = configured.rerender or configured.re_render or config.rerender_shortcut },
  }

  for _, mapping in ipairs(mappings) do
    local value = shortcut_value(mapping.value)
    if value then
      shortcuts["ipelet_" .. tostring(mapping.method) .. "_" .. ipelet_name] = value
    end
  end
end

configure_shortcuts()

local function warn(model, text, details)
  local ok = pcall(function () model:warning(text, details) end)
  if not ok then
    ipeui.messageBox(model.ui:win(), "warning", text, details, "ok")
  end
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function typst_string_quote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
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

local function xml_id_suffix(s)
  return tostring(s):gsub("[^A-Za-z0-9_-]", "_")
end

local function set_svg_path_fill(symbol, fill)
  return symbol:gsub("<path([^>]*)>", function (attrs)
    if attrs:match("%sfill=") then
      attrs = attrs:gsub('%sfill="[^"]*"', ' fill="' .. fill .. '"')
      return "<path" .. attrs .. ">"
    end
    return '<path fill="' .. fill .. '"' .. attrs .. ">"
  end)
end

local function patch_svg_use_fill(svg)
  local symbols = {}
  for symbol, id in svg:gmatch('(<symbol%s+[^>]-id="([^"]+)"[^>]*>.-</symbol>)') do
    symbols[id] = symbol
  end
  if not next(symbols) then return svg end

  local clones = {}
  local clone_order = {}
  svg = svg:gsub("<use%s+[^>]*/>", function (tag)
    local href = tag:match('xlink:href="#([^"]+)"') or tag:match('href="#([^"]+)"')
    local fill = tag:match('%sfill="([^"]+)"')
    if not href or not fill or fill == "none" or not symbols[href] then return tag end

    local clone_id = href .. "-ipe-typst-fill-" .. xml_id_suffix(fill)
    if not clones[clone_id] then
      local clone = symbols[href]:gsub('id="[^"]+"', 'id="' .. clone_id .. '"', 1)
      clone = set_svg_path_fill(clone, fill)
      clones[clone_id] = clone
      clone_order[#clone_order + 1] = clone_id
    end
    return tag:gsub('(xlink:href=)"#[^"]+"', '%1"#' .. clone_id .. '"', 1)
      :gsub('(href=)"#[^"]+"', '%1"#' .. clone_id .. '"', 1)
  end)

  if #clone_order == 0 then return svg end
  local clone_text = {}
  for _, clone_id in ipairs(clone_order) do
    clone_text[#clone_text + 1] = clones[clone_id]
  end
  return svg:gsub("</defs>", table.concat(clone_text, "\n") .. "\n</defs>", 1)
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

local function template_command_name(template)
  return tostring(template or ""):match("^%s*(%S+)")
end

local function validate_command_template(name, template)
  if type(template) ~= "string" or template == "" then
    return nil, name .. " is not configured.", nil
  end
  if not template:match("{input}") or not template:match("{output}") then
    return nil, name .. " must contain {input} and {output}.",
      "Current template:\n" .. template
  end
  return true
end

local function ensure_template_command(template, default_name, install_hint)
  local command = template_command_name(template)
  if command and not command_exists(command) then
    return nil, "`" .. command .. "` was not found in PATH.",
      install_hint or ("Please make sure `" .. command .. "` is executable from Ipe.")
  end
  return true
end

local function expand_command(template, vars)
  return template
    :gsub("{input}", shell_quote(vars.input))
    :gsub("{output}", shell_quote(vars.output))
    :gsub("{dir}", shell_quote(vars.dir))
end

function make_typst_document(source, options)
  options = options or {}
  local width = options.page_width or "auto"
  local height = options.page_height or "auto"
  local text_size = options.text_size or tostring(options.text_size_pt or config.text_size_pt) .. "pt"
  local fill = options.fill or "none"
  local font_family = options.font_family or config.font_family
  local text_args = "size: " .. text_size
  if font_family and font_family ~= "" then
    text_args = text_args .. ", font: " .. typst_string_quote(font_family)
  end
  return string.format([[
#set page(width: %s, height: %s, margin: 0pt, fill: %s)
#set text(%s)

%s
]], width, height, fill, text_args, source)
end

function render_typst_to_ipe(source, options)
  local ok, text, details = validate_command_template("compile_command", config.compile_command)
  if not ok then return nil, text, details end
  ok, text, details = validate_command_template("svgtoipe_command", config.svgtoipe_command)
  if not ok then return nil, text, details end

  ok, text, details = ensure_template_command(config.compile_command, "typst",
    "Please install Typst and make sure the configured compile_command is executable from Ipe.")
  if not ok then return nil, text, details end
  ok, text, details = ensure_template_command(config.svgtoipe_command, "svgtoipe",
    "Please install svgtoipe and make sure the configured svgtoipe_command is executable from Ipe.")
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

  local cmd = expand_command(config.compile_command, {
    input = typ_path,
    output = svg_path,
    dir = dir,
  })
  ok, _, err = run_command(cmd)
  if not ok then
    local details_text = (err or "")
    if details_text ~= "" then details_text = details_text .. "\n\n" end
    details_text = details_text .. "Temporary directory: " .. dir
    return nil, "Typst compilation failed.", details_text
  end

  local svg, svg_read_err = read_file(svg_path)
  if not svg then
    remove_tree(dir)
    return nil, "Could not read generated SVG.", svg_read_err
  end
  local wrote_svg, svg_write_err = write_file(svg_path, patch_svg_use_fill(svg))
  if not wrote_svg then
    remove_tree(dir)
    return nil, "Could not patch generated SVG.", svg_write_err
  end

  cmd = expand_command(config.svgtoipe_command, {
    input = svg_path,
    output = ipe_path,
    dir = dir,
  })
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
    "version=" .. tostring(METADATA_VERSION),
    "adapter-version=" .. IPELET_VERSION,
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
  return { kind = kind, version = version or METADATA_VERSION, source = source }
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

local function move_object_bbox_to_position(obj, pos)
  local box = ipe.Rect()
  obj:addToBBox(box, ipe.Matrix(), false)
  if box:isEmpty() then
    obj:setMatrix(ipe.Translation(pos))
    return
  end
  local delta = pos - box:bottomLeft()
  obj:setMatrix(ipe.Translation(delta) * obj:matrix())
end

local function matrix_for_object_bbox_at_position(obj, pos)
  local box = ipe.Rect()
  obj:addToBBox(box, ipe.Matrix(), false)
  if box:isEmpty() then return ipe.Translation(pos) end
  return ipe.Translation(pos - box:bottomLeft()) * obj:matrix()
end

----------------------------------------------------------------------
-- UI layer
----------------------------------------------------------------------

TYPSTPASTETOOL = {}
TYPSTPASTETOOL.__index = TYPSTPASTETOOL

function TYPSTPASTETOOL:new(model, obj)
  local tool = {}
  setmetatable(tool, TYPSTPASTETOOL)
  tool.model = model
  tool.obj = obj
  tool.pos = model.ui:pos()
  model.ui:pasteTool(obj, tool)
  tool.setColor(1.0, 0, 0)
  tool:mouseMove()
  return tool
end

function TYPSTPASTETOOL:placedObject()
  local obj = self.obj:clone()
  obj:setMatrix(matrix_for_object_bbox_at_position(obj, self.pos))
  return obj
end

function TYPSTPASTETOOL:mouseButton(button, modifiers, press)
  if not press then return end
  self.pos = self.model.ui:pos()
  self.model.ui:finishTool()
  self.model:creation("create Typst label", self:placedObject())
end

function TYPSTPASTETOOL:mouseMove(button, modifiers)
  self.pos = self.model.ui:pos()
  self.setMatrix(matrix_for_object_bbox_at_position(self.obj, self.pos))
  self.model.ui:update(false)
end

function TYPSTPASTETOOL:key(code, modifiers, text)
  if text == "\027" then
    self.model.ui:finishTool()
    return true
  end
  return false
end

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

  TYPSTPASTETOOL:new(model, obj)
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
