local wr_remaining = nil
local post_cb_installed = false

local function post_linebreak_filter(head, is_display)
  if not wr_remaining then return head end
  local st = wr_remaining
  local nlines = 0
  for line in node.traverse_id(node.id("hlist"), head) do
    nlines = nlines + 1
  end
  st.used = st.used + nlines
  if st.used >= st.total then
    wr_remaining = nil
  end
  return head
end

function wr_setup_parshape()
  if not wr_remaining then return end
  local st = wr_remaining
  local n = st.total - st.used
  if n <= 0 then
    wr_remaining = nil
    return
  end
  local parts = {}
  for i = 1, n do
    local idx = (st.used + i - 1) * 2 + 1
    parts[#parts + 1] = st.lines[idx]
    parts[#parts + 1] = st.lines[idx + 1]
  end
  local str = "\\parshape " .. n .. " "
  for _, v in ipairs(parts) do
    str = str .. string.format("%.1f", v) .. "pt "
  end
  tex.print(str)
end

function wrapgraphics_run()
  local verbose_enabled = tex.wr_verbose == "true"
  local function dbg(msg)
    if verbose_enabled then
      texio.write_nl("term and log", "[wrapgraphics] " .. msg)
    end
  end

  local img = tex.wr_filepath
  local out = img .. "-shape.svg"
  local thr = tex.wr_threshold
  local pad = tex.wr_padding

  local function find_pyscript()
    local f = io.open("wrapgraphics.py", "r")
    if f then f:close(); return "wrapgraphics.py" end
    local texdir = img:match("^(.*/)")
    if texdir then
      local c = texdir .. "wrapgraphics.py"
      f = io.open(c, "r")
      if f then f:close(); return c end
      local p = texdir .. "../wrapgraphics.py"
      f = io.open(p, "r")
      if f then f:close(); return p end
    end
    local h = io.popen("kpsewhich wrapgraphics.py 2>/dev/null")
    if h then
      local r = h:read("*l")
      h:close()
      if r and r ~= "" then return r end
    end
    return nil
  end
  local pyscript = find_pyscript()
  if not pyscript then
    tex.print("\\PackageError{wrapgraphics}{Cannot find wrapgraphics.py}{}")
    return
  end

  os.execute("python3 " .. pyscript .. " --input " .. img
           .. " --output " .. out
           .. " --threshold " .. thr
           .. " --padding " .. pad)

  local function parse_svg(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local function extract_attr(name)
      local _, e = content:find(name .. '="', 1, true)
      if not e then return nil end
      local val = content:sub(e + 1, content:find('"', e + 1, true) - 1)
      return val
    end
    local w = tonumber(extract_attr('width'))
    local h = tonumber(extract_attr('height'))
    local dpi = tonumber(extract_attr('wg-dpi'))
    local invert = content:find('wg-invert="1"', 1, true) ~= nil
    local points = {}
    local d = content:match('<path d="(.-)"')
    if d then
      local nums = {}
      for token in d:gmatch("[^ ]+") do
        local n = tonumber(token)
        if n then
          table.insert(nums, n)
        end
      end
      local nnums = 0
      for _ in ipairs(nums) do nnums = nnums + 1 end
      for i = 1, nnums - 1, 2 do
        table.insert(points, {nums[i], nums[i+1]})
      end
    end
    return {width = w, height = h, dpi = dpi, invert = invert, contour = points}
  end

  local ok, shape = pcall(parse_svg, out)
  if not ok or not shape then
    tex.print("\\PackageError{wrapgraphics}{Failed to load shape file}{}")
    return
  end

  local position = tex.wr_position
  if shape.invert and position == "left" then position = "right" end

  dbg("image=" .. img .. " " .. shape.width .. "x" .. shape.height .. " dpi=" .. shape.dpi)
  dbg("contour: " .. #shape.contour .. " points, invert=" .. tostring(shape.invert))
  dbg("params: threshold=" .. thr .. " padding=" .. pad .. " scale=" .. tex.wr_scale .. " position=" .. position)

  if next(shape.contour) == nil then
    dbg("empty contour -- no wrapping")
    local imbox = "\\noindent\\usebox{\\csname wr@imagebox\\endcsname}"
    if position == "right" then
      imbox = "\\noindent{\\hfill\\usebox{\\csname wr@imagebox\\endcsname}}"
    end
    tex.print(imbox)
    return
  end

  local scale = tonumber(tex.wr_scale)
  local width_override = tex.wr_width
  if width_override ~= "" then
    scale = nil
  end

  local sf
  if scale then
    sf = scale * 72.0 / shape.dpi
  else
    local explicit_width_pt = tonumber(width_override:match("([0-9.]+)"))
    sf = explicit_width_pt / shape.width
  end
  dbg("scale=" .. (scale or "nil") .. " sf=" .. string.format("%.6f", sf))

  local gg_min_x_px = math.huge
  local gg_max_x_px = -math.huge
  local gg_min_y_px = math.huge
  local gg_max_y_px = -math.huge
  for _, pt in ipairs(shape.contour) do
    if pt[1] < gg_min_x_px then gg_min_x_px = pt[1] end
    if pt[1] > gg_max_x_px then gg_max_x_px = pt[1] end
    if pt[2] < gg_min_y_px then gg_min_y_px = pt[2] end
    if pt[2] > gg_max_y_px then gg_max_y_px = pt[2] end
  end
  local gg_min_x = gg_min_x_px * sf
  local gg_max_x = gg_max_x_px * sf

  local img_w_pt = shape.width * sf
  local img_h_pt = shape.height * sf
  local hsize_pt = tex.hsize / 65536
  local first_contour_y = gg_min_y_px * sf
  local bskip_pt = tex.baselineskip.width / 65536
  if bskip_pt <= 0 then bskip_pt = 12 end

  local num_lines = math.ceil(img_h_pt / bskip_pt) + 2
  local lines_override = tex.wr_lines
  if lines_override ~= "" then
    num_lines = tonumber(lines_override)
  end

  local hang_mode = tex.wr_hang == "true"

  local function points_in_range(y_top, y_bot)
    local pts = {}
    for _, pt in ipairs(shape.contour) do
      local y_pt = pt[2] * sf
      if y_pt >= y_top and y_pt <= y_bot then
        table.insert(pts, pt[1] * sf)
      end
    end
    return pts
  end

  local function interpolate_x(y_mid)
    local above, below
    for _, pt in ipairs(shape.contour) do
      local y_pt = pt[2] * sf
      if y_pt >= y_mid then
        if not above or y_pt < above[2] then
          above = {pt[1] * sf, y_pt}
        end
      end
      if y_pt <= y_mid then
        if not below or y_pt > below[2] then
          below = {pt[1] * sf, y_pt}
        end
      end
    end
    if above and below then
      if above[2] == below[2] then return above[1] end
      local t = (y_mid - below[2]) / (above[2] - below[2])
      return below[1] + t * (above[1] - below[1])
    elseif above then
      return above[1]
    elseif below then
      return below[1]
    end
    return 0
  end

  local function indent_for_line(i)
    local y_top = i * bskip_pt
    local y_bot = (i + 1) * bskip_pt
    if y_top >= img_h_pt then return 0 end
    if y_bot <= first_contour_y then return 0 end
    local s_top = math.max(y_top, first_contour_y)
    local s_bot = math.min(y_bot, img_h_pt)
    local pts = points_in_range(s_top, s_bot)
    local x_val
    if next(pts) ~= nil then
      if position == "right" then
        x_val = math.min(table.unpack(pts))
      else
        x_val = math.max(table.unpack(pts))
      end
    else
      x_val = interpolate_x((s_top + s_bot) / 2)
    end
    if position == "right" then
      return hsize_pt - gg_max_x + x_val
    end
    return x_val - gg_min_x
  end

  local max_indent = 0
  local par_lines_flat = {}
  for i = 0, num_lines - 1 do
    local boundary = indent_for_line(i)
    if boundary > max_indent then max_indent = boundary end
    local indent, width
    if position == "right" then
      if hang_mode then boundary = max_indent end
      indent = 0
      width = boundary
    else
      if hang_mode then boundary = max_indent end
      indent = boundary
      width = hsize_pt - boundary
    end
    if width < 0 then width = 0 end
    if indent < 0 then indent = 0 end
    par_lines_flat[#par_lines_flat + 1] = indent
    par_lines_flat[#par_lines_flat + 1] = width
  end

  local fmt4 = string.char(37) .. ".4f"
  local first_indent = indent_for_line(0)
  local rpad = img_w_pt - gg_max_x
  local imbox
  if position == "right" then
    imbox = "\\rlap{\\smash{\\hbox to \\the\\hsize{\\hfill\\usebox{\\csname wr@imagebox\\endcsname}\\kern -" .. string.format(fmt4, rpad) .. "pt }}}"
  else
    imbox = "\\rlap{\\hskip -" .. string.format(fmt4, first_indent) .. "pt \\hskip -" .. string.format(fmt4, gg_min_x) .. "pt \\smash{\\usebox{\\csname wr@imagebox\\endcsname}}}"
  end

  if tex.wr_contour == "true" then
    local pdf_cmds = {}
    for i, pt in ipairs(shape.contour) do
      local x = pt[1] * sf
      local y = img_h_pt - pt[2] * sf
      if i == 1 then
        pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f m", x, y)
      else
        pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f l", x, y)
      end
    end
    pdf_cmds[#pdf_cmds + 1] = "h S"
    local pdf_path = "0.5 w 0 1 0 RG " .. table.concat(pdf_cmds, " ")
    local cin = string.char(37) .. ".1f"
    if position == "right" then
      imbox = imbox
        .. "\\rlap{\\hbox to \\the\\hsize{\\hfill"
        .. "\\special{pdf: literal direct {q 1 0 0 1 -" .. string.format(cin, img_w_pt) .. " 0 cm " .. pdf_path .. " Q}}"
        .. "\\kern -" .. string.format(fmt4, rpad) .. "pt }}"
    else
      imbox = imbox
        .. "\\rlap{\\hskip -" .. string.format(fmt4, first_indent)
        .. "pt \\hskip -" .. string.format(fmt4, gg_min_x)
        .. "pt \\special{pdf: literal direct {q " .. pdf_path .. " Q}}}"
    end
  end

  local parshape_str = "\\parshape " .. num_lines .. " "
  local line_parts = {}
  for i = 1, num_lines do
    local idx = (i - 1) * 2 + 1
    line_parts[#line_parts + 1] = string.format("%.1f", par_lines_flat[idx]) .. "pt " .. string.format("%.1f", par_lines_flat[idx + 1]) .. "pt"
  end
  local parshape_str = "\\parshape " .. num_lines .. " " .. table.concat(line_parts, " ")

  dbg("gg_min_x=" .. string.format("%.4f", gg_min_x) .. " gg_max_x=" .. string.format("%.4f", gg_max_x)
    .. " px:" .. gg_min_x_px .. ".." .. gg_max_x_px)
  dbg("first_contour_y=" .. string.format("%.4f", first_contour_y) .. " img_w=" .. string.format("%.2f", img_w_pt)
    .. " img_h=" .. string.format("%.2f", img_h_pt) .. " hsize=" .. string.format("%.2f", hsize_pt))
  dbg("bskip=" .. string.format("%.2f", bskip_pt) .. " num_lines=" .. num_lines
    .. " first_indent=" .. string.format("%.4f", first_indent))
  dbg("imbox=" .. imbox)
  dbg("parshape=" .. parshape_str)

  wr_remaining = {
    lines = par_lines_flat,
    total = num_lines,
    used = 0,
  }

  if not post_cb_installed then
    luatexbase.add_to_callback("post_linebreak_filter", post_linebreak_filter, "wrapgraphics")
    post_cb_installed = true
  end

  tex.print("\\noindent" .. imbox .. parshape_str)
  tex.print("\\everypar{\\directlua{wr_setup_parshape()}}")
end
