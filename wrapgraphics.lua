--[doc]
-- \texttt{wrapgraphics.lua} --- Lua module for the \textsf{wrapgraphics} package.
-- 
-- This file is loaded by \texttt{wrapgraphics.sty} via
-- \verb|\directlua{dofile("wrapgraphics.lua")}| at package load time.
-- Keeping the Lua code in a separate file avoids TeX catcode issues
-- with \verb|#| (parameter character) and \verb|~| (active character)
-- that would arise inside \verb|\directlua| within macro definitions.
-- 
-- The module provides two public functions:
-- \begin{description}
-- \item[\texttt{wrapgraphics\_run()}] called from \verb|\wrapgraphics|
-- via \verb|\directlua|; orchestrates the full pipeline.
-- \item[\texttt{wr\_setup\_parshape()}] called from \verb|\everypar|
-- on each new paragraph line; injects the remaining
-- \verb|\parshape| entries when wrapping spans multiple pages.
-- \end{description}
-- 
-- The computation is decomposed into subroutines documented below.
-- State is maintained in the \texttt{wr\_remaining} table, which tracks
-- how many lines of wrapping have been consumed and how many remain.
-- A \texttt{post\_linebreak\_filter} callback updates this state after
-- each paragraph break.
--[/doc]
local wr_remaining = nil
local post_cb_installed = false

--[doc]
-- Module-level verbose flag. Set at the start of \texttt{wrapgraphics\_run()}
-- from the \texttt{verbose} package option. Used by \texttt{dbg()} to
-- conditionally write debug messages to the terminal and log.
--[/doc]
local wr_verbose = false

local function dbg(msg)
  if wr_verbose then
    texio.write_nl("term and log", "[wrapgraphics] " .. msg)
  end
end

--[doc]
-- \subsection*{Page-break handling}
-- 
-- When the wrapping paragraph spans a page break, the shape must be
-- split across pages. \texttt{clear\_on\_page\_change()} detects page
-- transitions and clears the remaining shape.
-- 
-- \textbf{Input:} none (reads module state \texttt{wr\_remaining})
-- \textbf{Output:} \texttt{true} if the page changed (state cleared),
-- \texttt{false} otherwise
--
-- \texttt{post\_linebreak\_filter} is a Lua\TeX{} callback that runs
-- after every paragraph break. It counts how many lines were typeset
-- and marks them as consumed. If the paragraph exceeds the current
-- page, only the lines that fit on this page are consumed.
--
-- \textbf{Input:} \texttt{head} --- node list head, \texttt{is\_display} ---
-- display math flag (both passed by Lua\TeX)
-- \textbf{Output:} the (unmodified) node list
--[/doc]
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
    -- Clear lines where parshape width <= 0 (contour wider than column)
    local line_idx = st.used + nlines - 1
    if line_idx < st.total then
      local pw = st.lines[line_idx * 2 + 2]
      if pw and pw <= 0 then
        local empty = node.new("hlist")
        empty.width = 0
        node.slide(empty)
        node.flush_list(line.list)
        line.list = empty
      end
    end
  end

  local pt = tex.pagetotal / 65536
  local vs = tex.vsize / 65536
  local para_h = nlines * st.bskip

  if pt + para_h > vs then
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

--[doc]
-- \subsection*{\texttt{wr\_setup\_parshape}}
--
-- Called from \verb|\everypar| on every new paragraph line when there
-- are remaining wrapped lines. It slices the next chunk of
-- \verb|\parshape| entries from the stored \texttt{wr\_remaining.lines}
-- array (which stores indent and width as flat pairs) and injects them
-- into the \TeX{} stream.
-- 
-- The function checks whether the image height has been fully covered;
-- if so, it clears the state and subsequent lines use full text width.
-- 
-- \textbf{Input:} none (reads module state \texttt{wr\_remaining})
-- \textbf{Output:} none (writes into the \TeX{} stream via \texttt{tex.print})
--[/doc]
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

--[doc]
-- \subsubsection*{\texttt{wr\_find\_pyscript}}
--
-- Locates the \texttt{wrapgraphics.py} script on disk.
-- Searches in order:
-- \begin{enumerate}
-- \item current working directory
-- \item the directory of the image file
-- \item the parent of the image directory
-- \item via \texttt{kpsewhich}
-- \end{enumerate}
-- 
-- Mathematical notation: none.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{img} --- image file path (string)
-- \end{itemize}
-- \textbf{Output:} absolute or relative path to \texttt{wrapgraphics.py}
-- (string), or \texttt{nil} if not found
--[/doc]
local function wr_find_pyscript(img)
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

--[doc]
-- \subsubsection*{\texttt{wr\_svg\_matches\_params}}
--
-- Checks whether a cached \texttt{-shape.svg} file exists with metadata
-- matching the current threshold, padding, and smooth parameters.
-- If the parameters match, the expensive Python call can be skipped
-- (the SVG is reusable across \LaTeX{} compilations).
--
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{path} --- path to the \texttt{-shape.svg} file
-- \item \texttt{thr} --- threshold value (string)
-- \item \texttt{pad} --- padding value (string)
-- \item \texttt{smo} --- smooth value (string)
-- \end{itemize}
-- \textbf{Output:} \texttt{true} if the cached SVG matches the
-- parameters, \texttt{false} otherwise
--[/doc]
local function wr_svg_matches_params(path, thr, pad, smo)
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  local thr_attr = content:match('wg%-threshold="([^"]+)"')
  local pad_attr = content:match('wg%-padding="([^"]+)"')
  local smo_attr = content:match('wg%-smooth="([^"]+)"')
  return thr_attr == thr and pad_attr == pad and (smo_attr == nil or tonumber(smo_attr) == tonumber(smo))
end

--[doc]
-- \subsubsection*{\texttt{wr\_run\_python}}
--
-- Invokes \texttt{wrapgraphics.py} via \texttt{os.execute} (shell-escape).
-- The Python script reads the image, thresholds its alpha channel,
-- dilates by $N$ pixels, traces the contour (Moore--Neighbor), and
-- writes the result to \texttt{-shape.svg}.
--
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{pyscript} --- path to \texttt{wrapgraphics.py}
-- \item \texttt{img} --- input image path
-- \item \texttt{out} --- output SVG path
-- \item \texttt{thr} --- alpha threshold
-- \item \texttt{pad} --- dilation padding in pixels ($N$)
-- \item \texttt{smo} --- contour smoothing factor
-- \end{itemize}
-- \textbf{Output:} none (writes \texttt{-shape.svg} as a side effect)
--[/doc]
local function wr_run_python(pyscript, img, out, thr, pad, smo)
  texio.write("term and log", "[wrapgraphics] running python3 (padding=" .. pad .. ", smooth=" .. smo .. ")... ")
  os.execute("python3 " .. pyscript .. " --input " .. img
           .. " --output " .. out
           .. " --threshold " .. thr
           .. " --padding " .. pad
           .. " --smooth " .. smo)
end

--[doc]
-- \subsubsection*{\texttt{wr\_parse\_svg}}
--
-- Parses the \texttt{-shape.svg} file with simple string matching
-- (no XML library). Extracts image width, height, DPI, the invert
-- flag, and the contour point list from the \texttt{<path d="...">}
-- attribute.
-- 
-- The function is designed to run inside \texttt{pcall} so that a
-- malformed SVG produces a user-friendly \LaTeX{} error rather than
-- a Lua backtrace.
--
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{path} --- path to the \texttt{-shape.svg} file
-- \end{itemize}
-- \textbf{Output:} table with fields \texttt{width}, \texttt{height},
-- \texttt{dpi}, \texttt{invert}, and \texttt{contour} (list of
-- $\{x, y\}$ pixel pairs); or \texttt{nil} on failure
--[/doc]
local function wr_parse_svg(path)
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
    local nnums = #nums
    for i = 1, nnums - 1, 2 do
      table.insert(points, {nums[i], nums[i+1]})
    end
  end
  return {width = w, height = h, dpi = dpi, invert = invert, contour = points}
end

--[doc]
-- \subsubsection*{\texttt{wr\_compute\_scale}}
--
-- Computes the scale factor $s$ that converts image pixels to points.
-- Two modes:
-- \begin{itemize}
-- \item \texttt{scale} given: $s = s_u \cdot 72.27 / d$ where $s_u$
-- is the user-provided scale factor and $d$ is the image DPI
-- (the constant $72.27$ is the number of points per inch).
-- \item \texttt{width} given: $s = w_{\text{pt}} / w$ where
-- $w_{\text{pt}}$ is the explicit width in points and $w$ is
-- the image width in pixels.
-- \end{itemize}
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{scale\_str} --- user scale (string, may be empty)
-- \item \texttt{width\_str} --- user width (string, may be empty)
-- \item \texttt{shape} --- parsed SVG table (must have \texttt{.dpi}
-- and \texttt{.width} fields)
-- \end{itemize}
-- \textbf{Output:} scale factor $s$ (number)
--[/doc]
local function wr_compute_scale(scale_str, width_str, shape)
  local scale = tonumber(scale_str)
  if width_str ~= "" then
    scale = nil
  end
  if scale then
    return scale * 72.27 / shape.dpi
  else
    local explicit_width_pt = tonumber(width_str:match("([0-9.]+)"))
    return explicit_width_pt / shape.width
  end
end

--[doc]
-- \subsubsection*{\texttt{wr\_contour\_bounds}}
--
-- Computes the axis-aligned bounding box of the contour in both
-- pixels and scaled points.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{contour} --- list of $\{x, y\}$ pixel pairs
-- \item \texttt{sf} --- scale factor $s$ (pixels $\to$ points)
-- \end{itemize}
-- \textbf{Output:} table with fields \texttt{min\_x\_px},
-- \texttt{max\_x\_px}, \texttt{min\_y\_px}, \texttt{max\_y\_px} (pixel
-- values) and \texttt{min\_x\_pt}, \texttt{max\_x\_pt},
-- \texttt{min\_y\_pt}, \texttt{max\_y\_pt} (scaled point values)
--[/doc]
local function wr_contour_bounds(contour, sf)
  local min_x_px = math.huge
  local max_x_px = -math.huge
  local min_y_px = math.huge
  local max_y_px = -math.huge
  for _, pt in ipairs(contour) do
    if pt[1] < min_x_px then min_x_px = pt[1] end
    if pt[1] > max_x_px then max_x_px = pt[1] end
    if pt[2] < min_y_px then min_y_px = pt[2] end
    if pt[2] > max_y_px then max_y_px = pt[2] end
  end
  return {
    min_x_px = min_x_px, max_x_px = max_x_px,
    min_y_px = min_y_px, max_y_px = max_y_px,
    min_x_pt = min_x_px * sf, max_x_pt = max_x_px * sf,
    min_y_pt = min_y_px * sf, max_y_pt = max_y_px * sf,
  }
end

--[doc]
-- \subsubsection*{\texttt{wr\_get\_boundaries}}
--
-- For a given vertical position $y$ (in points), walks the closed
-- contour polygon and finds the leftmost and rightmost $x$-coordinates
-- where a horizontal line at $y$ crosses the contour. This yields the
-- horizontal span of the image at that $y$-level.
-- 
-- For each edge $(p_1, p_2)$ that straddles $y$, linear interpolation
-- gives the crossing point:
-- \[
-- t = \frac{y - y_1}{y_2 - y_1},
-- \qquad
-- x = x_1 s + t\,(x_2 s - x_1 s)
-- \]
-- where $s$ is the scale factor.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{contour} --- list of $\{x, y\}$ pixel pairs
-- \item \texttt{sf} --- scale factor $s$
-- \item \texttt{y\_level} --- $y$ coordinate in points
-- \end{itemize}
-- \textbf{Output:} \texttt{left\_x}, \texttt{right\_x} (numbers in
-- points), \texttt{found} (boolean, \texttt{false} if no intersection)
--[/doc]
local function wr_get_boundaries(contour, sf, y_level)
  local left_x, right_x
  local found = false
  local n = #contour
  for i = 1, n do
    local p1 = contour[i]
    local p2 = contour[(i % n) + 1]
    local y1 = p1[2] * sf
    local y2 = p2[2] * sf
    if (y1 <= y_level and y2 >= y_level) or (y2 <= y_level and y1 >= y_level) then
      local t
      if y2 == y1 then t = 0 else t = (y_level - y1) / (y2 - y1) end
      local x_cross = p1[1] * sf + t * (p2[1] * sf - p1[1] * sf)
      if not found then
        left_x = x_cross
        right_x = x_cross
        found = true
      else
        if x_cross < left_x then left_x = x_cross end
        if x_cross > right_x then right_x = x_cross end
      end
    end
  end
  return left_x, right_x, found
end

--[doc]
-- \subsubsection*{\texttt{wr\_boundary\_x}}
--
-- Selects the relevant contour boundary for the current wrapping side.
-- For \texttt{right} position, returns the leftmost $x$ (text ends
-- before the left side of the image). For \texttt{left} position,
-- returns the rightmost $x$ (text starts after the right side of
-- the image).
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{position} --- \texttt{"left"} or \texttt{"right"}
-- \item \texttt{contour}, \texttt{sf}, \texttt{y\_level} --- as in
-- \texttt{wr\_get\_boundaries}
-- \end{itemize}
-- \textbf{Output:} \texttt{bx} (the relevant boundary $x$ in points,
-- or $0$ if no intersection), \texttt{found} (boolean)
--[/doc]
local function wr_boundary_x(position, contour, sf, y_level)
  local left_x, right_x, found = wr_get_boundaries(contour, sf, y_level)
  if position == "right" then
    return left_x or 0, found
  else
    return right_x or 0, found
  end
end

--[doc]
-- \subsubsection*{\texttt{wr\_indent\_for\_line\_middle}}
--
-- Computes \texttt{\string\parshape} indent and width for a given
-- line when \texttt{position=middle}. The image is centred and text
-- wraps on both sides.
-- 
-- The vertical range of the line is sub-sampled at three points:
-- \[
-- y_m = y_{\text{top}} + (y_{\text{bot}} - y_{\text{top}})\,\frac{s - 0.5}{3},
-- \qquad s \in \{1, 2, 3\}
-- \]
-- The widest (rightmost) contour boundary at these samples determines
-- the indent. The centre offset is $\frac{\text{hsize} - w_{\text{img}}}{2}$.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{i} --- line index (0-based)
-- \item \texttt{geom} --- geometry table (see \texttt{wrapgraphics\_run})
-- \item \texttt{contour}, \texttt{sf} --- contour and scale factor
-- \end{itemize}
-- \textbf{Output:} \texttt{indent}, \texttt{width} (numbers in points)
--[/doc]
local function wr_indent_for_line_middle(i, geom, contour, sf)
  local y_top = i * geom.bskip_pt - geom.shifty_pt
  local y_bot = (i + 1) * geom.bskip_pt - geom.shifty_pt
  if y_top >= geom.gg_max_y_pt then return 0, geom.hsize_pt end
  if y_bot <= geom.first_contour_y then return 0, geom.hsize_pt end
  local s_top = math.max(y_top, geom.first_contour_y)
  local s_bot = math.min(y_bot, geom.gg_max_y_pt)
  local best_x, found
  for s = 1, 3 do
    local ym = s_top + (s_bot - s_top) * (s - 0.5) / 3
    local _, rx, ok = wr_get_boundaries(contour, sf, ym)
    if ok then
      found = true
      if not best_x or rx > best_x then best_x = rx end
    end
  end
  if not found then
    local ym = (s_top + s_bot) / 2
    _, best_x, _ = wr_get_boundaries(contour, sf, ym)
  end
  local center_offset = (geom.hsize_pt - geom.img_w_pt) / 2
  local indent = center_offset + (best_x or 0) + geom.shiftx_pt
  local width = geom.hsize_pt - indent
  if width < 0 then width = 0 end
  if indent < 0 then indent = 0 end
  return indent, width
end

--[doc]
-- \subsubsection*{\texttt{wr\_indent\_for\_line}}
--
-- Computes the \texttt{\string\parshape} indent for a given line
-- when \texttt{position} is \texttt{left} or \texttt{right}.
-- 
-- Same sub-sampling strategy as \texttt{wr\_indent\_for\_line\_middle},
-- but returns a single boundary value. For \texttt{left} wrapping the
-- indent is $\text{offset} = \text{bx} - x_{\text{min}} + \text{shiftx}$;
-- for \texttt{right} wrapping the indent is
-- $\text{offset} = \text{hsize} - x_{\text{max}} + \text{bx} + \text{shiftx}$.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{i} --- line index (0-based)
-- \item \texttt{position} --- \texttt{"left"} or \texttt{"right"}
-- \item \texttt{geom} --- geometry table
-- \item \texttt{contour}, \texttt{sf} --- contour and scale factor
-- \end{itemize}
-- \textbf{Output:} boundary offset (number in points)
--[/doc]
local function wr_indent_for_line(i, position, geom, contour, sf)
  local y_top = i * geom.bskip_pt - geom.shifty_pt
  local y_bot = (i + 1) * geom.bskip_pt - geom.shifty_pt
  if y_top >= geom.gg_max_y_pt then
    if position == "right" then return geom.hsize_pt end
    return 0
  end
  if y_bot <= geom.first_contour_y then return 0 end
  local s_top = math.max(y_top, geom.first_contour_y)
  local s_bot = math.min(y_bot, geom.gg_max_y_pt)
  local best_x, found
  for s = 1, 3 do
    local ym = s_top + (s_bot - s_top) * (s - 0.5) / 3
    local bx, ok = wr_boundary_x(position, contour, sf, ym)
    if ok then
      found = true
      if not best_x or (position == "right" and bx < best_x) or (position ~= "right" and bx > best_x) then
        best_x = bx
      end
    end
  end
  if not found then
    local ym = (s_top + s_bot) / 2
    best_x, _ = wr_boundary_x(position, contour, sf, ym)
  end
  if position == "right" then
    return geom.hsize_pt - geom.gg_max_x + (best_x or 0) + geom.shiftx_pt
  end
  return (best_x or 0) - geom.gg_min_x + geom.shiftx_pt
end

--[doc]
-- \subsubsection*{\texttt{wr\_build\_parshape}}
--
-- Constructs the flat \texttt{\string\parshape} array and the
-- corresponding \texttt{\string\parshape} command string.
-- 
-- The array contains flat pairs of indent and width for each line:
-- \begin{enumerate}
-- \item $k$ skipped lines (full text width, from \texttt{skip} key)
-- \item $n$ wrapped lines (indent/width from the contour)
-- \item one sentinel line (full width) --- any line beyond the
-- wrapped region automatically uses the full text width
-- without needing a separate \texttt{\string\parshape} reset.
-- \end{enumerate}
-- 
-- For \texttt{position=middle} each line gets both indent and width
-- from \texttt{wr\_indent\_for\_line\_middle}. For \texttt{left}/
-- \texttt{right}, the hang mode may lock the indent to the minimum
-- or maximum across all wrapped lines.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{skip\_count} --- number of full-width lines at the start
-- \item \texttt{hsize\_pt} --- \texttt{\string\hsize} in points
-- \item \texttt{position} --- \texttt{"left"}, \texttt{"right"}, or \texttt{"middle"}
-- \item \texttt{num\_lines} --- number of wrapped lines
-- \item \texttt{hang\_mode} --- boolean, lock indent to extremum
-- \item remaining: \texttt{geom}, \texttt{contour}, \texttt{sf}
-- \end{itemize}
-- \textbf{Output:} \texttt{par\_n} (number of parshape entries),
-- \texttt{par\_lines\_flat} (flat table of indent/width pairs),
-- \texttt{parshape\_str} (the \texttt{\string\parshape} command string)
--[/doc]
local function wr_build_parshape(skip_count, hsize_pt, position, num_lines, hang_mode, geom, contour, sf)
  local par_n = 0
  local par_lines_flat = {}

  for i = 1, skip_count do
    -- Full-width lines before wrapping (skip parameter)
    par_lines_flat[#par_lines_flat + 1] = 0
    par_lines_flat[#par_lines_flat + 1] = hsize_pt
    par_n = par_n + 1
  end

  if position == "middle" then
    -- Wrapped lines start from skip_count (skip lines are already placed)
    for i = skip_count, num_lines - 1 do
      local indent, width = wr_indent_for_line_middle(i, geom, contour, sf)
      par_lines_flat[#par_lines_flat + 1] = indent
      par_lines_flat[#par_lines_flat + 1] = width
      par_n = par_n + 1
    end
  else
    local max_indent = 0
    local min_indent = 1e308
    for i = skip_count, num_lines - 1 do
      local boundary = wr_indent_for_line(i, position, geom, contour, sf)
      local indent, width
      if position == "right" then
        -- Right: text flows on the left, indent=0, width = boundary
        if hang_mode then
          if boundary < min_indent then min_indent = boundary end
          boundary = min_indent
        end
        indent = 0
        width = boundary
      else
        -- Left: text flows on the right, indent = boundary
        if hang_mode then
          if boundary > max_indent then max_indent = boundary end
          boundary = max_indent
        end
        indent = boundary
        width = hsize_pt - boundary
      end
      if width < 0 then width = 0 end
      if indent < 0 then indent = 0 end
      par_lines_flat[#par_lines_flat + 1] = indent
      par_lines_flat[#par_lines_flat + 1] = width
      par_n = par_n + 1
    end
  end

  -- Sentinel: full-width line after wrapping ends
  par_lines_flat[#par_lines_flat + 1] = 0
  par_lines_flat[#par_lines_flat + 1] = hsize_pt
  par_n = par_n + 1

  local line_parts = {}
  for i = 1, par_n do
    local idx = (i - 1) * 2 + 1
    line_parts[#line_parts + 1] = string.format("%.1f", par_lines_flat[idx]) .. "pt " .. string.format("%.1f", par_lines_flat[idx + 1]) .. "pt"
  end
  local parshape_str = "\\parshape " .. par_n .. " " .. table.concat(line_parts, " ")

  return par_n, par_lines_flat, parshape_str
end

--[doc]
-- \subsubsection*{\texttt{wr\_build\_image\_box}}
--
-- Constructs the \verb|\rlap| overlay command that places the image
-- inside the reflowed paragraph. The image is \verb|\smash|ed so it
-- contributes no vertical space; horizontal offset aligns it with
-- the contour.
-- 
-- For \texttt{position=middle} the image is centred; for
-- \texttt{left}/\texttt{right} it shifts relative to the contour
-- bounds. Compass-point anchors (\texttt{nw}, \texttt{ne},
-- \texttt{sw}, \texttt{se}) position the image relative to the
-- text area corners using \verb|\dimexpr| arithmetic.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{position}, \texttt{anchor} --- placement parameters
-- \item \texttt{geom} --- geometry table
-- \item \texttt{contour}, \texttt{sf} --- contour and scale factor
-- \end{itemize}
-- \textbf{Output:} \texttt{imbox} --- the \LaTeX{} command string for
-- image placement
--[/doc]
local function wr_build_image_box(position, anchor, geom, contour, sf, skip_count)
  local fmt4 = "%.4f"
  local first_indent = wr_indent_for_line(0, position, geom, contour, sf)
  local rlap_indent = (geom.shifty_pt >= 0) and 0 or first_indent

  local hpos
  if anchor == "here" then
    if position == "middle" then
      local co = (geom.hsize_pt - geom.img_w_pt) / 2
      hpos = "\\hskip " .. string.format(fmt4, co + geom.shiftx_pt - rlap_indent) .. "pt"
    elseif position == "right" then
      hpos = "\\hskip " .. string.format(fmt4, geom.hsize_pt - geom.gg_max_x + geom.shiftx_pt - rlap_indent) .. "pt"
    else
      hpos = "\\hskip " .. string.format(fmt4, -geom.gg_min_x + geom.shiftx_pt - ((skip_count == 0) and first_indent or 0)) .. "pt"
    end
  elseif anchor == "nw" or anchor == "sw" then
    hpos = "\\hskip " .. string.format(fmt4, geom.shiftx_pt - rlap_indent) .. "pt"
  else
    hpos = "\\hskip \\dimexpr \\textwidth-\\wd\\wr@imagebox" .. string.format("%+.4f", geom.shiftx_pt - rlap_indent) .. "pt\\relax"
  end

  local vpos
  if anchor == "here" then
    -- vpos = "\\raisebox{" .. string.format(fmt4, geom.shifty_pt) .. "pt}{\\smash{\\usebox{\\csname wr@imagebox\\endcsname}}}"
    vpos = "\\smash{\\raisebox{" .. string.format(fmt4, geom.bskip_pt - geom.shifty_pt) .. "pt}{\\usebox{\\csname wr@imagebox\\endcsname}}}"
  elseif anchor == "nw" or anchor == "ne" then
    vpos = "\\raisebox{\\dimexpr \\pagetotal-\\ht\\wr@imagebox" .. string.format("%+.4f", -geom.shifty_pt) .. "pt\\relax}{\\usebox{\\csname wr@imagebox\\endcsname}}"
  else
    vpos = "\\raisebox{\\dimexpr \\pagetotal-\\textheight" .. string.format("%+.4f", -geom.shifty_pt) .. "pt\\relax}{\\usebox{\\csname wr@imagebox\\endcsname}}"
  end

  return "\\rlap{" .. hpos .. " " .. vpos .. "}"
end

--[doc]
-- \subsubsection*{\texttt{wr\_build\_contour\_overlay}}
--
-- Appends a PDF literal stroke of the contour path to the image
-- placement command. When \texttt{contour} is enabled, the traced
-- path is drawn on top of the image. The colour is resolved via
-- xcolor's \verb|\color| command, so any named colour defined with
-- \verb|\definecolor| or any built-in xcolor name works.
-- 
-- The path uses the same scaling $s$ as the image and is placed
-- with a $y$-flip so it aligns exactly.
-- 
-- \textbf{Input:}
-- \begin{itemize}
-- \item \texttt{imbox} --- current image placement command string
-- \item \texttt{contour}, \texttt{sf} --- contour and scale factor
-- \item \texttt{position} --- \texttt{"left"}, \texttt{"right"}, or \texttt{"middle"}
-- \item \texttt{contour\_val} --- colour name or \texttt{"false"}
-- \item \texttt{geom} --- geometry table
-- \end{itemize}
-- \textbf{Output:} modified \texttt{imbox} with the PDF overlay appended
--
-- The horizontal and vertical placement uses the same formulas as
-- \texttt{wr\_build\_image\_box} so the contour stroke aligns exactly
-- with the image.
--[/doc]
local function wr_build_contour_overlay(imbox, contour, sf, position, contour_val, geom, skip_count)
  local fmt4 = "%.4f"
  local first_indent = wr_indent_for_line(0, position, geom, contour, sf)
  local rlap_indent = (geom.shifty_pt >= 0) and 0 or first_indent

  local pdf_cmds = {}
  for i, pt in ipairs(contour) do
    local x = pt[1] * sf
    local y = -(pt[2] * sf)
    if i == 1 then
      pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f m", x, y)
    else
      pdf_cmds[#pdf_cmds + 1] = string.format("%.1f %.1f l", x, y)
    end
  end
  pdf_cmds[#pdf_cmds + 1] = "h S"
  local pdf_path = "0.5 w " .. table.concat(pdf_cmds, " ")
  local color_prefix = "{\\color{" .. contour_val .. "}"
  local color_suffix = "}"

  local hpos
  if position == "middle" then
    local co = (geom.hsize_pt - geom.img_w_pt) / 2
    hpos = "\\hskip " .. string.format(fmt4, co + geom.shiftx_pt - rlap_indent) .. "pt"
  elseif position == "right" then
    hpos = "\\hskip " .. string.format(fmt4, geom.hsize_pt - geom.gg_max_x + geom.shiftx_pt - rlap_indent) .. "pt"
  else
    hpos = "\\hskip " .. string.format(fmt4, -geom.gg_min_x + geom.shiftx_pt - ((skip_count == 0) and first_indent or 0)) .. "pt"
  end

  local vpos = "\\smash{\\raisebox{" .. string.format(fmt4, geom.bskip_pt - geom.shifty_pt) .. "pt}{"

  imbox = imbox
    .. "\\rlap{" .. hpos .. " " .. vpos
    .. color_prefix .. "\\special{pdf: literal direct {q " .. pdf_path .. " Q}}" .. color_suffix
    .. "}}}"
  return imbox
end

--[doc]
-- \subsection*{\texttt{wrapgraphics\_run}}
--
-- Main entry point, called once per \verb|\wrapgraphics| invocation
-- from \verb|\directlua|. Orchestrates the full pipeline:
-- \begin{enumerate}
-- \item Read \TeX{} parameters and set up the verbose logger.
-- \item Locate \texttt{wrapgraphics.py} (\texttt{wr\_find\_pyscript})
-- and either validate the cached SVG or run the Python backend
-- (\texttt{wr\_svg\_matches\_params}, \texttt{wr\_run\_python}).
-- \item Parse the contour from the SVG (\texttt{wr\_parse\_svg}).
-- \item Compute the pixel--point scale factor $s$
-- (\texttt{wr\_compute\_scale}) and contour bounding box
-- (\texttt{wr\_contour\_bounds}).
-- \item Build the geometry parameter table.
-- \item Compute the number of wrapped lines and clamp to page fit.
-- \item Build the \texttt{\string\parshape} array
-- (\texttt{wr\_build\_parshape}).
-- \item Build the image placement box
-- (\texttt{wr\_build\_image\_box}) and, if requested, the
-- contour PDF overlay (\texttt{wr\_build\_contour\_overlay}).
-- \item Store the remaining shape state in \texttt{wr\_remaining}
-- for page-spanning support and print the result into the
-- \TeX{} stream.
-- \end{enumerate}
-- 
-- \textbf{Input:} none (reads \texttt{tex.wr\_*} variables set by the
-- \textsf{wrapgraphics} \LaTeX{} package)
-- \textbf{Output:} none (writes \texttt{\string\parshape} and image
-- placement into the \TeX{} stream via \texttt{tex.print})
--[/doc]
function wrapgraphics_run()
  wr_verbose = tex.wr_verbose == "true"
  texio.write("term and log", "[wrapgraphics] processing " .. tex.wr_filepath .. " (position=" .. tex.wr_position .. ") ")

  local img = tex.wr_filepath
  local out = img .. "-shape.svg"
  local thr = tex.wr_threshold
  local pad = tex.wr_padding
  local smo = tex.wr_smooth

  local pyscript = wr_find_pyscript(img)
  if not pyscript then
    tex.print("\\PackageError{wrapgraphics}{Cannot find wrapgraphics.py}{}")
    return
  end

  if wr_svg_matches_params(out, thr, pad, smo) then
    dbg("cached SVG matches params, skipping Python")
  else
    wr_run_python(pyscript, img, out, thr, pad, smo)
  end

  local ok, shape = pcall(wr_parse_svg, out)
  if not ok or not shape then
    tex.print("\\PackageError{wrapgraphics}{Failed to load shape file}{}")
    return
  end

  local position = tex.wr_position
  if shape.invert and position == "left" then position = "right" end
  local anchor = tex.wr_anchor or "here"
  local shiftx_str = tex.wr_shiftx or "0pt"
  local shifty_str = tex.wr_shifty or "0pt"
  local shiftx_pt = tonumber(shiftx_str:match("(-?[0-9.]+)")) or 0
  local shifty_pt = tonumber(shifty_str:match("(-?[0-9.]+)")) or 0

  dbg("image=" .. img .. " " .. shape.width .. "x" .. shape.height .. " dpi=" .. shape.dpi)
  dbg("contour: " .. #shape.contour .. " points, invert=" .. tostring(shape.invert))
  dbg("params: threshold=" .. thr .. " padding=" .. pad .. " smooth=" .. smo .. " scale=" .. tex.wr_scale .. " position=" .. position)

  if next(shape.contour) == nil then
    dbg("empty contour -- no wrapping")
    if position == "right" then
      tex.print("\\noindent{\\hfill\\usebox{\\csname wr@imagebox\\endcsname}}")
    else
      tex.print("\\noindent\\usebox{\\csname wr@imagebox\\endcsname}")
    end
    return
  end

  local sf = wr_compute_scale(tex.wr_scale, tex.wr_width, shape)
  dbg("scale=" .. (tonumber(tex.wr_scale) or "nil") .. " sf=" .. string.format("%.6f", sf))

  local bounds = wr_contour_bounds(shape.contour, sf)

  local img_w_pt = shape.width * sf
  local img_h_pt = shape.height * sf
  local hsize_pt = tex.hsize / 65536
  local first_contour_y = bounds.min_y_pt
  local bskip_pt = tex.baselineskip.width / 65536
  if bskip_pt <= 0 then bskip_pt = 12 end

  local geom = {
    img_w_pt      = img_w_pt,
    img_h_pt      = img_h_pt,
    hsize_pt      = hsize_pt,
    bskip_pt      = bskip_pt,
    first_contour_y = first_contour_y,
    gg_min_x      = bounds.min_x_pt,
    gg_max_x      = bounds.max_x_pt,
    gg_max_y_pt   = bounds.max_y_pt,
    shiftx_pt     = shiftx_pt,
    shifty_pt     = shifty_pt,
  }

  local effective_h = bounds.max_y_pt + shifty_pt
  local num_lines
  if effective_h <= 0 then
    num_lines = 0
  else
    num_lines = math.ceil(effective_h / bskip_pt) + 2
  end
  local lines_override = tex.wr_lines
  if lines_override ~= "" then
    local n = tonumber(lines_override)
    if n then
      if n < 0 then
        num_lines = math.max(0, num_lines + n)
      else
        num_lines = n
      end
    end
  end
  local skip_count = tonumber(tex.wr_skip) or 0
  local hang_mode = tex.wr_hang == "true"

  local pagetotal_pt = tex.pagetotal / 65536
  local vsize_pt = tex.vsize / 65536
  local max_fit = math.max(2, math.floor((vsize_pt - pagetotal_pt - 0.5 * bskip_pt) / bskip_pt))
  num_lines = math.max(0, math.min(num_lines, max_fit - 1))

  local par_n, par_lines_flat, parshape_str = wr_build_parshape(
    skip_count, hsize_pt, position, num_lines, hang_mode, geom, shape.contour, sf)

  local imbox = wr_build_image_box(position, anchor, geom, shape.contour, sf, skip_count)

  local contour_val = tex.wr_contour
  if contour_val ~= "false" and contour_val ~= "" then
    imbox = wr_build_contour_overlay(imbox, shape.contour, sf, position, contour_val, geom, skip_count)
  end

  dbg("gg_min_x=" .. string.format("%.4f", bounds.min_x_pt) .. " gg_max_x=" .. string.format("%.4f", bounds.max_x_pt)
    .. " px:" .. bounds.min_x_px .. ".." .. bounds.max_x_px)
  dbg("first_contour_y=" .. string.format("%.4f", first_contour_y) .. " img_w=" .. string.format("%.2f", img_w_pt)
    .. " img_h=" .. string.format("%.2f", img_h_pt) .. " hsize=" .. string.format("%.2f", hsize_pt))
  dbg("bskip=" .. string.format("%.2f", bskip_pt) .. " num_lines=" .. par_n
    .. " first_indent=" .. string.format("%.4f", wr_indent_for_line(0, position, geom, shape.contour, sf)))
  dbg("imbox=" .. imbox)
  dbg("parshape=" .. parshape_str)

  wr_remaining = {
    lines = par_lines_flat,
    total = par_n,
    used = 0,
    bskip = bskip_pt,
    img_h = bounds.max_y_pt + shifty_pt,
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
