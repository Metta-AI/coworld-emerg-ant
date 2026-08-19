## Local HTTP service for inspecting and editing CTF map specs.
## Usage: nim c -d:release --threads:on --mm:orc -r tools/map_editor.nim [port] [host]
## Demo/curation tooling; NOT part of the server. Nothing here ships in the game
## binary — `src/ctf.nim` never imports it, and it exists to author and inspect
## the `mapSpec` JSON the server already consumes.
##
## The request dispatcher is deliberately independent of mummy so the API can
## be tested without a socket or a threads-enabled test build. The executable
## adapter is compiled only when this module is the program entrypoint.
import
  std/[base64, json, os, strutils],
  pixie,
  ../src/ctf/[map_pool, sim],
  map_render

const
  MapEditorMaxBodyBytes* = 2 * 1024 * 1024
  MapEditorMaxDimension* = 6500
  MapEditorMaxPixels* = 25_000_000
  DefaultRenderMaxDimension = 1600
  EditorAssetDir = currentSourcePath().parentDir() / "map_editor"

type
  EditorResponse* = object
    status*: int
    contentType*: string
    body*: string

proc jsonResponse(node: JsonNode, status = 200): EditorResponse =
  EditorResponse(
    status: status,
    contentType: "application/json; charset=utf-8",
    body: $node
  )

proc errorResponse(message: string, status = 200): EditorResponse =
  jsonResponse(%*{"ok": false, "error": message}, status)

proc raiseRequestError(message: string) {.noreturn.} =
  raise newException(CtfError, message)

proc parseObject(text, description: string): JsonNode =
  try:
    result = parseJson(text)
  except JsonParsingError as e:
    raiseRequestError("Could not parse " & description & " JSON: " & e.msg)
  if result.kind != JObject:
    raiseRequestError(description & " must be a JSON object.")

proc requiredField(node: JsonNode, name: string): JsonNode =
  if not node.hasKey(name):
    raiseRequestError("Missing required field: " & name & ".")
  node[name]

proc requiredObject(node: JsonNode, name: string): JsonNode =
  result = node.requiredField(name)
  if result.kind != JObject:
    raiseRequestError("Field " & name & " must be an object.")

proc requiredInt(node: JsonNode, name: string): int =
  let value = node.requiredField(name)
  if value.kind != JInt:
    raiseRequestError("Field " & name & " must be an integer.")
  value.getInt()

proc optionalInt(node: JsonNode, name: string, default: int): int =
  if not node.hasKey(name):
    return default
  let value = node[name]
  if value.kind != JInt:
    raiseRequestError("Field " & name & " must be an integer.")
  value.getInt()

proc optionalBool(node: JsonNode, name: string, default: bool): bool =
  if not node.hasKey(name):
    return default
  let value = node[name]
  if value.kind != JBool:
    raiseRequestError("Field " & name & " must be a boolean.")
  value.getBool()

proc pointNode(x, y: int): JsonNode =
  %*[x, y]

proc pointsNode(points: openArray[tuple[x, y: int]]): JsonNode =
  result = newJArray()
  for point in points:
    result.add pointNode(point.x, point.y)

proc mapPointsNode(points: openArray[MapPoint]): JsonNode =
  result = newJArray()
  for point in points:
    result.add pointNode(point.x, point.y)

proc rectNode(rect: MapRect): JsonNode =
  %*[rect.x, rect.y, rect.w, rect.h]

proc mapRectsNode(rects: openArray[MapRect]): JsonNode =
  result = newJArray()
  for rect in rects:
    result.add rect.rectNode()

proc teamNamesNode(teams: openArray[Team]): JsonNode =
  result = newJArray()
  for team in teams:
    result.add %teamText(team)

proc validateMapResourceLimits(gameMap: CtfMap) =
  ## These are service allocation limits, not a second geometry validator.
  if gameMap.width > MapEditorMaxDimension or
      gameMap.height > MapEditorMaxDimension:
    raiseRequestError(
      "Map dimensions must not exceed " & $MapEditorMaxDimension & " px."
    )
  let pixels = int64(gameMap.width) * int64(gameMap.height)
  if pixels > MapEditorMaxPixels:
    raiseRequestError(
      "Map area must not exceed " & $MapEditorMaxPixels & " pixels."
    )

proc parseMapSpec(node: JsonNode): CtfMap =
  ## mapFromSpecJson deliberately reports its domain failures as CtfError,
  ## but std/json access errors are possible for missing or mistyped fields.
  ## Both are expected while a person is editing and belong in the lint panel.
  try:
    result = mapFromSpecJson($node)
  except CtfError:
    raise
  except CatchableError as e:
    raiseRequestError("Could not parse map spec JSON: " & e.msg)

proc parseTrenches(node: JsonNode, gameMap: CtfMap): seq[ArenaShape] =
  ## The editor authors rect pits (matching the generator); the field type is
  ## shape-general so authored polygon pits round-trip via the mapSpec, but the
  ## editor UI still submits [x, y, w, h] rectangles.
  if node.kind != JArray:
    raiseRequestError("Field trenches must be an array.")
  for i in 0 ..< node.len:
    let item = node[i]
    if item.kind != JArray or item.len != 4:
      raiseRequestError(
        "Field trenches entries must be [x, y, w, h] arrays."
      )
    for value in item:
      if value.kind != JInt:
        raiseRequestError("Trench coordinates and sizes must be integers.")
    let rect = MapRect(
      x: item[0].getInt(), y: item[1].getInt(),
      w: item[2].getInt(), h: item[3].getInt(),
    )
    if rect.w <= 0 or rect.h <= 0:
      raiseRequestError("Map trench " & $i & " size must be positive.")
    if rect.x < 0 or rect.y < 0 or
        rect.w > gameMap.width or rect.x > gameMap.width - rect.w or
        rect.h > gameMap.height or rect.y > gameMap.height - rect.h:
      raiseRequestError("Map trench " & $i & " is outside the map.")
    result.add rectShape(rect)

proc parseMedKits(node: JsonNode, gameMap: CtfMap): seq[MapPoint] =
  if node.kind != JArray:
    raiseRequestError("Field medKits must be an array.")
  for i in 0 ..< node.len:
    let item = node[i]
    if item.kind != JArray or item.len != 2:
      raiseRequestError("Field medKits entries must be [x, y] arrays.")
    for value in item:
      if value.kind != JInt:
        raiseRequestError("Med-kit coordinates must be integers.")
    let point = MapPoint(x: item[0].getInt(), y: item[1].getInt())
    if point.x < 0 or point.y < 0 or
        point.x >= gameMap.width or point.y >= gameMap.height:
      raiseRequestError("Map med kit " & $i & " is outside the map.")
    result.add point

proc parseMapGenOverrides(node: JsonNode): MapGenOverrides =
  if node.kind != JObject:
    raiseRequestError("Field overrides must be an object.")
  result = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  for name, value in node:
    case name
    of "size", "symmetry", "centerFeature", "layout", "endzone":
      if value.kind != JString:
        raiseRequestError("Override " & name & " must be a string.")
      case name
      of "size": result.size = value.getStr()
      of "symmetry": result.symmetry = value.getStr()
      of "centerFeature": result.centerFeature = value.getStr()
      of "layout": result.layout = value.getStr()
      of "endzone": result.endzone = value.getStr()
      else: discard
    of "columns", "windows", "pits", "pitDensity", "endzoneRadius",
        "baseDepth":
      if value.kind != JInt:
        raiseRequestError("Override " & name & " must be an integer.")
      case name
      of "columns": result.columns = value.getInt()
      of "windows": result.windows = value.getInt()
      of "pits": result.pits = value.getInt()
      of "pitDensity": result.pitDensity = value.getInt()
      of "endzoneRadius": result.endzoneRadius = value.getInt()
      of "baseDepth": result.baseDepth = value.getInt()
      else: discard
    else:
      raiseRequestError("Unknown map generator override: " & name & ".")

proc parseRenderOptions(node: JsonNode): MapRenderOptions =
  if node.kind != JObject:
    raiseRequestError("Field render must be an object.")
  result.maxDimension = node.optionalInt(
    "maxDimension", DefaultRenderMaxDimension
  )
  if result.maxDimension < 0:
    raiseRequestError("Render maxDimension must be 0 or greater.")
  result.pickupKinds = AllPickupKinds
  if not node.hasKey("overlays"):
    return
  let overlays = node["overlays"]
  if overlays.kind != JArray:
    raiseRequestError("Field render.overlays must be an array.")
  for item in overlays:
    if item.kind != JString:
      raiseRequestError("Render overlay names must be strings.")
    case item.getStr()
    of "protected": result.overlays.incl overlayProtected
    of "pickups": result.overlays.incl overlayPickups
    of "spin": result.overlays.incl overlaySpin
    of "seedRegion": result.overlays.incl overlaySeedRegion
    of "sightlines": result.overlays.incl overlaySightlines
    of "reachability": result.overlays.incl overlayReachability
    else:
      raiseRequestError("Unknown render overlay: " & item.getStr() & ".")

proc diagnosticsNode(gameMap: CtfMap, diagnostics: MapDiagnostics): JsonNode =
  ## Every positional detail the validator knows travels with the verdict, so a
  ## client can point at a failure without deriving geometry or scraping the
  ## reason prose. Gate points and the two flank booleans already exist in
  ## MapDiagnostics; dropping them here only made the UI less truthful.
  var gates = newJArray()
  for gate in diagnostics.endzoneGates:
    gates.add %*{
      "name": gate.name,
      "state": (
        case gate.state
        of gateOpen: "open"
        of gateOffMap: "offMap"
        of gateSealed: "sealed"
      ),
      "x": gate.point.x,
      "y": gate.point.y,
    }
  let reason = mapValidationReason(diagnostics)
  %*{
    "valid": reason.len == 0,
    "reason": reason,
    "coverPermille": diagnostics.coverPermille,
    "minCoverPermille": diagnostics.minCoverPermille,
    "coverPermilleMin": CoverPermilleMin,
    "coverPermilleMax": CoverPermilleMax,
    "openSightlineRows": diagnostics.openSightlineRows,
    # The x band the sightline scan actually covers. A rule drawn across the
    # full width would claim the validator checked ground it never looked at.
    "sightlineXRange": {
      "xLo": gameMap.sightlineLoX(),
      "xHi": gameMap.sightlineHiX(),
    },
    "unreachableTeams": teamNamesNode(diagnostics.unreachableTeams),
    "centerReachable": diagnostics.centerReachable,
    "redHomeOnOpenFloor": diagnostics.redHomeOnOpenFloor,
    "endzoneFlankChecked": diagnostics.endzoneFlankChecked,
    "rearGateReachesCenterWithoutEndzone":
      diagnostics.rearGateReachesCenterWithoutEndzone,
    "endzoneGates": gates,
  }

proc captureZonesNode(gameMap: CtfMap): JsonNode =
  result = newJArray()
  for team in gameMap.teams():
    let zone = gameMap.captureZone(team)
    result.add %*{
      "team": teamText(team),
      "xLo": zone.xLo,
      "xHi": zone.xHi,
      "yLo": zone.yLo,
      "yHi": zone.yHi,
      "diag": zone.diag,
      "cornerX": zone.cornerX,
      "cornerY": zone.cornerY,
      "diagLimit": zone.diagLimit,
      "disc": zone.disc,
      "anchorX": zone.anchorX,
      "anchorY": zone.anchorY,
      "radius": zone.radius,
    }

proc editorMapSeedRegion(gameMap: CtfMap): MapRect =
  ## The core export is authoritative. Keep the renderer fallback only while
  ## the concurrently developed core branch is being reconciled.
  when compiles(sim.mapSeedRegion(gameMap)):
    sim.mapSeedRegion(gameMap)
  else:
    map_render.mapSeedRegion(gameMap)

proc derivedNode(gameMap: CtfMap): JsonNode =
  let
    seedRegion = editorMapSeedRegion(gameMap)
    obstacles = buildArenaObstacles(gameMap)
    diamonds = buildAnimatedDiamonds(gameMap, obstacles)
  var anchors = newJArray()
  for team in gameMap.teams():
    let anchor = gameMap.teamAnchor(team)
    anchors.add %*{
      "team": teamText(team),
      "x": anchor.x,
      "y": anchor.y,
    }
  var diamondNodes = newJArray()
  for diamond in diamonds:
    diamondNodes.add %*{
      "cx": diamond.cx,
      "cy": diamond.cy,
      "r": diamond.radius,
    }
  %*{
    "teamCount": gameMap.teamCount(),
    # Trivially derivable from the dimensions, but returning it keeps the
    # client out of the business of knowing how a map's centre is defined.
    "center": {"x": gameMap.center.x, "y": gameMap.center.y},
    "seedRegion": {
      "x": seedRegion.x,
      "y": seedRegion.y,
      "w": seedRegion.w,
      "h": seedRegion.h,
    },
    "anchors": anchors,
    "captureZones": captureZonesNode(gameMap),
    "pickups": {
      "grenade": pointsNode(gameMap.grenadeSpawnPoints()),
      "shield": pointsNode(gameMap.shieldSpawnPoints()),
      "plasmaArc": pointsNode(gameMap.plasmaArcSpawnPoints()),
      "medKitActive": mapPointsNode(gameMap.medKitSpawns),
      "medKitCandidate": mapPointsNode(gameMap.medKitCandidates),
    },
    "spinningDiamonds": diamondNodes,
    "authoredObstacleCount": gameMap.leftObstacles.len,
    "expandedObstacleCount": obstacles.len,
  }

proc mapResponseNode(body: string): JsonNode =
  let
    request = parseObject(body, "map request")
    spec = request.requiredObject("spec")
    renderNode =
      if request.hasKey("render"): request["render"]
      else: newJObject()
    options = parseRenderOptions(renderNode)
    gameMap = parseMapSpec(spec)
  gameMap.validateMapResourceLimits()
  var artifacts: set[MapDiagnosticArtifact]
  if overlayReachability in options.overlays:
    artifacts.incl diagnosticCorridorOpen
    artifacts.incl diagnosticReachable
  let
    diagnostics = mapDiagnostics(gameMap, artifacts)
    rendered = renderMap(gameMap, diagnostics, options)
    png = rendered.image.encodeImage(PngFormat)
  %*{
    "ok": true,
    "png": encode(png),
    "renderScale": rendered.renderScale,
    "validation": diagnosticsNode(gameMap, diagnostics),
    "derived": derivedNode(gameMap),
  }

proc generateResponseNode(body: string): JsonNode =
  let
    request = parseObject(body, "generate request")
    seed = request.requiredInt("seed")
    teams = request.optionalInt("teams", 2)
    validated = request.optionalBool("validated", true)
  if teams notin [2, 4]:
    raiseRequestError("Field teams must be 2 or 4.")
  let
    overrides =
      if request.hasKey("overrides"):
        parseMapGenOverrides(request["overrides"])
      else:
        MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
    gameMap =
      if validated: generateCtfMap(seed, overrides, teams)
      else: generateMapAttempt(seed, overrides, teams)
  gameMap.validateMapResourceLimits()
  %*{
    "ok": true,
    "spec": parseJson(mapSpecJson(gameMap)),
  }

proc symmetryResponseNode(body: string): JsonNode =
  let
    request = parseObject(body, "symmetry request")
    spec = request.requiredObject("spec")
    gameMap = parseMapSpec(spec)
  gameMap.validateMapResourceLimits()
  let
    trenches = parseTrenches(request.requiredField("trenches"), gameMap)
    medKits = parseMedKits(request.requiredField("medKits"), gameMap)
  if gameMap.symmetry in {symRot90, symQuadMirror} and trenches.len > 0:
    raiseRequestError("Trenches are not supported on 4-team maps yet.")
  var
    trenchOrbits = newJArray()
    medKitOrbits = newJArray()
  for trench in trenches:
    trenchOrbits.add mapRectsNode(gameMap.symmetryImages(shapeAsRect(trench)))
  for medKit in medKits:
    medKitOrbits.add mapPointsNode(gameMap.symmetryImages(medKit))
  %*{
    "ok": true,
    "trenches": trenchOrbits,
    "medKits": medKitOrbits,
  }

proc poolListResponseNode(): JsonNode =
  var seeds = newJArray()
  for seed in MapPoolSeeds:
    seeds.add %seed
  %*{
    "seeds": seeds,
    "count": MapPoolSeeds.len,
  }

proc poolEntryResponseNode(indexText: string): JsonNode =
  var index: int
  try:
    index = parseInt(indexText)
  except ValueError:
    raiseRequestError("Pool index must be an integer.")
  if index < 0 or index >= MapPoolSeeds.len:
    raiseRequestError(
      "Pool index must be 0.." & $(MapPoolSeeds.len - 1) & "."
    )
  let gameMap = poolCtfMap(index)
  %*{
    "ok": true,
    "spec": parseJson(mapSpecJson(gameMap)),
  }

proc handleMap*(body: string): EditorResponse =
  try:
    jsonResponse(mapResponseNode(body))
  except CtfError as e:
    errorResponse(e.msg)

proc handleGenerate*(body: string): EditorResponse =
  try:
    jsonResponse(generateResponseNode(body))
  except CtfError as e:
    errorResponse(e.msg)

proc handleSymmetry*(body: string): EditorResponse =
  try:
    jsonResponse(symmetryResponseNode(body))
  except CtfError as e:
    errorResponse(e.msg)

proc handlePoolList*(): EditorResponse =
  jsonResponse(poolListResponseNode())

proc handlePoolEntry*(indexText: string): EditorResponse =
  try:
    jsonResponse(poolEntryResponseNode(indexText))
  except CtfError as e:
    errorResponse(e.msg)

proc mimeType(path: string): string =
  case path.splitFile.ext.toLowerAscii()
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".json": "application/json; charset=utf-8"
  of ".png": "image/png"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  else: "application/octet-stream"

proc safeAssetPath(relativePath: string): string =
  if relativePath.len == 0 or relativePath.isAbsolute():
    raiseRequestError("Invalid static asset path.")
  for component in relativePath.split('/'):
    if component.len == 0 or component in [".", ".."] or '\\' in component:
      raiseRequestError("Invalid static asset path.")
  EditorAssetDir / relativePath

proc ensureAssetInsideRoot(path: string) =
  ## Component checks reject ordinary traversal; resolving the existing file
  ## also prevents a symlink under tools/map_editor from escaping that root.
  let
    root = EditorAssetDir.expandFilename()
    resolved = path.expandFilename()
    rootPrefix = root & DirSep
  if resolved != root and not resolved.startsWith(rootPrefix):
    raiseRequestError("Invalid static asset path.")

proc handleIndex(): EditorResponse =
  let path = EditorAssetDir / "index.html"
  if path.fileExists():
    try:
      path.ensureAssetInsideRoot()
      return EditorResponse(
        status: 200,
        contentType: "text/html; charset=utf-8",
        body: path.readFile()
      )
    except CtfError, OSError:
      discard
  EditorResponse(
    status: 200,
    contentType: "text/html; charset=utf-8",
    body: """<!doctype html>
<html><head><title>CTF Map Editor</title></head>
<body><h1>CTF Map Editor</h1>
<p>The editor browser assets are not present yet.</p></body></html>"""
  )

proc handleStatic(path: string): EditorResponse =
  try:
    let filePath = safeAssetPath(path)
    if not filePath.fileExists():
      return EditorResponse(
        status: 404,
        contentType: "text/plain; charset=utf-8",
        body: "Static asset not found."
      )
    filePath.ensureAssetInsideRoot()
    EditorResponse(
      status: 200,
      contentType: mimeType(filePath),
      body: filePath.readFile()
    )
  except CtfError as e:
    errorResponse(e.msg, 404)
  except OSError:
    EditorResponse(
      status: 404,
      contentType: "text/plain; charset=utf-8",
      body: "Static asset not found."
    )

proc handleEditorRequest*(
  httpMethod, path, body: string
): EditorResponse =
  ## Routes one request without a socket so the complete API boundary is
  ## deterministic and directly unit-testable.
  if body.len > MapEditorMaxBodyBytes:
    return errorResponse(
      "Request body exceeds the 2 MiB limit.", status = 413
    )
  case path
  of "/":
    if httpMethod != "GET":
      return errorResponse("Method not allowed.", 405)
    handleIndex()
  of "/api/map":
    if httpMethod != "POST":
      return errorResponse("Method not allowed.", 405)
    handleMap(body)
  of "/api/generate":
    if httpMethod != "POST":
      return errorResponse("Method not allowed.", 405)
    handleGenerate(body)
  of "/api/symmetry":
    if httpMethod != "POST":
      return errorResponse("Method not allowed.", 405)
    handleSymmetry(body)
  of "/api/pool":
    if httpMethod != "GET":
      return errorResponse("Method not allowed.", 405)
    handlePoolList()
  else:
    if path.startsWith("/api/pool/"):
      if httpMethod != "GET":
        return errorResponse("Method not allowed.", 405)
      return handlePoolEntry(path["/api/pool/".len .. ^1])
    if path.startsWith("/static/"):
      if httpMethod != "GET":
        return errorResponse("Method not allowed.", 405)
      return handleStatic(path["/static/".len .. ^1])
    errorResponse("Not found.", 404)

when isMainModule:
  import mummy

  const
    DefaultMapEditorHost = "127.0.0.1"
    DefaultMapEditorPort = 8080

  proc requestHandler(request: Request) {.gcsafe.} =
    var response: EditorResponse
    {.gcsafe.}:
      response = handleEditorRequest(
        request.httpMethod, request.path, request.body
      )
    request.respond(
      response.status,
      @[
        ("Content-Type", response.contentType),
        ("Cache-Control", "no-store"),
      ],
      response.body
    )

  proc environmentOr(name, default: string): string =
    let value = getEnv(name)
    if value.len > 0: value else: default

  proc parsePort(text: string): int =
    try:
      result = parseInt(text)
    except ValueError:
      raiseRequestError("Map editor port must be an integer.")
    if result < 1 or result > 65535:
      raiseRequestError("Map editor port must be 1..65535.")

  let
    portText =
      if paramCount() >= 1: paramStr(1)
      else: environmentOr("MAP_EDITOR_PORT", $DefaultMapEditorPort)
    host =
      if paramCount() >= 2: paramStr(2)
      else: environmentOr("MAP_EDITOR_HOST", DefaultMapEditorHost)
  if paramCount() > 2:
    stderr.writeLine("Usage: map_editor [port] [host]")
    quit(1)
  try:
    let
      port = parsePort(portText)
      server = newServer(
        requestHandler,
        workerThreads = 1,
        maxBodyLen = MapEditorMaxBodyBytes
      )
    echo "Serving CTF map editor on http://", host, ":", port
    server.serve(Port(port), host)
  except CtfError as e:
    stderr.writeLine(e.msg)
    quit(1)
