local wr_remaining = nil
local post_cb_installed = false

local function clear_on_page_change()
  if not wr_remaining then return true end
  local st = wr_remaining
  local cur = status and status.page or 0
  if st.start_page and cur > st.start_page then
    wr_remaining = nil
    return true
  end
  return false
end

local function post_linebreak_filter(head, is_display)
  if not wr_remaining then return head end
  if clear_on_page_change() then return head end
  local st = wr_remaining

  local nlines = 0
  for line in node.traverse_id(node.id("hlist"), head) do
    nlines = nlines + 1
  end

  -- Detect page break within paragraph
  local pt = tex.pagetotal / 65536
  local vs = tex.vsize / 65536
  local para_h = nlines * st.bskip

  if pt + para_h > vs then
    -- Paragraph spans pages: consume only the lines that fit on this page
    local on_page = math.max(1, math.floor((vs - pt) / st.bskip))
    st.used = st.used + on_page
    wr_remaining = nil
    return head
  end

  st.used = st.used + nlines
  if st.used >= st.total or st.used * st.bskip >= st.img_h then
    wr_remaining = nil
  end
  return head
end

function wr_setup_parshape()
  if not wr_remaining then return end
  if clear_on_page_change() then return end
  local st = wr_remaining
  if st.used * st.bskip >= st.img_h then
    wr_remaining = nil
    return
  end
  local n = st.total - st.used
  if n <= 0 then
    wr_remaining = nil
    return
  end
  local parts = {}
  local pi = st.parindent
  for i = 1, n do
    local idx = (st.used + i - 1) * 2 + 1
    local indent = st.lines[idx]
    local width = st.lines[idx + 1]
    if i == 1 then
      indent = indent + pi
      width = width - pi
      if width < 0 then width = 0 end
    end
    parts[#parts + 1] = indent
    parts[#parts + 1] = width
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
  texio.write("term and log", "[wrapgraphics] processing " .. tex.wr_filepath .. " (position=" .. tex.wr_position .. ") ")

  local img = tex.wr_filepath
  local out = img .. "-shape.svg"
  local thr = tex.wr_threshold
  local pad = tex.wr_padding
  local smo = tex.wr_smooth

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

  local function svg_matches_params(path)
    local f = io.open(path, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    local thr_attr = content:match('wg%-threshold="([^"]+)"')
    local pad_attr = content:match('wg%-padding="([^"]+)"')
    local smo_attr = content:match('wg%-smooth="([^"]+)"')
    return thr_attr == thr and pad_attr == pad and (smo_attr == nil or tonumber(smo_attr) == tonumber(smo))
  end

  local function run_python()
    texio.write("term and log", "[wrapgraphics] running python3 (padding=" .. pad .. ", smooth=" .. smo .. ")... ")
    os.execute("python3 " .. pyscript .. " --input " .. img
             .. " --output " .. out
             .. " --threshold " .. thr
             .. " --padding " .. pad
             .. " --smooth " .. smo)
  end

  if svg_matches_params(out) then
    dbg("cached SVG matches params, skipping Python")
  else
    run_python()
  end

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
  dbg("params: threshold=" .. thr .. " padding=" .. pad .. " smooth=" .. smo .. " scale=" .. tex.wr_scale .. " position=" .. position)

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
    sf = scale * 72.27 / shape.dpi
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

  local function boundary_x(y_level)
    local xx, found
    local n = #shape.contour
    for i = 1, n do
      local p1 = shape.contour[i]
      local p2 = shape.contour[(i % n) + 1]
      local y1 = p1[2] * sf
      local y2 = p2[2] * sf
      if (y1 <= y_level and y2 >= y_level) or (y2 <= y_level and y1 >= y_level) then
        local t
        if y2 == y1 then t = 0 else t = (y_level - y1) / (y2 - y1) end
        local x_cross = p1[1] * sf + t * (p2[1] * sf - p1[1] * sf)
        if not found then
          xx = x_cross
          found = true
        elseif position == "right" then
          if x_cross < xx then xx = x_cross end
        else
          if x_cross > xx then xx = x_cross end
        end
      end
    end
    return xx or 0, found
  end

  local function indent_for_line(i)
    local y_top = i * bskip_pt
    local y_bot = (i + 1) * bskip_pt
    local out_y = (i + 1) * bskip_pt
    if out_y >= img_h_pt then
      if position == "right" then return hsize_pt end
      return 0
    end
    if y_bot <= first_contour_y then return 0 end
    local s_top = math.max(y_top, first_contour_y)
    local s_bot = math.min(y_bot, img_h_pt)
    local best_x, found
    for s = 1, 3 do
      local ym = s_top + (s_bot - s_top) * (s - 0.5) / 3
      local bx, ok = boundary_x(ym)
      if ok then
        found = true
        if not best_x or (position == "right" and bx < best_x) or (position ~= "right" and bx > best_x) then
          best_x = bx
        end
      end
    end
    if not found then
      local ym = (s_top + s_bot) / 2
      best_x, _ = boundary_x(ym)
    end
    if position == "right" then
      return hsize_pt - gg_max_x + (best_x or 0)
    end
    return (best_x or 0) - gg_min_x
  end

  local par_n = 1
  local max_indent = 0
  local par_lines_flat = {0, hsize_pt}
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
    par_n = par_n + 1
  end

  local fmt4 = string.char(37) .. ".4f"
  local first_indent = indent_for_line(0)
  local rpad = img_w_pt - gg_max_x
  local imbox
  if position == "right" then
    imbox = "\\rlap{\\smash{\\hbox to \\the\\hsize{\\hfill\\usebox{\\csname wr@imagebox\\endcsname}\\kern -" .. string.format(fmt4, rpad) .. "pt }}}"
  else
    imbox = "\\rlap{\\hskip -" .. string.format(fmt4, gg_min_x) .. "pt \\smash{\\usebox{\\csname wr@imagebox\\endcsname}}}"
  end

  if tex.wr_contour == "true" then
    local pdf_cmds = {}
    for i, pt in ipairs(shape.contour) do
      local x = pt[1] * sf
      local y = -(pt[2] * sf)
      if i == 1 then
        pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f m", x, y)
      else
        pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f l", x, y)
      end
    end
    pdf_cmds[#pdf_cmds + 1] = "h S"
    local pdf_path = "0.5 w 1 0 0 RG " .. table.concat(pdf_cmds, " ")
    local cin = string.char(37) .. ".1f"
    if position == "right" then
      imbox = imbox
        .. "\\rlap{\\hbox to \\the\\hsize{\\hfill"
        .. "\\special{pdf: literal direct {q 1 0 0 1 -" .. string.format(cin, img_w_pt) .. " 0 cm " .. pdf_path .. " Q}}"
        .. "\\kern -" .. string.format(fmt4, rpad) .. "pt }}"
    else
      imbox = imbox
        .. "\\rlap{\\hskip -" .. string.format(fmt4, gg_min_x)
        .. "pt \\special{pdf: literal direct {q " .. pdf_path .. " Q}}}"
    end
  end

  local parshape_str = "\\parshape " .. par_n .. " "
  local line_parts = {}
  for i = 1, par_n do
    local idx = (i - 1) * 2 + 1
    line_parts[#line_parts + 1] = string.format("%.1f", par_lines_flat[idx]) .. "pt " .. string.format("%.1f", par_lines_flat[idx + 1]) .. "pt"
  end
  local parshape_str = "\\parshape " .. par_n .. " " .. table.concat(line_parts, " ")

  dbg("gg_min_x=" .. string.format("%.4f", gg_min_x) .. " gg_max_x=" .. string.format("%.4f", gg_max_x)
    .. " px:" .. gg_min_x_px .. ".." .. gg_max_x_px)
  dbg("first_contour_y=" .. string.format("%.4f", first_contour_y) .. " img_w=" .. string.format("%.2f", img_w_pt)
    .. " img_h=" .. string.format("%.2f", img_h_pt) .. " hsize=" .. string.format("%.2f", hsize_pt))
  dbg("bskip=" .. string.format("%.2f", bskip_pt) .. " num_lines=" .. par_n
    .. " first_indent=" .. string.format("%.4f", first_indent))
  dbg("imbox=" .. imbox)
  dbg("parshape=" .. parshape_str)

  wr_remaining = {
    lines = par_lines_flat,
    total = par_n,
    used = 0,
    bskip = bskip_pt,
    img_h = img_h_pt,
    pos = position,
    parindent = tex.parindent / 65536,
    start_page = status and status.page or 0,
  }

  if not post_cb_installed then
    luatexbase.add_to_callback("post_linebreak_filter", post_linebreak_filter, "wrapgraphics")
    post_cb_installed = true
  end

  tex.print("\\noindent" .. imbox .. parshape_str)
  tex.print("\\everypar{\\directlua{wr_setup_parshape()}}")
end
