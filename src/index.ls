module.exports =
  pkg:
    name: 'usmapadv', version: '0.0.1'
    # lite: 不帶 d3 的 base. 補間用 chart.anim, 可以逐格錄影
    extend: {name: "@makechart/base", path: "lite/index.html"}
    # 地圖檔是 topojson, 已投影成平面座標 ( tool/map.js ). 其餘 ( 變形、立體、泡泡 ) 都自己算
    dependencies: [
    * name: \topojson-client, version: "3.1.0", path: "dist/topojson-client.min.js", async: false
    ]
    i18n:
      "zh-TW":
        "state": "州"
        "county": "郡"
        "value": "數值"
        "size": "大小"
        "category": "分類"
        "proportion": "比例"
        "aggregated": "郡匯總"
  init: ({root, context, t, pubsub, data, manager}) ->
    mod {context, t, data, manager, cls: @_instance.block}
      .then (m) -> pubsub.fire \init, mod: m .then ~> it.0

# ---------------------------------------------------------------- 幾何
svgns = "http://www.w3.org/2000/svg"
tau = Math.PI * 2
mk = (p, tag, cls) ->
  n = document.createElementNS svgns, tag
  if cls => n.setAttribute \class, cls
  p.appendChild n
  n

# ring 是頭尾相同的封閉點列 ( GeoJSON ). 有號面積 ( shoelace ) 與重心
ring-area = (r) ->
  s = 0
  for i from 0 til r.length - 1 => s += r[i].0 * r[i + 1].1 - r[i + 1].0 * r[i].1
  s / 2

ring-centroid = (r) ->
  [a, cx, cy] = [0, 0, 0]
  for i from 0 til r.length - 1
    [x0, y0] = r[i]
    [x1, y1] = r[i + 1]
    k = x0 * y1 - x1 * y0
    a += k
    cx += (x0 + x1) * k
    cy += (y0 + y1) * k
  if !a => return (r.0 or [0, 0]).slice!
  [cx / (3 * a), cy / (3 * a)]

# polys: [ [外框, 洞...] ... ]. 面積扣掉洞; label 放在最大那塊的重心
metrics = (polys) ->
  [area, cx, cy, best, best-a] = [0, 0, 0, null, 0]
  for poly in polys
    for ring, j in poly
      if ring.length < 4 => continue
      a = Math.abs ring-area ring
      c = ring-centroid ring
      w = if j == 0 => a else -a
      area += w
      cx += c.0 * w
      cy += c.1 * w
      if j == 0 and a > best-a => [best, best-a] = [c, a]
  best = best or [0, 0]
  {area: area >? 0, c: (if area > 0 => [cx / area, cy / area] else best), label: best}

clone = (polys) -> polys.map (p) -> p.map (r) -> r.map (q) -> [q.0, q.1]

each-point = (polys, cb) -> for p in polys => for r in p => for q in r => cb q

# 連續型 cartogram ( Dougenik, Chrisman & Niemeyer 1985 ).
# 每個點的位移只跟它的位置有關, 所以共用的邊在兩邊會移到同一個地方, 地圖不會裂開;
# 也因此村里、縣界只要跟著同一組力場移動, 就會與鄉鎮對齊.
#  - units: [{polys, v}], v 是目標面積的比例. 沒有值的不參與, 但會被推擠
#  - sets: 要跟著變形的所有 polys ( 包含 units 自己的 ). 直接改座標
cartogram = (units, sets, iter = 15) ->
  # 簡化時消失 ( 面積 0 ) 的不算: 它的面積誤差是無限大, 會把整體的力量縮減到 0, 地圖完全不動
  valid = units.filter -> it.v? and isFinite(it.v) and metrics(it.polys).area > 0
  if valid.length < 2 => return
  pts = []
  for s in sets => each-point s, (q) -> pts.push q
  for k from 0 til iter
    ms = valid.map (u) -> {m: metrics(u.polys), v: (u.v >? 0)}
    ta = ms.reduce ((a, b) -> a + b.m.area), 0
    tv = ms.reduce ((a, b) -> a + b.v), 0
    if !(tv > 0) => return
    err = 0
    fs = ms.map ({m, v}) ->
      d = (ta * v / tv) >? (ta * 1e-4)
      a = m.area >? 1e-9
      err += (a >? d) / (a <? d)
      r = Math.sqrt(a / Math.PI)
      {x: m.c.0, y: m.c.1, r, f: Math.sqrt(d / Math.PI) - r}
    frf = 1 / (1 + err / fs.length)
    for q in pts
      [dx, dy] = [0, 0]
      for c in fs
        ex = q.0 - c.x
        ey = q.1 - c.y
        d = Math.sqrt(ex * ex + ey * ey)
        if d < 1e-9 => continue
        f = if d > c.r => c.f * c.r / d else c.f * (d * d / (c.r * c.r)) * (4 - 3 * d / c.r)
        dx += f * ex / d
        dy += f * ey / d
      q.0 += frf * dx
      q.1 += frf * dy

# 泡泡排開 ( Dorling ). 往各自的中心拉, 互相不重疊. 固定次數, 沒有亂數, 結果可重現
relax = (nodes, pad = 0, iter = 160) ->
  for k from 0 til iter + 120
    a = if k < iter => 0.12 * (1 - k / iter) else 0
    if a => for n in nodes => n.x += (n.tx - n.x) * a; n.y += (n.ty - n.y) * a
    for i from 0 til nodes.length
      p = nodes[i]
      for j from i + 1 til nodes.length
        q = nodes[j]
        dx = q.x - p.x
        dy = q.y - p.y
        m = p.r + q.r + pad
        if Math.abs(dx) >= m or Math.abs(dy) >= m => continue
        d = Math.sqrt(dx * dx + dy * dy)
        if d >= m => continue
        if d < 1e-6 => [dx, dy, d] = [1e-3 * (j - i), 0, 1e-3 * (j - i)]
        o = (m - d) / d
        # 大的移得少
        w = (q.r * q.r) / (p.r * p.r + q.r * q.r)
        p.x -= dx * o * w
        p.y -= dy * o * w
        q.x += dx * o * (1 - w)
        q.y += dy * o * (1 - w)
  nodes

# 圓餅的各片. 角度從 12 點鐘起算、順時針 ( rad ).
#  - desc: 由大到小, 從 12 點鐘開始
#  - side: 每片有自己的方位 - 第 1 片左、第 2 片右, 其餘依序上、下交錯 ( 上的多一片 ):
#    2 片「左右」, 3 片「左右上」, 4 片「左右上下」, 5 片「左右上上下」.
#    各片照方位排成一圈後, 整圈轉到各片中心最接近自己方位的角度. 兩片時剛好一左一右對稱,
#    分界線偏離垂直的程度就是兩者的差距
pie-arcs = (vs, order) ->
  vs = vs.map -> if isFinite(it) and it > 0 => it else 0
  tot = vs.reduce ((a, b) -> a + b), 0
  if !(tot > 0) => return []
  n = vs.length
  if order == \desc or n < 2 =>
    a = 0
    return [0 til n]
      .sort (i, j) -> (vs[j] - vs[i]) or (i - j)
      .map (i) ->
        w = tau * vs[i] / tot
        ret = {i, a0: a, a1: a + w}
        a += w
        ret
  rest = [2 til n]
  tops = rest.slice 0, Math.ceil(rest.length / 2)
  bottoms = rest.slice tops.length
  seq = tops ++ [1] ++ bottoms ++ [0]
  anchor = (i) -> if i == 0 => tau * 3 / 4 else if i == 1 => tau / 4 else if i in tops => 0 else tau / 2
  cum = 0
  [sx, sy] = [0, 0]
  ws = seq.map (i) ->
    w = tau * vs[i] / tot
    d = anchor(i) - (cum + w / 2)
    sx += Math.cos d
    sy += Math.sin d
    cum += w
    w
  phi = Math.atan2 sy, sx
  a = phi
  seq.map (i, k) ->
    ret = {i, a0: a, a1: a + ws[k]}
    a += ws[k]
    ret

wedge = (cx, cy, r, a0, a1) ->
  if a1 - a0 >= tau - 1e-6 =>
    return "M#{cx},#{cy - r}A#r,#r 0 1 1 #{cx},#{cy + r}A#r,#r 0 1 1 #{cx},#{cy - r}Z"
  p = (a) -> [cx + r * Math.sin(a), cy - r * Math.cos(a)]
  [x0, y0] = p a0
  [x1, y1] = p a1
  "M#cx,#{cy}L#x0,#{y0}A#r,#r 0 #{if a1 - a0 > Math.PI => 1 else 0} 1 #x1,#y1 Z"

# ---------------------------------------------------------------- 顏色
# 一律轉成 [r, g, b] 再內插 ( 補間也認得 rgb() )
to-rgb = (c, ldcolor) ->
  c = c.value or c
  if typeof(c) == \string and m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec c.trim! =>
    h = m.1
    if h.length == 3 => h = h.split('').map(-> it + it).join('')
    return [0 1 2].map (i) -> parseInt h.substr(i * 2, 2), 16
  try
    o = ldcolor.rgb c
    return [o.r, o.g, o.b].map -> Math.round it
  catch e
    return [128, 128, 128]
rgb-str = (c, k = 1) -> "rgb(#{c.map(-> Math.round(it * k) >? 0 <? 255).join(',')})"
ramp = (cs) -> (t) ->
  if !(cs and cs.length) => return [200, 200, 200]
  if cs.length == 1 => return cs.0
  t = (if isNaN(t) => 0 else t) >? 0 <? 1
  x = t * (cs.length - 1)
  i = Math.floor(x) <? (cs.length - 2)
  f = x - i
  [0 1 2].map (k) -> cs[i][k] + (cs[i + 1][k] - cs[i][k]) * f

# 分位數: 值 -> 名次 ( 0 ~ 1, 相鄰兩值之間線性內插, 相同的值取中間 ), 與反函式.
# vs 已排序
rank = (vs) -> (x) ->
  n = vs.length
  if n < 2 => return 0.5
  if x <= vs.0 => return 0
  if x >= vs[n - 1] => return 1
  [lo, hi] = [0, n - 1]
  while hi - lo > 1
    m = (lo + hi) .>>. 1
    if vs[m] <= x => lo = m else hi = m
  # 同值的區段取中間
  a = lo
  while a > 0 and vs[a - 1] == vs[lo] => a--
  b = lo
  while b < n - 1 and vs[b + 1] == vs[lo] => b++
  i = if vs[lo] == x => (a + b) / 2 else lo + (x - vs[lo]) / ((vs[lo + 1] - vs[lo]) or 1)
  i / (n - 1)
unrank = (vs) -> (t) ->
  n = vs.length
  if !n => return 0
  x = (t >? 0 <? 1) * (n - 1)
  i = Math.floor(x) <? (n - 2) >? 0
  if n == 1 => return vs.0
  vs[i] + (vs[i + 1] - vs[i]) * (x - i)

palettes =
  sequential: {name: "orange", colors: <[#fff5eb #fdd0a2 #fd8d3c #d94801 #7f2704]>}
  diverging: {name: "rdbu", colors: <[#2166ac #67a9cf #f7f7f7 #ef8a62 #b2182b]>}


# 下層的列寫這些字 ( 或空白 ) 就代表整個上層
town-words = <[total all statewide 全區 全部 總計 合計 小計]>

# ---------------------------------------------------------------- 地圖 ( 與 twmapadv 不同的部分 )
# 名稱比對: 小寫、去掉重音與標點 ( Doña Ana, St. Louis ). county 另外認得去掉 County / Parish 等字尾的寫法
norm = (s) ->
  "#{if s? => s else ''}".normalize(\NFD).replace(/[̀-ͯ]/g, '').toLowerCase!
    .replace(/[.'’]/g, '').replace(/\s+/g, ' ').trim!
suffix = /\s+(county|parish|borough|census area|city and borough|municipality|municipio|planning region)$/
strip = (s) -> norm(s).replace suffix, ''

# county 名稱的索引. 同名的 county 與 city ( Baltimore County / Baltimore city ) 不帶字尾時算 county;
# 只有 city 的 ( Norfolk city ) 不帶字尾也認得
county-index = (list) ->
  by = {}
  for f in list
    by[norm f.full] = f
    if suffix.test(norm f.full) => by[strip f.full] = f
  for f in list => if !by[norm f.name] => by[norm f.name] = f
  by
# "Los Angeles County, California": 逗號後是州名
find-county = (by, s) -> by[norm s] or by[strip s] or (if /,/.test(s) => find-county(by, s.replace(/,.*$/, '')) else null)

# 地圖檔 ( tool/map.js 產生, 已投影成平面座標 ) 與範例資料跟著 block 發佈, 網址照 registry 的規則組
# ( 沙盒裡是靜態網域 )
get-json = (manager, cls, path) ->
  url = manager.get-url {ns: cls.ns, name: cls.name, version: cls.version, path, type: \json}
  fetch url .then (r) -> if r.ok => r.json! else Promise.reject new Error("#{r.status} #url")

# level -> 地圖. 程式裡上層一律叫 town、下層 village ( 與 twmapadv 相同, 之後抽共用 block 時這裡就是介面 ):
#  - nation ( 預設 ): 州 > county, map/nation.json. 阿拉斯加、夏威夷、波多黎各在左下
#  - state/<州>: 該州的 county, 只有一層, map/state/<USPS>.json. 州可以是縮寫、州名或 2 碼 FIPS
# 回傳 towns / villages ( {code, level, town, village, full, abbr, polys, tcode} ), 上層合併成的外框,
# 與資料的名稱 / 代碼 -> 單位的 upper(s) / lower(上層, s)
load-geo = ({manager, cls, topojson, level}) ->
  national = !/^state\//.test(level)
  index <- get-json(manager, cls, "map/index.json").then _
  state = null
  if !national =>
    k = level.split('/').1 or ''
    state = index.states.find (s) -> s.code == k.padStart(2, '0') or s.usps == k.toUpperCase! or norm(s.name) == norm(k)
    if !state => return Promise.reject new Error("[usmapadv] unknown state in level: #level")
  topo <- get-json(manager, cls, if national => "map/nation.json" else "map/state/#{state.usps}.json").then _
  read = (obj) -> topojson.feature(topo, topo.objects[obj]).features.map (f) ->
    g = f.geometry or {}
    polys = if g.type == \Polygon => [g.coordinates] else if g.type == \MultiPolygon => g.coordinates else []
    {p: f.properties, polys}
  if national =>
    states = read \state
    sname = Object.fromEntries states.map ({p}) -> [p.code, p.name]
    towns = states.map ({p, polys}) -> {code: p.code, level: \town, town: p.name, village: '', abbr: p.usps, polys, tcode: p.code}
    villages = read(\county).map ({p, polys}) ->
      {code: p.code, level: \village, town: sname[p.state], village: p.name, full: p.full, polys, tcode: p.state}
  else
    towns = read(\county).map ({p, polys}) -> {code: p.code, level: \town, town: p.name, village: '', full: p.full, polys, tcode: p.code}
    villages = []
  m = topojson.merge topo, topo.objects[if national => \state else \county].geometries
  outline = if m.type == \Polygon => [m.coordinates] else m.coordinates
  feat = {}
  for f in towns ++ villages => feat[f.code] = f
  # 代碼可能被當成數字讀進來 ( 6037 -> 06037 )
  code = (s, n) -> if /^\d+$/.test(s) => feat[s.padStart(n, '0')] else null
  if national =>
    sby = {}
    for t in towns => sby[norm t.town] = sby[norm t.abbr] = t
    cby = {}
    for t in towns => cby[t.code] = county-index villages.filter (v) -> v.tcode == t.code
    lower = (t, s) ->
      s = "#{if s? => s else ''}".trim!
      if (f = code s, 5) => return (if f.tcode == t.code => f else null)
      find-county cby[t.code], s
    upper = (s) ->
      s = "#{if s? => s else ''}".trim!
      if /^\d+$/.test(s) => return code(s, if s.length <= 2 => 2 else 5)
      if sby[norm s] => return that
      # 只有一欄的 "<county>, <州>"
      if (r = /^(.*),\s*([^,]+)$/.exec s) and (t = sby[norm r.2]) => lower t, r.1 else null
  else
    by = county-index towns
    upper = (s) ->
      s = "#{if s? => s else ''}".trim!
      code(s, 5) or find-county(by, s)
    lower = -> null
  {national, state, towns, villages, outline, upper, lower}

mod = ({context, t, data, manager, cls}) ->
  {chart, ldcolor, topojson} = context
  {format, anim: {join}} = chart.utils
  t = t or (-> it)
  level = data.level or \nation
  {national, state, towns, villages, outline, upper, lower} <- load-geo({manager, cls, topojson, level}).then _
  # 範圍不含遠方的小島 ( 例如阿拉斯加州圖的阿留申群島西端以外 ), 全部框進來主體會縮成一點.
  # 主體 = 佔外框面積 1% 以上的區塊; 離主體的範圍超過它對角線兩倍的不算 ( 全國圖的插圖仍在範圍內 ).
  # 範圍外的照畫, 由 view 的裁切擋掉 ( overflow )
  oa = (p) -> Math.abs ring-area(p.0)
  total = outline.reduce ((a, p) -> a + oa(p)), 0
  bb = (ps) ->
    b = [Infinity, Infinity, -Infinity, -Infinity]
    each-point ps, (q) -> b := [b.0 <? q.0, b.1 <? q.1, b.2 >? q.0, b.3 >? q.1]
    b
  B = bb outline.filter (p) -> oa(p) >= total * 0.01
  D = Math.hypot(B.2 - B.0, B.3 - B.1)
  main = outline.filter (p) ->
    c = bb [p]
    dx = (B.0 - c.2) >? (c.0 - B.2) >? 0
    dy = (B.1 - c.3) >? (c.1 - B.3) >? 0
    Math.hypot(dx, dy) <= D * 2
  [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity]
  each-point main, (q) ->
    x0 := x0 <? q.0
    y0 := y0 <? q.1
    x1 := x1 >? q.0
    y1 := y1 >? q.1
  overflow = main.length < outline.length
  k = 1000 / ((x1 - x0) or 1)
  for f in towns ++ villages ++ [{polys: outline}] => each-point f.polys, (q) ->
    q.0 = (q.0 - x0) * k
    q.1 = (q.1 - y0) * k
  W = 1000
  H = (y1 - y0) * k
  for f in towns ++ villages => f <<< metrics(f.polys)
  vill-of = {}
  for v in villages => vill-of[][v.tcode].push v
  feat = {}
  for f in towns ++ villages => feat[f.code] = f
  geo = {towns, villages, outline, main, overflow, W, H, vill-of, feat, national}

  # 範例資料 ( dist/sample/nation.json, 由 tool/sample.js 產生 ), 用到才載入. 州圖只取該州的 county
  sample: ->
    get-json manager, cls, "sample/nation.json"
      .catch (e) ->
        console.warn "[usmapadv] sample data not found:", e
        {head: [], units: {}, rows: []}
      .then ({head, units, rows}) ->
        if !national =>
          rows = rows.filter((r) -> r.1 and norm(r.0) == norm(state.name)).map (r) -> r.slice 1
          head = head.slice 1
        raw: rows.map (r) -> Object.fromEntries head.map (h, i) -> [h, r[i]]
        binding: {
          town: {key: head.0}
          value: {key: '65+ %', unit: units['65+ %']}
          size: {key: \population, unit: units.population}
          cat: {key: '65+ share'}
          parts: [{key: \male, unit: units.male}, {key: \female, unit: units.female}]
        } <<< (if national => {village: {key: head.1}} else {})

  config: chart.utils.config.from({
    preset: \default
    tip: \tip
  }) <<< {
    # 地圖 / 變形地圖 ( cartogram, 面積依「大小」) / 泡泡 ( dorling )
    mode: type: \choice, values: <[map cartogram bubble]>, default: \map, desc: {en: "map: regions as they are; cartogram: regions resized by size; bubble: a circle per region sized by size", "zh-TW": "map：原本的地圖；cartogram：依「大小」變形各區的面積；bubble：每區一個依「大小」縮放的泡泡"}
    # 顏色依什麼: auto = 有「數值」用數值, 否則用分類
    color-by: type: \choice, values: <[auto value cat]>, default: \auto, desc: {en: "what colors the regions: value, cat ( category ), or auto: value when bound, otherwise category", "zh-TW": "區塊依什麼上色：value 數值、cat 分類；auto 有綁數值就用數值，否則用分類"}
    heat:
      # sequential: 由小到大; diverging: 雙極, 中點兩側各用一種顏色
      mode: type: \choice, values: <[sequential diverging]>, default: \sequential, desc: {en: "sequential: one ramp from low to high; diverging: two colors on either side of a center value", "zh-TW": "sequential：由低到高一條色階；diverging：以中點分成兩側，各用一種顏色"}
      # quantile: 依名次 ( 分位數 ), 偏斜的資料也會均勻用到整條色階
      scale: type: \choice, values: <[linear log pow quantile]>, default: \linear, desc: {en: "how values map to colors; quantile uses ranks, so skewed data still spreads over the whole ramp", "zh-TW": "數值對應到顏色的方式；quantile 依名次，偏斜的資料也會用到整條色階"}
      exponent: type: \number, default: 0.5, min: 0.1, max: 5, step: 0.1, desc: {en: "exponent of the pow scale", "zh-TW": "pow 色階的指數"}
      # 雙極的中點: 中位數 / 平均 / 手動指定
      center:
        mode: type: \choice, values: <[median mean manual]>, default: \median, desc: {en: "center of the diverging colors: the median, the mean, or the value below ( manual )", "zh-TW": "雙極色階的中點：中位數、平均，或用下面指定的值 ( manual )"}
        value: type: \number, default: 0, desc: {en: "center value when the center mode is manual", "zh-TW": "中點設為 manual 時的中點數值"}
      # 兩側用同樣的距離, 這樣同樣深的顏色代表離中點一樣遠
      symmetric: type: \boolean, default: true, desc: {en: "use the same distance on both sides of the center, so equal shades mean equally far from it", "zh-TW": "中點兩側用相同的距離，同樣深的顏色代表離中點一樣遠"}
      # 0 = 連續; 大於 1 時切成幾級
      steps: type: \number, default: 0, min: 0, max: 12, step: 1, desc: {en: "number of color classes; 0 keeps the colors continuous", "zh-TW": "色階分成幾級；0 表示連續"}
      sequential: type: \palette, default: palettes.sequential, desc: {en: "colors used in sequential mode", "zh-TW": "sequential 模式用的色票"}
      diverging: type: \palette, default: palettes.diverging, desc: {en: "colors used in diverging mode", "zh-TW": "diverging 模式用的色票"}
      empty: type: \color, default: \#e5e5e5, desc: {en: "color of regions without a value", "zh-TW": "沒有數值的區塊的顏色"}
    legend: {} <<< chart.utils.config.preset.legend <<< {
      format: type: \format, default: '.3s', desc: {en: "number format of the color scale labels", "zh-TW": "色條刻度的數值格式"}
    }
    village:
      # none: 只畫鄉鎮; click: 點鄉鎮展開村里 ( 資料沒有村里時不展開 ); all: 全部畫村里
      mode: type: \choice, values: <[click all none]>, default: \click, desc: {en: "click: click a state to show its counties; all: draw every county; none: states only. Only the nation map has counties under states", "zh-TW": "click：點州展開郡；all：全部畫郡；none：只畫州。只有全國圖的州底下有郡"}
      # 沒有「全區」列時, 鄉鎮值怎麼由村里算出來
      aggregate: type: \choice, values: <[sum mean none]>, default: \sum, desc: {en: "how a state's value is computed from its counties when the data has no row for the whole state", "zh-TW": "資料沒有州整體的列時，如何由郡算出州的值"}
      # level: 鄉鎮與村里各自一組色階 / 大小; shared: 共用
      domain: type: \choice, values: <[level shared]>, default: \level, desc: {en: "level: states and counties get separate color and size ranges; shared: one range for both", "zh-TW": "level：州與郡各自一組色階與大小範圍；shared：共用一組"}
      # click 模式下展開村里時, 放大到那個鄉鎮 ( 再點一次或點空白處還原 )
      zoom: type: \boolean, default: false, desc: {en: "in click mode, zoom into the expanded state", "zh-TW": "click 模式展開郡時，放大到那個州"}
    border:
      color: type: \color, default: \#fff
      width: type: \number, default: 1, min: 0, max: 20, step: 0.1, desc: {en: "width of the borders between regions ( states, or counties on a state map ) ( px )", "zh-TW": "區塊邊界的粗細 ( 州；州圖是郡 ) ( px )"}
      linejoin: type: \choice, values: <[round bevel miter]>, default: \round, desc: {en: "shape of the border corners", "zh-TW": "邊界轉角的形狀"}
      village:
        color: type: \color, default: \#fff
        width: type: \number, default: 0.4, min: 0, max: 20, step: 0.1, desc: {en: "width of the county borders under the states ( px )", "zh-TW": "州底下郡邊界的粗細 ( px )"}
    extrude:
      enabled: type: \boolean, default: false, desc: {en: "raise each region by its value into 3D columns ( not in bubble mode )", "zh-TW": "依數值把各區塊拉高成立體 ( 泡泡模式不適用 )"}
      # 最高的柱子是地圖寬的幾倍
      height: type: \number, default: 0.25, min: 0, max: 2, step: 0.01, desc: {en: "height of the tallest column, as a multiple of the map width", "zh-TW": "最高的柱子是地圖寬度的幾倍"}
      tilt: type: \number, default: 55, min: 0, max: 85, step: 1, desc: {en: "how far the 3D view leans back ( degrees ); 0 looks straight down", "zh-TW": "立體視角的傾斜角度 ( 度 )；0 是正上方往下看"}
      angle: type: \number, default: -20, min: -180, max: 180, step: 1, desc: {en: "starting rotation of the 3D map ( degrees )", "zh-TW": "立體地圖一開始的旋轉角度 ( 度 )"}
      # 旋轉: drag = 拖曳, auto = 自動轉, both = 自動轉, 也可以拖曳 ( 拖曳時暫停 )
      rotate: type: \choice, values: <[drag auto both none]>, default: \drag, desc: {en: "drag: rotate by dragging; auto: keep turning; both: keep turning and allow dragging", "zh-TW": "drag：拖曳旋轉；auto：自動旋轉；both：自動旋轉，也可以拖曳"}
      speed: type: \number, default: 12, min: -180, max: 180, step: 1, desc: {en: "auto rotation speed ( degrees per second ); negative turns the other way", "zh-TW": "自動旋轉的速度 ( 度 / 秒 )；負值反方向轉"}
      base:
        enabled: type: \boolean, default: true, desc: {en: "draw a plate under the 3D map", "zh-TW": "在立體地圖下方畫一塊底板"}
        color: type: \color, default: \#d8d8d8
      shade: type: \number, default: 0.25, min: 0, max: 1, step: 0.01, desc: {en: "how much darker the side walls are than the tops ( 0 to 1 )", "zh-TW": "側面比頂面暗多少 ( 0 到 1 )"}
    cartogram:
      iteration: type: \number, default: 15, min: 1, max: 60, step: 1, desc: {en: "rounds of distortion; more gets areas closer to their sizes but takes longer", "zh-TW": "變形的次數；越多面積越接近目標，但計算越久"}
    bubble:
      scale: type: \number, default: 1, min: 0.1, max: 4, step: 0.05, desc: {en: "multiplier on bubble size", "zh-TW": "泡泡大小的倍率"}
      overlap: type: \boolean, default: false, desc: {en: "let bubbles overlap and stay at their region centers, instead of pushing them apart", "zh-TW": "泡泡可以重疊並留在區塊中心，不互相推開"}
      padding: type: \number, default: 1, min: 0, max: 20, step: 0.5, desc: {en: "gap between bubbles when they don't overlap ( px )", "zh-TW": "泡泡不重疊時彼此的間距 ( px )"}
      # 不重疊時, 以虛線連到行政區中心
      leader: type: \boolean, default: true, desc: {en: "draw a dashed line from a moved bubble to its region center", "zh-TW": "泡泡被推開時，以虛線連到區塊中心"}
      leader-color: type: \color, default: \#999, desc: {en: "color of the dashed leader lines", "zh-TW": "連到區塊中心的虛線的顏色"}
      basemap: type: \boolean, default: true, desc: {en: "draw the region shapes under the bubbles", "zh-TW": "在泡泡底下畫出行政區的形狀"}
      basemap-color: type: \color, default: \#eeeeee, desc: {en: "fill color of the regions under the bubbles", "zh-TW": "泡泡底下行政區的填色"}
      stroke: type: \color, default: \#fff, desc: {en: "outline color of the bubbles", "zh-TW": "泡泡外框的顏色"}
      stroke-width: type: \number, default: 0.5, min: 0, max: 10, step: 0.1, desc: {en: "outline width of the bubbles ( px )", "zh-TW": "泡泡外框的粗細 ( px )"}
      # 比例 ( 圓餅 ): side = 依方位 ( 左右上下 ), desc = 由大到小從 12 點鐘起順時針
      pie: type: \choice, values: <[side desc none]>, default: \side, desc: {en: "with two or more proportion fields, draw bubbles as pies. side: slices by direction ( left, right, top ... ); desc: largest first from 12 o'clock; none: plain bubbles", "zh-TW": "綁定兩個以上「比例」欄位時把泡泡畫成圓餅。side：各片依方位 ( 左、右、上 ... ) 排；desc：由大到小從 12 點鐘起；none：不畫圓餅"}
    label:
      enabled: type: \boolean, default: true, desc: {en: "show region names", "zh-TW": "顯示行政區名稱"}
      village: type: \boolean, default: false, desc: {en: "also name the counties under the states", "zh-TW": "州底下的郡也標上名稱"}
      font: chart.utils.config.from({preset: \font})
      color: type: \color, default: \#222
      halo: type: \color, default: \#fff, desc: {en: "color of the outline around names, keeping them readable over the map", "zh-TW": "名稱外圍描邊的顏色，讓字在地圖上清楚"}
      fit: type: \boolean, default: true, desc: {en: "hide names that don't fit in their region", "zh-TW": "區塊放不下名稱時不標"}
      halo-width: type: \number, default: 2, min: 0, max: 10, step: 0.5, desc: {en: "width of the outline around names ( px )", "zh-TW": "名稱外圍描邊的粗細 ( px )"}
    # crossfilter 的單位: town = 上層 ( 州 ); village = 上層 + 下層 ( 州 + 郡 ). 值的名稱與 twmapadv 相同
    filter-level: type: \choice, values: <[town village]>, default: \town, desc: {en: "what a click selects for other charts: town = the state ( or county on a state map ), village = state and county", "zh-TW": "點選時對其他圖表篩選的單位：town 州 ( 州圖是郡 )，village 州加郡"}
  }

  # 段落 ( tab ) 的說明, key 是段落的路徑. preset 的段落由 chart.utils.config.tabinfo 掛上來, 共用的 common 由核心補
  tabinfo: chart.utils.config.tabinfo({tip: \tip, legend: \legend}) <<<
    legend: desc: {en: "the list of categories or fields, or the color bar when coloring by value", "zh-TW": "分類或欄位的清單，依數值上色時則是色條"}
    heat: desc: {en: "the color scale that turns values into region colors", "zh-TW": "把數值轉成區塊顏色的色階"}
    "heat/center": desc: {en: "the center value of the diverging color scale", "zh-TW": "雙極 ( diverging ) 色階的中點"}
    village: desc: {en: "how counties are shown under the states, and how state values come from them", "zh-TW": "州底下郡的顯示方式，以及州的數值如何由郡計算"}
    border: desc: {en: "the borders between regions", "zh-TW": "區塊之間的邊界"}
    "border/village": desc: {en: "the borders between counties under the states", "zh-TW": "州底下郡之間的邊界"}
    extrude: desc: {en: "raise regions into 3D columns by value, and how the 3D view is turned", "zh-TW": "依數值把區塊拉成立體柱，以及立體視角的轉動"}
    "extrude/base": desc: {en: "the plate under the 3D map", "zh-TW": "立體地圖下方的底板"}
    cartogram: desc: {en: "how regions are distorted in cartogram mode", "zh-TW": "cartogram 模式下區塊的變形"}
    bubble: desc: {en: "the circles drawn in bubble mode, and the map under them", "zh-TW": "bubble 模式下的泡泡，以及底下的地圖"}
    label: desc: {en: "region names written on the map", "zh-TW": "標在地圖上的行政區名稱"}
  # 上層 / 下層. 全國是州 / 郡; 州圖只有郡, 沒有下層
  dimension: {
    town: {type: \N, name: (if national => "state" else "county"), priority: 1}
  } <<< (if national => {village: {type: \N, name: "county", priority: 2}} else {}) <<< {
    value: {type: \R, name: "value", priority: 3}
    size: {type: \R, name: "size", priority: 4}
    cat: {type: \C, name: "category", priority: 5}
    parts: {type: \R, name: "proportion", priority: 6, multiple: true}
  }

  init: ->
    @geo = geo
    @expanded = {}
    @angle = null
    @tint = tint = new chart.utils.tint!
    @g = Object.fromEntries <[view legend scale]>.map ~> [it, @layout.get-group it]
    @g <<< Object.fromEntries <[bg base units solid outline leader bubble label]>.map ~> [it, mk(@g.view, \g, it)]
    # 立體: 每一格重畫的切片 ( 重複使用 ), 與驅動立體轉場的補間 ( 不在畫面上 )
    @pool = []
    @_t3 = document.createElementNS svgns, \g
    @g.bg = mk @g.bg, \rect
    # 放大到鄉鎮時, 超出畫面的部分不要蓋到 legend
    @clip = mk mk(mk(@g.view, \defs), \clipPath), \rect
    @clip.parentNode.setAttribute \id, "tmap-clip-#{Math.random!toString(36).substring(2)}"
    @g.bg.setAttribute \fill, \transparent
    # 每個行政區一個 <g> ( 平面 ). 立體時改畫在 solid 裡, 切片的 __data__ 也是這個 <g> 的
    @node = {}
    for f in geo.towns ++ geo.villages
      g = mk @g.units, \g, "unit #{f.level}"
      # _raw: base 的 data-accessor 取這個 ( auto-select 的 select / hover 事件 )
      g.__data__ = {code: f.code, _raw: null}
      top = mk g, \path, \top
      top.__data__ = g.__data__
      bubble = mk @g.bubble, \g, "bubble #{f.level}"
      bubble.__data__ = g.__data__
      label = mk @g.label, \text
      label.setAttribute \text-anchor, \middle
      label.setAttribute \dominant-baseline, \central
      label.setAttribute \paint-order, \stroke
      label.style.pointerEvents = \none
      line = mk @g.leader, \line
      line.setAttribute \stroke-dasharray, '2 2'
      @node[f.code] = {g, top, bubble, label, line}
    @base = {top: mk(@g.base, \path), wall: mk(@g.base, \path)}
    @outline = {}
    for t in geo.towns
      @outline[t.code] = mk @g.outline, \path
      @outline[t.code].setAttribute \fill, \none
    @g.outline.style.pointerEvents = \none
    @g.leader.style.pointerEvents = \none

    @legend = new chart.utils.legend do
      root: @root
      name: \legend
      layout: @layout
      shape: (d) -> @setAttribute \fill, tint.get(d.key)
    @legend.on \select, ~> @bind!; @resize!; @render!

    @tip = new chart.utils.tip {
      root: @root
      accessor: ({evt}) ~>
        if !(evt.target and (d = evt.target.__data__) and d.code and (f = @geo.feat[d.code])) => return null
        @local.tip f
      range: ~> @layout.get-node \view .getBoundingClientRect!
    }
    # 多行的內容 ( 數值、圓餅各欄 ) 才換行. 整個 tip 都 pre-line 的話, 範本裡元素之間的換行會變成空行
    @tip.tip.style <<< {maxWidth: \16em}
    @tip.tip.querySelector('[ld=value-alt]').style.whiteSpace = \pre-line
    # 位置: 內建的會依滑鼠在區塊中心的哪一側決定方向, 大的區塊 ( 例如花蓮縣 ) 裡一移動就上下左右跳.
    # 改成固定放在滑鼠左上方, 左邊或上面放不下時才各自翻到右邊或下面
    render0 = @tip.render
    @tip.render = (opt = {}) ->
      render0.call @, opt
      if !(@enabled and opt.evt) => return
      rbox = @root.getBoundingClientRect!
      range = if @range => @range! else rbox
      tbox = @tip.getBoundingClientRect!
      [mx, my, m] = [opt.evt.clientX - rbox.x, opt.evt.clientY - rbox.y, @margin]
      [x0, y0] = [range.x - rbox.x, range.y - rbox.y]
      [x1, y1] = [x0 + range.width, y0 + range.height]
      tx = mx - m - tbox.width
      ty = my - m - tbox.height
      if tx < x0 => tx = mx + m
      if ty < y0 => ty = my + m
      tx = (tx <? x1 - tbox.width) >? x0
      ty = (ty <? y1 - tbox.height) >? y0
      @tip.style.transform = "translate(#{tx}px,#{ty}px)"

    # 點擊: 行政區 / 泡泡 -> 選取 ( 也展開村里 ); 空白處 -> 收合、清除選取.
    # 立體時拖曳旋轉, 拖過就不算點擊
    drag = null
    @g.view.addEventListener \pointerdown, (e) ~>
      drag := @drag = {x: e.clientX, moved: false, angle: @local.angle!}
    @root.addEventListener \pointermove, (e) ~>
      if !drag => return
      if !e.buttons => return drag := @drag = null
      dx = e.clientX - drag.x
      if Math.abs(dx) > 3 => drag.moved = true
      if !(drag.moved and @local.is3d! and @cfg.extrude.rotate in <[drag both]>) => return
      # 像轉盤: 往右拖, 靠近觀看者的那一側跟著往右 ( 由上往下看是逆時針, 角度變小 )
      @angle = drag.angle - dx * 0.5
      @local.draw true
    @root.addEventListener \pointerup, ~>
      @drag = null
      setTimeout (-> drag := null), 0
    @g.view.addEventListener \click, (e) ~>
      if drag and drag.moved => return
      d = (e.target or {}).__data__
      if d and d.code => @local.click e, @geo.feat[d.code]
      else @local.reset!

  destroy: -> @tip.destroy!; @legend.destroy!

  # 點選會發的維度 ( 見 local.click ): 沒綁 town 時不發; filter-level 是村里且有綁 village 時連村里一起發.
  # 沒宣告的話核心會當成 name, 但這張圖沒有 name 維
  filter-dims: ->
    if !@binding.town => return []
    if @cfg.filter-level == \village and @binding.village => <[town village]> else <[town]>
  interactions: -> click: @filter-dims!

  # 這張圖自己會發 filter ( 鄉鎮, 或鄉鎮 + 村里 ). chart.filter 會幫我們 parse / bind / resize / render
  filter: (filters, internal) ->

  parse: ->
    num = (v) -> if v? and v != '' and !isNaN(+v) => +v else undefined
    @rec = {}
    vals = (d) ->
      parts = if Array.isArray(d.parts) => d.parts else if d.parts? => [d.parts] else []
      {value: num(d.value), size: num(d.size), cat: d.cat, parts: parts.map(num), row: d}
    for d in @data
      t = "#{if d.town? => d.town else ''}".trim!
      v = "#{if d.village? => d.village else ''}".trim!
      tf = upper t
      # town 欄是村里代碼: 這一列就是那個村里
      if tf and tf.level == \village =>
        @rec[tf.code] = vals(d) <<< {keys: [d.town]}
        continue
      # 只綁村里代碼也行
      if !tf and @geo.feat[v] => tf = @geo.feat[@geo.feat[v].tcode]
      if !tf or tf.level != \town => continue
      # keys: 這一塊在 town 維度上代表的值 ( 發 filter / 判斷選取用, 保留原本的寫法 )
      if !v or (v.toLowerCase! in town-words) =>
        @rec[tf.code] = vals(d) <<< {keys: [d.town]}
      else
        # 下層名稱可以帶上層的名字 ( 臺北市中正區 )
        vf = lower tf, v
        if vf and vf.level == \village => @rec[vf.code] = vals(d) <<< {keys: [d.town], vname: d.village}
    # 沒有「全區」列的鄉鎮, 由村里匯總
    agg = @cfg.village.aggregate
    for t in @geo.towns
      if @rec[t.code] or agg == \none => continue
      vs = (@geo.vill-of[t.code] or []).map(~> @rec[it.code]).filter(-> it)
      if !vs.length => continue
      red = (k) ->
        ns = vs.map(-> it[k]).filter(-> it?)
        if !ns.length => return undefined
        s = ns.reduce ((a, b) -> a + b), 0
        if agg == \mean => s / ns.length else s
      cnt = {}
      for r in vs => if r.cat? => cnt[r.cat] = (cnt[r.cat] or 0) + 1
      cat = [k for k of cnt].sort((a, b) -> cnt[b] - cnt[a]).0
      len = Math.max.apply null, vs.map(-> it.parts.length)
      parts = [0 til len].map (i) ->
        ns = vs.map(-> it.parts[i]).filter(-> it?)
        if !ns.length => return undefined
        s = ns.reduce ((a, b) -> a + b), 0
        if agg == \mean => s / ns.length else s
      # 由村里匯總的鄉鎮, 代表的就是它底下各村里的 key ( 通常都是同一個鄉鎮名; town 欄是村里代碼時則是一串代碼 )
      keys = Array.from(new Set([].concat.apply [], vs.map (.keys)))
      @rec[t.code] = {value: red(\value), size: red(\size), cat, parts, keys, agg: true}

  resize: ->
    @root.querySelector('.pdl-layout').classList.toggle \legend-bottom, (@cfg.legend.position == \bottom)
    @tip.toggle(if @cfg.{}tip.enabled? => @cfg.tip.enabled else true)
    @legend.config @cfg.legend
    @local.prepare!
    @legend.update false
    @layout.update false
    @box = @layout.get-box \view

  render: ->
    if !@box => return
    @local.draw!
    @local.draw-scale!
    @legend.render!
    if @local.auto-rotate! => @start! else @stop!

  tick: (t, dt = 0) ->
    # 拖曳中暫停, 放開後從拖到的角度繼續轉
    if !(@local.auto-rotate! and dt) or (@drag and @drag.moved) => return
    @angle = @local.angle! + @cfg.extrude.speed * dt / 1000
    @local.draw true

  local:
    is3d: -> @cfg.extrude.enabled and @cfg.mode != \bubble
    angle: -> if @angle? => @angle else @cfg.extrude.angle
    auto-rotate: -> @local.is3d! and @cfg.extrude.rotate in <[auto both]>
    # 是否畫成圓餅: 泡泡模式且「比例」至少兩個欄位
    is-pie: -> @cfg.mode == \bubble and @cfg.bubble.pie != \none and Array.isArray(@binding.parts) and @binding.parts.length >= 2
    color-by: ->
      if @cfg.color-by == \cat => return (if @binding.cat => \cat else \value)
      if @cfg.color-by == \value => return \value
      if @binding.value => \value else if @binding.cat => \cat else \value

    expanded: (t) ->
      if !(@geo.vill-of[t.code] or []).length => return false
      m = @cfg.village.mode
      m == \all or (m == \click and @expanded[t.code] and @local.has-village!)

    # 資料裡有村里 ( 下層 ) 的列. 只有鄉鎮 ( 上層 ) 資料時 click 模式不展開 - 展開後每一塊都沒有值,
    # 剛選的那塊看起來像被清空 ( 例如只有縣市資料的儀表板 )
    has-village: -> @geo.villages.some ~> @rec[it.code]

    # 目前畫出來的單位: 沒展開的鄉鎮 + 展開的鄉鎮底下的村里
    units: ->
      ret = []
      for t in @geo.towns
        if @local.expanded t => ret ++= @geo.vill-of[t.code]
        else ret.push t
      # 簡化時消失的小村里還是對得到資料, 但沒有形狀可畫
      ret.filter -> it.area > 0

    # 色階、大小的範圍. level: 鄉鎮與村里各一組; shared: 共用一組
    prepare: ->
      lv = (f) ~> if @cfg.village.domain == \shared => \all else f.level
      dom = {}
      for code, r of @rec
        f = @geo.feat[code]
        o = dom[][lv f]
        o.push r
      @dom = {}
      for k, rs of dom
        vs = rs.map(-> it.value).filter(-> it? and isFinite it).sort (a, b) -> a - b
        ss = rs.map(-> if it.size? => it.size else it.value).filter(-> it? and isFinite it)
        @dom[k] = {value: vs, scale: @local.heat(vs), smax: (if ss.length => Math.max.apply(null, ss.map(-> Math.abs it)) else 0)}
        # 泡泡: 同一層的泡泡總面積約為地圖面積的 30%, 再乘上 bubble.scale
        tot = ss.reduce ((a, b) ~> a + (Math.abs(b) / (@dom[k].smax or 1))), 0
        area = @geo.W * @geo.H * 0.3
        @dom[k].rmax = if tot => Math.sqrt(area / (Math.PI * tot)) else 0
      @dom-of = (f) ~> @dom[lv f] or {value: [], scale: null, smax: 0, rmax: 0}

      # legend: 分類或圓餅的各欄位用 legend, 數值用自己畫的色條
      by = @local.color-by!
      @tint.reset!
      @tint.mode chart.utils.tint.mode.ordinal
      @tint.set @cfg.palette
      if @local.is-pie! =>
        @parts = @binding.parts.map (b, i) -> {key: (b.name or b.key or "#{i + 1}"), text: (b.name or b.key or "#{i + 1}")}
        @legend.data @parts.map (d, i) -> d <<< {value: -i}
      else if by == \cat =>
        cats = []
        for code, r of @rec => if r.cat? and !(r.cat in cats) => cats.push r.cat
        cats.sort!
        @legend.data cats.map -> {key: it, text: "#it"}
      else @legend.data []
      @show-scale = !@local.is-pie! and by == \value and @binding.value? and
        (@cfg.legend.enabled != false)
      n = @layout.get-node \scale
      n.style.display = if @show-scale => '' else \none

    # 數值 -> 0 ~ 1. 雙極時中點在 0.5
    heat: (vs) ->
      if !vs.length => return null
      c = @cfg.heat
      e = c.exponent or 0.5
      tf = switch c.scale
      | \log => (x) -> (if x < 0 => -1 else 1) * Math.log10(1 + Math.abs(x))
      | \pow => (x) -> (if x < 0 => -Math.pow(-x, e) else Math.pow(x, e))
      | \quantile => rank vs
      | otherwise => (x) -> x
      [lo, hi] = [vs.0, vs[* - 1]]
      div = c.mode == \diverging
      center = if !div => null
      else if c.center.mode == \manual => c.center.value
      else if c.center.mode == \mean => vs.reduce(((a, b) -> a + b), 0) / vs.length
      else
        m = vs.length / 2
        if vs.length % 2 => vs[Math.floor m] else (vs[m - 1] + vs[m]) / 2
      if div and c.symmetric =>
        r = Math.max(Math.abs(tf(hi) - tf(center)), Math.abs(tf(center) - tf(lo)))
        [tlo, thi] = [tf(center) - r, tf(center) + r]
      else [tlo, thi] = [tf(lo), tf(hi)]
      tc = if div => tf(center) else null
      steps = Math.round(c.steps or 0)
      t = (v) ->
        x = tf v
        r = if !div => (x - tlo) / ((thi - tlo) or 1)
        else if x < tc => 0.5 * (x - tlo) / ((tc - tlo) or 1)
        else 0.5 + 0.5 * (x - tc) / ((thi - tc) or 1)
        r = r >? 0 <? 1
        if steps > 1 =>
          # 雙極時中點落在級距的分界或中間, 兩側級數相同
          r = Math.min(steps - 1, Math.floor(r * steps)) / (steps - 1)
        r
      pal = if div => c.diverging else c.sequential
      cs = ((pal and pal.colors and pal.colors.length and pal.colors) or palettes[if div => \diverging else \sequential].colors)
        .map -> to-rgb it, ldcolor
      color = ramp cs
      inv = switch c.scale
      | \log => (x) -> (if x < 0 => -1 else 1) * (Math.pow(10, Math.abs(x)) - 1)
      | \pow => (x) -> (if x < 0 => -1 else 1) * Math.pow(Math.abs(x), 1 / e)
      | \quantile => unrank vs
      | otherwise => (x) -> x
      {t, lo, hi, center, color, div, inv, tlo, thi, tc}

    # 一個單位的顏色 ( [r,g,b] ), 沒有值時回 null
    color: (f) ->
      r = @rec[f.code]
      if !r => return null
      if @local.color-by! == \cat =>
        # legend 關掉的分類: shrink 當成沒有值, dim 留著顏色由 picked 降透明
        return if r.cat? and @legend.is-visible(r.cat) => to-rgb(ldcolor.web(@tint.get r.cat), ldcolor) else null
      s = @dom-of(f).scale
      if !(s and r.value? and isFinite(r.value)) => return null
      s.color s.t(r.value)

    # 0 ~ 1 的高度
    height: (f) ->
      r = @rec[f.code]
      if !r => return 0
      v = if r.value? => r.value else r.size
      vs = @dom-of(f).value
      if !(v? and vs.length) => return 0
      lo = vs.0 <? 0
      hi = vs[* - 1]
      if hi <= lo => return 1
      (v - lo) / (hi - lo) >? 0 <? 1

    # subset ( 外部篩選後的子集 ) 中這一塊佔多少. 沒有 subset 時 null
    ratio: (f, k, i) ->
      r = @rec[f.code]
      if !(r and r.row and r.row.subset) => return null
      k = k or (if @binding.size => \size else \value)
      @subset.ratio r.row, k, i

    # 被選取 / 篩選的程度 ( 1 或 common.subset.opacity )
    picked: (f) ->
      dim = ((@cfg.common or {}).subset or {}).opacity ? 0.2
      r = @rec[f.code] or {}
      # dim: 子集裡沒有這一塊就淡化. partial 只有泡泡切得出比例 ( 內圈, 見 draw );
      # 行政區塊沒有自然的可切維度 ( 同 dash 對地圖的決定 ), 退回 dim
      m = @subset.mode!
      if (m == \dim or (m == \partial and @cfg.mode != \bubble)) and @local.ratio(f) == 0 => return dim
      tr = if f.level == \village => (@rec[f.tcode] or {}) else r
      ft = ((@binding.town or {}).filter or {}).value
      fv = ((@binding.village or {}).filter or {}).value
      keys = r.keys or tr.keys or []
      if ft and !keys.some((k) -> k in ft) => return dim
      if fv and f.level == \village and !(r.vname? and r.vname in fv) => return dim
      # legend 關掉的分類
      if @local.color-by! == \cat and !@local.is-pie! and r.cat? and !@legend.is-selected(r.cat) => return @legend.opacity!
      1

    # 形狀 ( 依模式變形後的座標 ), 資料或模式不變就沿用
    shape: ->
      mode = @cfg.mode
      use-v = @cfg.village.mode == \all
      size = (f) ~>
        r = @rec[f.code]
        if !r => return undefined
        v = if r.size? => r.size else r.value
        if v? => Math.abs v else undefined
      key = [mode, use-v, @cfg.cartogram.iteration].join(\/) +
        (if mode == \cartogram => '/' + (@geo.towns ++ @geo.villages).map(size).join(',') else '')
      if @_shape and @_shape.key == key => return @_shape
      polys = {}
      for f in @geo.towns ++ @geo.villages => polys[f.code] = f.polys
      outline = @geo.outline
      if mode == \cartogram =>
        polys = {}
        for f in @geo.towns ++ @geo.villages => polys[f.code] = clone f.polys
        outline = clone @geo.outline
        # 有村里資料、而且全部畫村里時, 依村里變形; 否則依鄉鎮. 其他層跟著同一個力場移動
        list = if use-v and @geo.villages.some(~> @rec[it.code]) => @geo.villages else @geo.towns
        units = list.map (f) -> {polys: polys[f.code], v: size(f)}
        sets = [outline] ++ (@geo.towns ++ @geo.villages).map(-> polys[it.code])
        cartogram units, sets, @cfg.cartogram.iteration
      ms = {}
      for code, p of polys => ms[code] = if mode == \cartogram => metrics(p) else @geo.feat[code]
      @_shape = {key, polys, outline, ms}

    # 放大的對象: village.zoom 時 click 模式展開的鄉鎮, 否則 null ( 整張地圖 )
    focus: ->
      if !(@cfg.village.zoom and @cfg.village.mode == \click) => return null
      ts = @geo.towns.filter ~> @local.expanded it
      if ts.length => ts else null

    # 視角參數 ( 不含旋轉角度 ): 中心、縮放與位移. 立體的轉場就在這些參數之間補間
    view-param: ->
      box = @box
      pad = 10
      is3d = @local.is3d!
      cx = @geo.W / 2
      cy = @geo.H / 2
      [w, h] = [@geo.W, @geo.H]
      focus = @local.focus!
      pts = @geo.main
      if focus =>
        shape = @local.shape!
        pts = [].concat.apply [], focus.map -> shape.polys[it.code]
        [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity]
        each-point pts, (q) ->
          x0 := x0 <? q.0
          y0 := y0 <? q.1
          x1 := x1 >? q.0
          y1 := y1 >? q.1
        [cx, cy, w, h] = [(x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) or 1, (y1 - y0) or 1]
      @clip.setAttribute \width, box.width
      @clip.setAttribute \height, box.height
      if focus or @geo.overflow => @g.view.setAttribute \clip-path, "url(\##{@clip.parentNode.id})"
      else @g.view.removeAttribute \clip-path
      if !is3d =>
        s = Math.min((box.width - 2 * pad) / w, (box.height - 2 * pad) / h) >? 0.01
        return {is3d, cx, cy, s, ox: box.width / 2 - cx * s, oy: box.height / 2 - cy * s}
      tl = @cfg.extrude.tilt * Math.PI / 180
      [ct, st] = [Math.cos(tl), Math.sin(tl)]
      # 用外接圓決定縮放, 旋轉時大小不會跳
      R = 0
      each-point pts, (q) -> R := R >? Math.hypot(q.0 - cx, q.1 - cy)
      hmax = @cfg.extrude.height * @geo.W
      thick = @geo.W * 0.015
      s = Math.min((box.width - 2 * pad) / (2 * R), (box.height - 2 * pad) / (2 * R * ct + (hmax + thick) * st)) >? 0.01
      {is3d, cx, cy, s, hmax, thick, ox: box.width / 2, oy: box.height / 2 + (hmax - thick) * st * s / 2}

    # 地圖單位 -> 畫面. 立體時繞 (cx, cy) 旋轉、傾斜, h 往上.
    # rot: 旋轉後的座標 ( 第二個值越大越靠近觀看者 ); prj: 旋轉後的座標 -> 畫面
    mkview: (p) ->
      {cx, cy, s, ox, oy} = p
      if !p.is3d => return {} <<< p <<< {pt: (x, y) -> [ox + x * s, oy + y * s]}
      a = @local.angle! * Math.PI / 180
      tl = @cfg.extrude.tilt * Math.PI / 180
      [ca, sa, ct, st] = [Math.cos(a), Math.sin(a), Math.cos(tl), Math.sin(tl)]
      rot = (x, y) -> [(x - cx) * ca - (y - cy) * sa, (x - cx) * sa + (y - cy) * ca]
      prj = (rx, ry, h = 0) -> [ox + rx * s, oy + ry * ct * s - h * st * s]
      pt = (x, y, h = 0) ->
        r = rot x, y
        prj r.0, r.1, h
      {} <<< p <<< {rot, prj, pt}

    view: -> @local.mkview @local.view-param!

    # 畫地圖. instant = 不補間 ( 旋轉時 ). 立體另外畫 ( draw3d )
    draw: (instant = false) ->
      cfg = @cfg
      v = @local.view!
      shape = @local.shape!
      units = @local.units!
      shown = Object.fromEntries units.map -> [it.code, true]
      bubble = cfg.mode == \bubble
      @g.bg.setAttribute \width, @box.width
      @g.bg.setAttribute \height, @box.height
      # _raw: base 的 data-accessor 取這個 ( 平面的頂面、立體的每一片都掛同一個物件 )
      for f in units => @node[f.code].g.__data__._raw = ((@rec[f.code] or {}).row or {})._raw or null
      if v.is3d => return @local.draw3d instant
      @s3 = null
      @g.solid.style.display = \none
      @g.base.style.display = \none
      is-pie = @local.is-pie!
      dur = if instant => 0 else 350
      tween = (n, o, d = dur) ~> @anim.tween n, o, {duration: d}
      # 前一次畫的樣子 ( 平面或立體 ). 這次才出現的 ( 或剛從立體切回來 ) 從那個畫面上的位置開始補間,
      # 不然會從上次顯示時留下的位置 ( 旋轉前、放大前 ) 飛過來
      prev = @prev
      pv = if prev => prev.v else v
      fresh = (k) -> !prev or prev.is3d or !prev.shown[k]
      ph = (code) -> if prev and prev.is3d => prev.h(code) else 0
      drawn = {}
      rings = (polys, h = 0, vv = v) ->
        polys.map((p) -> p.map((r) ->
          if r.length < 2 => return ''
          'M' + r.slice(0, -1).map((q) -> vv.pt(q.0, q.1, h).map(-> it.toFixed 2).join(',')).join('L') + 'Z'
        ).join('')).join('')

      # 行政區
      empty = to-rgb cfg.heat.empty, ldcolor
      for f in @geo.towns ++ @geo.villages
        n = @node[f.code]
        if !shown[f.code] =>
          n.g.style.display = \none
          n.bubble.style.display = \none
          n.line.style.display = \none
          continue
        n.g.style.display = ''
        polys = shape.polys[f.code]
        c = @local.color(f)
        op = @local.picked f
        bw = if f.level == \town => cfg.border.width else cfg.border.village.width
        bc = if f.level == \town => cfg.border.color else cfg.border.village.color
        fill = if bubble => (if cfg.bubble.basemap => to-rgb(cfg.bubble.basemap-color, ldcolor) else null)
        else c or empty
        if bubble and !cfg.bubble.basemap => n.g.style.display = \none
        drawn[f.code] = true
        if fresh f.code =>
          @anim.interrupt n.top
          n.top.setAttribute \d, rings(polys, ph(f.code), pv)
        tween n.top, {
          d: rings(polys)
          fill: (if fill => rgb-str(fill) else \none)
          stroke: bc
          "stroke-width": bw
          "stroke-linejoin": cfg.border.linejoin
          opacity: op
        }

      # 鄉鎮界 ( 有村里展開時, 疊在上面 )
      for t in @geo.towns
        o = @outline[t.code]
        if bubble or !@local.expanded(t) =>
          o.style.display = \none
          continue
        o.style.display = ''
        drawn["o:#{t.code}"] = true
        if fresh "o:#{t.code}" =>
          @anim.interrupt o
          o.setAttribute \d, rings(shape.polys[t.code], ph(t.code), pv)
        tween o, {
          d: rings(shape.polys[t.code])
          stroke: cfg.border.color
          "stroke-width": cfg.border.width * 1.5
          "stroke-linejoin": cfg.border.linejoin
        }

      # 泡泡
      lay = if bubble => @local.bubbles(units, shape) else null
      for f in units
        n = @node[f.code]
        if !bubble =>
          n.bubble.style.display = \none
          n.line.style.display = \none
          continue
        b = lay[f.code]
        n.bubble.style.display = ''
        [x, y] = v.pt b.x, b.y
        r = b.r * v.s
        [tx, ty] = v.pt b.tx, b.ty
        op = @local.picked f
        # 虛線: 泡泡外緣 -> 行政區中心
        d = Math.hypot(tx - x, ty - y)
        if cfg.bubble.leader and !cfg.bubble.overlap and d > r + 1 =>
          n.line.style.display = ''
          [ux, uy] = [(tx - x) / d, (ty - y) / d]
          tween n.line, {
            x1: x + ux * r, y1: y + uy * r, x2: tx, y2: ty
            stroke: cfg.bubble.leader-color, "stroke-width": 0.8, opacity: op
          }
        else n.line.style.display = \none
        rec = @rec[f.code] or {}
        _raw = (rec.row or {})._raw or null
        # legend 關掉的欄位: shrink 不算進圓餅, dim 留著但降透明
        arcs = if is-pie => pie-arcs((rec.parts or []).map((v, i) ~> if @legend.is-visible(@parts[i].key) => v else 0), cfg.bubble.pie) else []
        if !arcs.length => arcs = [{i: -1, a0: 0, a1: tau}]
        partial = @subset.mode! == \partial
        color = (a) ~>
          if a.i >= 0 => to-rgb(ldcolor.web(@tint.get(@parts[a.i].key)), ldcolor)
          else (@local.color(f) or empty)
        ratio = (a) ~> if a.i >= 0 => @local.ratio(f, \parts, a.i) else @local.ratio(f)
        aop = (a) ~> op * (if a.i >= 0 and !@legend.is-selected(@parts[a.i].key) => @legend.opacity! else 1)
        wj = join root: n.bubble, tag: \path, cls: \wedge, data: arcs, key: (a) -> a.i
        wj.exit.map (p) ~> @anim.interrupt p; p.remove!
        wj.nodes.map (p) ~>
          a = p.__data__
          p.__data__ = a <<< {code: f.code, _raw}
          c = color a
          tween p, {
            d: wedge(x, y, r, a.a0, a.a1)
            fill: rgb-str(if partial and ratio(a)? => to-rgb(@subset.color(rgb-str c), ldcolor) else c)
            stroke: cfg.bubble.stroke
            "stroke-width": cfg.bubble.stroke-width
            opacity: aop(a)
          }
        # partial: 子集佔的比例畫成同心的內圈 ( 面積比 )
        subs = if !partial => [] else arcs.filter((a) -> ratio(a)?).map (a) -> a <<< {k: Math.sqrt(ratio a)}
        sj = join root: n.bubble, tag: \path, cls: \subset, data: subs, key: (a) -> a.i
        sj.exit.map (p) ~> @anim.interrupt p; p.remove!
        sj.nodes.map (p) ~>
          a = p.__data__
          p.setAttribute \pointer-events, \none
          tween p, {d: wedge(x, y, r * a.k, a.a0, a.a1), fill: rgb-str(color a), opacity: aop(a)}
        # 新進場的 wedge 會排在最後, 內圈要一直蓋在上面
        sj.nodes.map (p) -> n.bubble.appendChild p

      # 名稱
      at = (vv, f, h = 0) ->
        if bubble =>
          b = lay[f.code]
          return vv.pt b.x, b.y
        m = shape.ms[f.code]
        vv.pt m.label.0, m.label.1, h
      @local.labels {
        units, dur, drawn, fresh
        pos: (f) -> if bubble and lay[f.code].r * v.s < 10 => null else at(v, f)
        start: (f) -> at pv, f, ph(f.code)
        room: (f) -> if bubble => lay[f.code].r * v.s * 2 else Math.sqrt(shape.ms[f.code].area) * v.s * 1.3
      }
      @prev = {is3d: false, v, shown: drawn}

    # 名稱. pos(f): 畫面上的位置, null 時不標; start(f): 剛出現時的起點; depth(f): 立體時依深度疊放
    # room(f): 名稱可用的寬度 ( px ). label.fit 時放不下的不標 ( 州圖的 county 很多, 小的會擠成一團 )
    labels: ({units, pos, start, dur, drawn, fresh, depth, room}) ->
      cfg = @cfg
      lf = cfg.label.font or {}
      # 展開成村里的鄉鎮, 沒開村里名時仍標鄉鎮名 ( 泡泡模式沒有鄉鎮泡泡, 不標 )
      outer = if cfg.mode == \bubble or cfg.label.village => []
      else @geo.towns.filter ~> @local.expanded it
      on-map = Object.fromEntries (units ++ outer).map -> [it.code, true]
      for f in @geo.towns ++ @geo.villages => if !on-map[f.code] => @node[f.code].label.style.display = \none
      list = []
      for f in units ++ outer
        n = @node[f.code]
        p = if cfg.label.enabled and (f.level == \town or cfg.label.village) => pos(f) else null
        if !p =>
          n.label.style.display = \none
          continue
        n.label.style.display = ''
        # 州標縮寫
        n.label.textContent = f.abbr or (if f.level == \town => f.town else f.village)
        n.label.setAttribute \class, (if lf.family => (lf.family.className or '') else '')
        size = lf.size or '1em'
        # 字級不補間: 要先量寬度
        n.label.setAttribute \font-size, (if f.level == \village => "calc(#size * 0.7)" else size)
        if cfg.label.fit and room and n.label.getComputedTextLength! > room(f) =>
          n.label.style.display = \none
          continue
        list.push f
        drawn["l:#{f.code}"] = true
        if fresh "l:#{f.code}" =>
          q = start f
          n.label.setAttribute \x, q.0
          n.label.setAttribute \y, q.1
        @anim.tween n.label, {
          x: p.0, y: p.1
          fill: cfg.label.color
          stroke: cfg.label.halo
          "stroke-width": cfg.label.halo-width
          opacity: @local.picked f
        }, {duration: dur}
      if depth => list.sort (a, b) -> depth(a) - depth(b)
      else list = list.filter -> it in outer
      for f in list => @g.label.appendChild @node[f.code].label

    # 相鄰: 每塊每一段邊的另一側是哪一塊 ( 限這次畫出來的單位 ). 共用的邊兩側的點完全相同
    # ( 來自同一條 arc; 變形也只跟位置有關 ), 用端點當 key 就對得上
    adjacency: (polys) ->
      codes = [k for k of polys]
      key = codes.join(',') + '/' + @local.shape!key
      if @_adj and @_adj.key == key => return @_adj.map
      pk = (a, b) ->
        if a.0 < b.0 or (a.0 == b.0 and a.1 < b.1) => "#{a.0},#{a.1},#{b.0},#{b.1}"
        else "#{b.0},#{b.1},#{a.0},#{a.1}"
      seg = new Map!
      for code in codes
        for p in polys[code]
          for r in p
            for l from 0 til r.length - 1
              k = pk r[l], r[l + 1]
              if (o = seg.get k) => o.push code else seg.set k, [code]
      map = {}
      for code in codes
        map[code] = polys[code].map (p) -> p.map (r) -> [0 til r.length - 1].map (l) ->
          (seg.get(pk r[l], r[l + 1]) or []).find((c) -> c != code) or null
      @_adj = {key, map}
      map

    # 立體. 算出目標 ( 每塊的高度、顏色、形狀與視角 ) 後從目前的樣子補間過去, 每一格由 render3d 整個重畫
    # ( 切帶、排序依當下的角度 ), 所以轉動中也能轉場. 這次才出現的從上一層 ( 村里 <-> 鄉鎮 ) 的高度長出來
    draw3d: (instant) ->
      cfg = @cfg
      for code, n of @node
        n.g.style.display = \none
        n.bubble.style.display = \none
        n.line.style.display = \none
      for code, o of @outline => o.style.display = \none
      p = @local.view-param!
      shape = @local.shape!
      units = @local.units!
      empty = to-rgb cfg.heat.empty, ldcolor
      # 淡化改成往背景色混 ( 不透明 ): 半透明會看到後面的側面, 切帶的接縫也會透出來
      bg = if /^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test("#{cfg.background or ''}".trim!) => to-rgb(cfg.background, ldcolor)
      else [255 255 255]
      tgt = {}
      for f in units
        c = @local.color(f) or empty
        op = @local.picked f
        tgt[f.code] = {h: @local.height(f) * p.hmax, fill: c.map((x, i) -> x * op + bg[i] * (1 - op)), polys: shape.polys[f.code]}
      @s3adj = @local.adjacency Object.fromEntries units.map -> [it.code, shape.polys[it.code]]
      @s3outline = shape.outline
      # 切帶的寬度: 畫面上單位大小 ( 中位數 ) 的 0.35 倍
      sz = units.map((f) -> Math.sqrt(shape.ms[f.code].area or 0)).filter(-> it > 0).sort((a, b) -> a - b)
      @s3band = ((sz[Math.floor(sz.length / 2)] or @geo.W) * 0.35) >? (@geo.W / 400)
      if instant and @s3 => return @local.render3d!
      S = @s3 or {}
      SV = @s3view or p
      avg = (xs, k) -> xs.reduce(((a, b) -> a + b[k]), 0) / xs.length
      start = {}
      for code, t of tgt
        s = S[code]
        f = @geo.feat[code]
        if !s =>
          par = if f.level == \village => S[f.tcode] else null
          kids = if f.level == \town => (@geo.vill-of[code] or []).map(-> S[it.code]).filter(-> it) else []
          s = if par => {h: par.h, fill: par.fill}
          else if kids.length => {h: avg(kids, \h), fill: [0 1 2].map (i) -> avg(kids.map(-> {v: it.fill[i]}), \v)}
          else {h: 0, fill: t.fill}
        poly = s.polys and s.polys != t.polys and s.polys.length == t.polys.length and
          s.polys.every((p, i) -> p.length == t.polys[i].length and p.every (r, j) -> r.length == t.polys[i][j].length)
        start[code] = {h: s.h, fill: s.fill, polys: (if poly => s.polys else null)}
      lerp = (a, b, k) -> a + (b - a) * k
      @anim.tween @_t3, {"data-t": (k) ~>
        @s3 = {}
        for code, t of tgt
          s = start[code]
          polys = if !s.polys or k >= 1 => t.polys
          else s.polys.map (p, i) -> p.map (r, j) -> r.map (q, l) ->
            e = t.polys[i][j][l]
            [lerp(q.0, e.0, k), lerp(q.1, e.1, k)]
          @s3[code] = {h: lerp(s.h, t.h, k), fill: t.fill.map((x, i) -> lerp s.fill[i], x, k), polys}
        @s3view = {} <<< p <<< Object.fromEntries <[cx cy s ox oy]>.map (n) -> [n, lerp(SV[n], p[n], k)]
        @local.render3d!
        k
      }, {duration: (if instant => 0 else 350)}

    # 立體的一格. 依目前的角度把每塊沿深度 ( 旋轉後的 y ) 切成窄帶, 由遠而近一帶一帶畫, 同一帶裡由低到高.
    # 行政區不是凸的, 整塊排序 ( 畫家演算法 ) 在互相嵌合的地方一定會畫錯; 切開後的每一帶裡,
    # 「只會被比它近、而且比它高的東西擋住」都成立 ( 視線往觀看者是往上走的 ).
    # 側面只畫高出前方鄰居的部分: 低於鄰居的那段本來就藏在鄰居裡
    render3d: ->
      st = @s3
      if !st => return
      cfg = @cfg
      v = @local.mkview @s3view
      adj = @s3adj
      shape = @local.shape!
      @g.solid.style.display = ''
      codes = [k for k of st]
      fmt = (q) -> "#{q.0.toFixed 2},#{q.1.toFixed 2}"
      P = (q, h) -> v.prj q.0, q.1, h
      quad = (a, b, h0, h1) -> 'M' + [P(a, h0), P(b, h0), P(b, h1), P(a, h1)].map(fmt).join('L') + 'Z'
      mix = (a, b, t) -> [a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t]
      # 旋轉後的座標, 每個環的方向 ( 外框 / 洞 ), 每塊的深度範圍
      R = {}
      [ymin, ymax] = [Infinity, -Infinity]
      for code in codes
        [lo, hi] = [Infinity, -Infinity]
        rr = []
        for p in st[code].polys
          pp = []
          for r, j in p
            rp = []
            for q in r
              o = v.rot q.0, q.1
              if o.1 < lo => lo = o.1
              if o.1 > hi => hi = o.1
              rp.push o
            pp.push {r: rp, sgn: (if ring-area(rp) > 0 => 1 else -1) * (if j > 0 => -1 else 1)}
          rr.push pp
        R[code] = {rr, lo, hi}
        if lo < ymin => ymin = lo
        if hi > ymax => ymax = hi

      # 底板
      if cfg.extrude.base.enabled =>
        bc = to-rgb cfg.extrude.base.color, ldcolor
        [top, wall] = ['', '']
        for p in @s3outline
          for r, j in p
            if r.length < 4 => continue
            rr = r.map (q) -> v.rot q.0, q.1
            top += 'M' + rr.slice(0, -1).map((q) -> fmt P(q, 0)).join('L') + 'Z'
            sgn = (if ring-area(rr) > 0 => 1 else -1) * (if j > 0 => -1 else 1)
            for l from 0 til rr.length - 1
              [a, b] = [rr[l], rr[l + 1]]
              if sgn * (a.0 - b.0) > 0 => wall += quad a, b, -v.thick, 0
        @base.wall.setAttribute \d, wall
        @base.wall.setAttribute \fill, rgb-str(bc, 0.8)
        @base.top.setAttribute \d, top
        @base.top.setAttribute \fill, rgb-str(bc)
        @g.base.style.display = ''
      else @g.base.style.display = \none

      # 切帶
      d = @s3band
      nb = if codes.length => Math.floor((ymax - ymin) / d) + 1 else 0
      bands = [[] for i from 0 til nb]
      for code in codes
        o = R[code]
        for k from Math.floor((o.lo - ymin) / d) to Math.floor((o.hi - ymin) / d) => bands[k].push code
      # 環只留 y0 <= y <= y1 的部分 ( Sutherland–Hodgman, 兩條水平線 )
      cut = (pts, y, keep) ->
        out = []
        for a, i in pts
          b = pts[(i + 1) % pts.length]
          [ia, ib] = [keep(a.1), keep(b.1)]
          if ia => out.push a
          if ia != ib => out.push mix(a, b, (y - a.1) / (b.1 - a.1))
        out
      clip-ring = (r, y0, y1) ->
        pts = cut r.slice(0, -1), y0, (y) -> y >= y0
        if pts.length < 3 => return null
        pts = cut pts, y1, (y) -> y <= y1
        if pts.length < 3 => null else pts
      # 線段在 y0 ~ y1 之間的那段, 回傳參數範圍
      clip-seg = (a, b, y0, y1) ->
        dy = b.1 - a.1
        if !dy => return (if a.1 >= y0 and a.1 < y1 => [0, 1] else null)
        [ta, tb] = [(y0 - a.1) / dy, (y1 - a.1) / dy]
        if ta > tb => [ta, tb] = [tb, ta]
        [t0, t1] = [ta >? 0, tb <? 1]
        if t0 < t1 => [t0, t1] else null

      # 元素重複使用: 每一格依序填進去, 順序就是疊放的順序
      pool = @pool
      cnt = {i: 0}
      put = (d, a, data) ~>
        el = pool[cnt.i]
        if !el =>
          el = pool[cnt.i] = mk @g.solid, \path
          el._a = {}
        cnt.i++
        a.d = d
        for k, val of a => if el._a[k] != val =>
          el._a[k] = val
          el.setAttribute k, val
        el.__data__ = data
      k1 = 1 - cfg.extrude.shade
      for list, k in bands
        if !list.length => continue
        y0 = ymin + k * d
        y1 = y0 + d
        list.sort (a, b) -> (st[a].h - st[b].h) or ((R[a].lo + R[a].hi) - (R[b].lo + R[b].hi))
        for code in list
          s = st[code]
          o = R[code]
          f = @geo.feat[code]
          whole = o.lo >= y0 and o.hi <= y1
          [w0, w1, top, line] = ['', '', '', '']
          for p, pi in o.rr
            for {r, sgn}, j in p
              if r.length < 4 => continue
              t = if whole => r.slice(0, -1) else clip-ring(r, y0, y1)
              if t => top += 'M' + t.map((q) -> fmt P(q, s.h)).join('L') + 'Z'
              nbs = adj[code][pi][j]
              for l from 0 til r.length - 1
                [a, b] = [r[l], r[l + 1]]
                tt = if whole => [0, 1] else clip-seg(a, b, y0, y1)
                if !tt => continue
                [qa, qb] = [mix(a, b, tt.0), mix(a, b, tt.1)]
                line += "M#{fmt P(qa, s.h)}L#{fmt P(qb, s.h)}"
                # 朝向觀看者的邊 ( 外法向量往 y 正向 ), 依法向量的 x 分亮暗
                [nx, ny] = [sgn * (b.1 - a.1), sgn * (a.0 - b.0)]
                if ny <= 0 => continue
                hn = if nbs[l] and st[nbs[l]] => st[nbs[l]].h else 0
                if s.h - hn < 1e-6 => continue
                if nx > 0 => w1 += quad(qa, qb, hn, s.h) else w0 += quad(qa, qb, hn, s.h)
          data = @node[code].g.__data__
          for [w, kk] in [[w0, k1], [w1, k1 * k1]] => if w =>
            c = rgb-str s.fill, kk
            put w, {fill: c, stroke: c, "stroke-width": 0.5, "stroke-linejoin": \round, "pointer-events": \visiblePainted}, data
          if top =>
            # 同色的細邊蓋住切帶的接縫
            c = rgb-str s.fill
            put top, {fill: c, stroke: c, "stroke-width": 0.6, "stroke-linejoin": \round, "pointer-events": \visiblePainted}, data
          if line =>
            put line, {
              fill: \none
              stroke: (if f.level == \town => cfg.border.color else cfg.border.village.color)
              "stroke-width": (if f.level == \town => cfg.border.width else cfg.border.village.width)
              "stroke-linejoin": cfg.border.linejoin
              "pointer-events": \none
            }, data
      for el in pool.splice(cnt.i) => el.remove!

      # 名稱 ( 每一格直接放到位置 ). 展開的鄉鎮標在它村里的平均高度
      hof = (f) ~>
        if st[f.code] => return st[f.code].h
        ks = (@geo.vill-of[f.code] or []).map(-> st[it.code]).filter(-> it)
        if ks.length => ks.reduce(((a, b) -> a + b.h), 0) / ks.length else 0
      at = (f) ->
        m = shape.ms[f.code]
        v.pt m.label.0, m.label.1, hof(f)
      @local.labels {
        units: codes.map(~> @geo.feat[it]), dur: 0, drawn: {}, fresh: (-> true)
        pos: at, start: at
        room: (f) -> Math.sqrt(shape.ms[f.code].area) * v.s * 1.3
        depth: (f) -> m = shape.ms[f.code]; v.rot(m.label.0, m.label.1).1
      }
      @prev = {is3d: true, v, h: ((c) -> if st[c] => st[c].h else 0), shown: {}}

    # 泡泡位置 ( 地圖單位 ), 依資料與設定快取
    bubbles: (units, shape) ->
      cfg = @cfg.bubble
      nodes = units.map (f) ~>
        r = @rec[f.code] or {}
        v = if r.size? => r.size else r.value
        d = @dom-of f
        m = @geo.feat[f.code]
        rr = if v? and d.smax => Math.sqrt(Math.abs(v) / d.smax) * d.rmax * cfg.scale else 0
        {code: f.code, tx: m.c.0, ty: m.c.1, x: m.c.0, y: m.c.1, r: rr}
      key = JSON.stringify([cfg.overlap, cfg.padding, @box.width] ++ nodes.map -> [it.code, it.r.toFixed(3)])
      if @_bubble and @_bubble.key == key => return @_bubble.map
      # padding 是畫面上的 px, 換成地圖單位
      s = @local.view!s
      if !cfg.overlap => relax nodes.filter(-> it.r > 0), cfg.padding / s
      @_bubble = {key, map: Object.fromEntries nodes.map -> [it.code, it]}
      @_bubble.map

    # 數值的色條 ( 連續 / 分級; 雙極時標出中點 )
    draw-scale: ->
      g = @g.scale
      g.textContent = ''
      if !@show-scale => return
      units = @local.units!
      # 各層各自一組色階時, 色條跟著畫面上的鄉鎮; 全部都是村里, 或放大到鄉鎮 ( 看到的主要是村里 ) 時顯示村里的
      vonly = units.length and units.every(-> it.level == \village)
      lv = if @cfg.village.domain != \shared and (vonly or @local.focus!) => @geo.villages.0
      else @geo.towns.0
      s = @dom-of(lv).scale
      if !s => return
      box = @layout.get-box \scale
      bottom = @cfg.legend.position == \bottom
      f = format.from(@cfg.legend.format or '.3s')
      unit = (@binding.value or {}).unit or ''
      id = "tmap-grad-#{Math.random!toString(36).substring(2)}"
      defs = mk g, \defs
      grad = mk defs, \linearGradient
      grad.setAttribute \id, id
      if bottom => grad.setAttribute \x2, '100%'
      else
        grad.setAttribute \x2, '0'
        grad.setAttribute \y1, '100%'
        grad.setAttribute \y2, '0'
      steps = Math.round(@cfg.heat.steps or 0)
      n = if steps > 1 => steps else 24
      for i from 0 til n
        for e in (if steps > 1 => [i / n, (i + 1) / n] else [i / (n - 1)])
          st = mk grad, \stop
          st.setAttribute \offset, "#{(e * 100).toFixed(2)}%"
          tt = if steps > 1 => i / (steps - 1) else i / (n - 1)
          st.setAttribute \stop-color, rgb-str(s.color tt)
      th = 10
      len = if bottom => box.width - 20 else box.height - 30
      len = len >? 20
      rect = mk g, \rect
      rect.setAttribute \fill, "url(##id)"
      # t ( 0~1 ) -> 數值, 標刻度用
      inv-tf = s.inv
      val = (t) ->
        x = if !s.div => s.tlo + (s.thi - s.tlo) * t
        else if t < 0.5 => s.tlo + (s.tc - s.tlo) * t * 2
        else s.tc + (s.thi - s.tc) * (t - 0.5) * 2
        inv-tf x
      ticks = [0 0.5 1]
      label = (t, txt) ->
        n = mk g, \text
        n.textContent = txt
        n.setAttribute \font-size, '0.75em'
        n.setAttribute \fill, \currentColor
        if bottom =>
          n.setAttribute \x, 10 + len * t
          n.setAttribute \y, th + 14
          n.setAttribute \text-anchor, \middle
        else
          n.setAttribute \x, th + 4
          n.setAttribute \y, 10 + len * (1 - t)
          n.setAttribute \dominant-baseline, \central
      [rx, ry, rw, rh] = if bottom => [10, 0, len, th] else [0, 10, th, len]
      for k, v of {x: rx, y: ry, width: rw, height: rh} => rect.setAttribute k, v
      for t in ticks => label t, "#{f val(t)}#{if t == 1 => unit else ''}"

    # tip 的內容
    tip: (f) ->
      r = @rec[f.code] or {}
      f2 = format.from(@cfg.tip.format or '.3s')
      fv = (v, b) -> if v? and isFinite(v) => "#{f2 v}#{(b or {}).unit or ''}" else '-'
      name = f.full or (if f.level == \village => f.village else f.town)
      lines = []
      if @binding.value => lines.push "#{@binding.value.name or @binding.value.key}: #{fv r.value, @binding.value}"
      if @binding.size and @cfg.mode != \map => lines.push "#{@binding.size.name or @binding.size.key}: #{fv r.size, @binding.size}"
      if @binding.cat and r.cat? => lines.push "#{@binding.cat.name or @binding.cat.key}: #{r.cat}"
      if @local.is-pie! =>
        tot = (r.parts or []).reduce ((a, b) -> a + (b or 0)), 0
        for b, i in @binding.parts
          p = (r.parts or [])[i]
          lines.push "#{b.name or b.key}: #{fv p, b}#{if tot and p? => " (#{(p / tot * 100).toFixed(1)}%)" else ''}"
      {
        group: if f.level == \village => f.town else ''
        name: name + (if r.agg => " ( #{t(\aggregated)} )" else '')
        value: lines.0 or '-'
        value-alt: lines.slice(1).join('\n')
      }

    # 點擊. 鄉鎮: 展開村里 ( click 模式 ) 並選取; 村里: 依 filter-level 選村里或它的鄉鎮
    # 單擊只選這一個, shift 增刪, 再點一次選到只剩自己的那個就清空 ( 與 pie 一致 )
    click: (evt, f) ->
      shift = evt and evt.shiftKey
      town = if f.level == \town => f else @geo.feat[f.tcode]
      if f.level == \town and @cfg.village.mode == \click and (@geo.vill-of[f.code] or []).length and @local.has-village! =>
        if !shift => @expanded = {}
        @expanded[f.code] = true
      # 一塊可能代表好幾個 key ( 見 parse ), 整組進出
      toggle = (vs, ks) ->
        vs = (vs or []).slice!
        ks = [].concat ks
        all-in = ks.every (k) -> k in vs
        if shift => (if all-in => vs.filter((v) -> !(v in ks)) else Array.from(new Set(vs ++ ks)))
        else if all-in and vs.length == ks.length => []
        else ks
      ft = ((@binding.town or {}).filter or {}).value
      fv = ((@binding.village or {}).filter or {}).value
      r = @rec[f.code] or {}
      keys = r.keys or (@rec[town.code] or {}).keys or []
      filters = {}
      if f.level == \village and @cfg.filter-level == \village and @binding.village and r.vname? =>
        fv = toggle fv, r.vname
        ft = if fv.length => Array.from(new Set((ft or []) ++ keys)) else []
        filters.village = if fv.length => {type: \index, value: fv} else undefined
      else if keys.length =>
        ft = toggle ft, keys
        filters.village = undefined
        # 再點一次取消選取時, 一併收合 ( 放大時就是還原 )
        if !shift and !ft.length => delete @expanded[town.code]
      else return @render!
      filters.town = if ft and ft.length => {type: \index, value: ft} else undefined
      if !@binding.town => return @render!
      @filter filters, true

    reset: ->
      had = [k for k of @expanded].length or ((@binding.town or {}).filter) or ((@binding.village or {}).filter)
      @expanded = {}
      if !had => return
      if @binding.town => @filter {town: undefined, village: undefined}, true
      else @render!
