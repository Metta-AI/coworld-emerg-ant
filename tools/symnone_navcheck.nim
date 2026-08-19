import ../src/ctf/[arena, sim_types], std/[os, deques, strformat]
let gm = mapFromSpecJson(readFile(paramStr(1)))
let obs = buildArenaObstacles(gm)
let w = gm.width; let h = gm.height
const R = 13
var walk = newSeq[bool](w*h)
for y in 0..<h:
  for x in 0..<w: walk[y*w+x] = not mapWallAt(gm, obs, x, y, includeSpinning=false)
# erode 13 (26-body)
var er = newSeq[bool](w*h)
for y in 0..<h:
  for x in 0..<w:
    if not walk[y*w+x] or x<R or y<R or x>=w-R or y>=h-R: continue
    var ok = true
    block s:
      for dy in -R..R:
        for dx in -R..R:
          if not walk[(y+dy)*w+(x+dx)]: ok=false; break s
    er[y*w+x]=ok
# components
var lab = newSeq[int](w*h); var n=0; var sizes: seq[int]
for sy in 0..<h:
  for sx in 0..<w:
    if er[sy*w+sx] and lab[sy*w+sx]==0:
      inc n; var sz=0; var q=initDeque[(int,int)](); q.addLast((sx,sy)); lab[sy*w+sx]=n
      while q.len>0:
        let (x,y)=q.popFirst(); inc sz
        for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)]:
          let nx=x+dx; let ny=y+dy
          if nx>=0 and ny>=0 and nx<w and ny<h and er[ny*w+nx] and lab[ny*w+nx]==0:
            lab[ny*w+nx]=n; q.addLast((nx,ny))
      sizes.add sz
echo &"26-body components: {n}  sizes(top): ", sizes
# anchors reachable to field center-ish?
proc comp(x,y:int):int = (if x>=0 and y>=0 and x<w and y<h: lab[y*w+x] else: -1)
for t in gm.teams():
  let a = gm.teamAnchor(t)
  echo t, " anchor ", a, " comp=", comp(a.x,a.y)
echo "field(300,100) comp=", comp(300,100), " field(900,550) comp=", comp(900,550)
