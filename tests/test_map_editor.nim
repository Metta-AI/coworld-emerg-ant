import
  std/[base64, json, strutils, unittest],
  ctf/[map_pool, sim],
  "../tools/map_editor"

proc responseJson(response: EditorResponse): JsonNode =
  check response.contentType.startsWith("application/json")
  try:
    result = parseJson(response.body)
  except JsonParsingError:
    check false
    result = newJNull()

proc smallMapSpec(): JsonNode =
  let gameMap = generateMapAttempt(
    1001,
    MapGenOverrides(
      size: "small",
      windows: -1,
      pits: -1,
      pitDensity: -1,
    ),
  )
  parseJson(mapSpecJson(gameMap))

proc mapRequest(spec: JsonNode, overlays: seq[string] = @[]): string =
  var overlayNodes = newJArray()
  for overlay in overlays:
    overlayNodes.add %overlay
  $(%*{
    "spec": spec,
    "render": {
      "maxDimension": 160,
      "overlays": overlayNodes,
    },
  })

proc symmetrySpec(symmetry: string): JsonNode =
  let
    teams = if symmetry == "rot90": 4 else: 2
    gameMap = generateMapAttempt(
      1001,
      MapGenOverrides(
        size: "small",
        symmetry: symmetry,
        windows: -1,
        pits: -1,
        pitDensity: -1,
      ),
      teams,
    )
  parseJson(mapSpecJson(gameMap))

proc symmetryRequest(spec, trenches, medKits: JsonNode): string =
  $(%*{
    "spec": spec,
    "trenches": trenches,
    "medKits": medKits,
  })

suite "map editor service":
  test "POST /api/map returns the complete map response":
    let
      spec = smallMapSpec()
      response = handleEditorRequest(
        "POST",
        "/api/map",
        mapRequest(spec, @[
          "protected", "pickups", "spin", "seedRegion",
          "sightlines", "reachability",
        ]),
      )
      body = response.responseJson()
    check response.status == 200
    check body["ok"].getBool()
    check body["renderScale"].getFloat() > 0
    let png = decode(body["png"].getStr())
    check png.len > 8
    check png[0 .. 7] == "\x89PNG\r\n\x1a\n"

    let validation = body["validation"]
    check validation["valid"].kind == JBool
    check validation["reason"].kind == JString
    check validation["coverPermille"].kind == JInt
    check validation["minCoverPermille"].kind == JInt
    check validation["coverPermilleMin"].getInt() == 40
    check validation["coverPermilleMax"].getInt() == 170
    check validation["openSightlineRows"].kind == JArray
    check validation["unreachableTeams"].kind == JArray
    check validation["centerReachable"].kind == JBool
    check validation["endzoneGates"].kind == JArray

    let
      gameMap = mapFromSpecJson($spec)
      derived = body["derived"]
      expanded = buildArenaObstacles(gameMap)
    check derived["teamCount"].getInt() == gameMap.teamCount()
    for field in ["x", "y", "w", "h"]:
      check derived["seedRegion"][field].kind == JInt
    check derived["anchors"].len == gameMap.teamCount()
    check derived["captureZones"].len == gameMap.teamCount()
    check derived["pickups"]["grenade"].len == 4
    check derived["pickups"]["shield"].len == gameMap.teamCount()
    check derived["pickups"]["plasmaArc"].len == gameMap.teamCount()
    check derived["pickups"]["medKitActive"].len ==
      gameMap.medKitSpawns.len
    check derived["pickups"]["medKitCandidate"].len ==
      gameMap.medKitCandidates.len
    check derived["authoredObstacleCount"].getInt() ==
      gameMap.leftObstacles.len
    check derived["expandedObstacleCount"].getInt() == expanded.len

    for zoneNode in derived["captureZones"]:
      for field in [
        "xLo", "xHi", "yLo", "yHi", "diag", "cornerX", "cornerY",
        "diagLimit", "disc", "anchorX", "anchorY", "radius",
      ]:
        check zoneNode.hasKey(field)

  test "map requests never install request geometry into process globals":
    let
      widthBefore = MapWidth
      heightBefore = MapHeight
      obstaclesBefore = ArenaObstacles
      response = handleEditorRequest(
        "POST", "/api/map", mapRequest(smallMapSpec())
      )
    check response.status == 200
    check response.responseJson()["ok"].getBool()
    check MapWidth == widthBefore
    check MapHeight == heightBefore
    check ArenaObstacles == obstaclesBefore

  test "POST /api/map reports malformed editing states as JSON":
    for requestBody in [
      "not json",
      "{}",
      $(%*{"spec": "not an object"}),
      $(%*{"spec": {"name": "missing the required fields"}}),
    ]:
      let
        response = handleEditorRequest("POST", "/api/map", requestBody)
        body = response.responseJson()
      check response.status == 200
      check not body["ok"].getBool()
      check body["error"].getStr().len > 0

  test "map request enforces render and allocation limits":
    var spec = smallMapSpec()
    spec["width"] = %(MapEditorMaxDimension + 1)
    var response = handleEditorRequest("POST", "/api/map", mapRequest(spec))
    check response.status == 200
    check not response.responseJson()["ok"].getBool()

    response = handleEditorRequest(
      "POST",
      "/api/map",
      $(%*{
        "spec": smallMapSpec(),
        "render": {"maxDimension": -1, "overlays": []},
      }),
    )
    check response.status == 200
    check not response.responseJson()["ok"].getBool()

    response = handleEditorRequest(
      "POST",
      "/api/map",
      $(%*{
        "spec": smallMapSpec(),
        "render": {"overlays": ["browserGeometry"]},
      }),
    )
    check response.status == 200
    check not response.responseJson()["ok"].getBool()

  test "POST /api/generate supports validated and raw generation":
    for validated in [false, true]:
      let
        response = handleEditorRequest(
          "POST",
          "/api/generate",
          $(%*{
            "seed": 1001,
            "teams": 2,
            "overrides": {"size": "small"},
            "validated": validated,
          }),
        )
        body = response.responseJson()
      check response.status == 200
      check body["ok"].getBool()
      check body["spec"].kind == JObject
      check body["spec"]["width"].getInt() == 1050

  test "POST /api/generate validates request fields":
    for requestBody in [
      "{}",
      $(%*{"seed": 1, "teams": 3}),
      $(%*{"seed": 1, "overrides": {"windows": "many"}}),
      $(%*{"seed": 1, "overrides": {"mystery": 1}}),
    ]:
      let
        response = handleEditorRequest(
          "POST", "/api/generate", requestBody
        )
        body = response.responseJson()
      check response.status == 200
      check not body["ok"].getBool()
      check body["error"].getStr().len > 0

  test "POST /api/symmetry expands named placements in input order":
    let
      spec = symmetrySpec("rot180")
      gameMap = mapFromSpecJson($spec)
      response = handleEditorRequest(
        "POST",
        "/api/symmetry",
        symmetryRequest(
          spec,
          %*[[20, 30, 7, 9], [100, 120, 11, 13]],
          %*[[30, 40], [200, 220]],
        ),
      )
      body = response.responseJson()
    check response.status == 200
    check body["ok"].getBool()
    check body["trenches"].len == 2
    check body["medKits"].len == 2
    check body["trenches"][0][0] == %*[20, 30, 7, 9]
    check body["trenches"][0][1] == %*[
      gameMap.width - 27,
      gameMap.height - 39,
      7,
      9,
    ]
    check body["trenches"][1][0] == %*[100, 120, 11, 13]
    check body["medKits"][0][0] == %*[30, 40]
    check body["medKits"][0][1] == %*[
      gameMap.width - 1 - 30,
      gameMap.height - 1 - 40,
    ]
    check body["medKits"][1][0] == %*[200, 220]

  test "POST /api/symmetry allows med kits but refuses trenches on rot90":
    let spec = symmetrySpec("rot90")
    var response = handleEditorRequest(
      "POST",
      "/api/symmetry",
      symmetryRequest(spec, %*[], %*[[30, 40]]),
    )
    var body = response.responseJson()
    check response.status == 200
    check body["ok"].getBool()
    check body["trenches"].len == 0
    check body["medKits"].len == 1
    check body["medKits"][0].len == 4
    check body["medKits"][0][0] == %*[30, 40]

    response = handleEditorRequest(
      "POST",
      "/api/symmetry",
      symmetryRequest(spec, %*[[20, 30, 7, 9]], %*[]),
    )
    body = response.responseJson()
    check response.status == 200
    check not body["ok"].getBool()
    check body["error"].getStr() ==
      "Trenches are not supported on 4-team maps yet."

  test "POST /api/symmetry validates its editing boundary":
    let spec = symmetrySpec("mirror")
    for requestBody in [
      "{}",
      $(%*{"spec": spec, "medKits": []}),
      $(%*{"spec": spec, "trenches": []}),
      symmetryRequest(spec, %*{}, %*[]),
      symmetryRequest(spec, %*[], %*{}),
      symmetryRequest(spec, %*[[1, 2, 3]], %*[]),
      symmetryRequest(spec, %*[[1, 2, "wide", 4]], %*[]),
      symmetryRequest(spec, %*[[1, 2, 0, 4]], %*[]),
      symmetryRequest(spec, %*[[-1, 2, 3, 4]], %*[]),
      symmetryRequest(spec, %*[[1048, 2, 3, 4]], %*[]),
      symmetryRequest(spec, %*[], %*[[1, 2, 3]]),
      symmetryRequest(spec, %*[], %*[["left", 2]]),
      symmetryRequest(spec, %*[], %*[[-1, 2]]),
      symmetryRequest(spec, %*[], %*[[1050, 2]]),
    ]:
      let
        response = handleEditorRequest(
          "POST", "/api/symmetry", requestBody
        )
        body = response.responseJson()
      check response.status == 200
      check not body["ok"].getBool()
      check body["error"].getStr().len > 0

  test "pool endpoints expose exact curated entries with strict bounds":
    var response = handleEditorRequest("GET", "/api/pool", "")
    var body = response.responseJson()
    check response.status == 200
    check body["count"].getInt() == MapPoolSeeds.len
    check body["seeds"].len == MapPoolSeeds.len
    for i, seed in MapPoolSeeds:
      check body["seeds"][i].getInt() == seed

    response = handleEditorRequest("GET", "/api/pool/0", "")
    body = response.responseJson()
    check response.status == 200
    check body["ok"].getBool()
    check body["spec"]["genSeed"].getInt() == MapPoolSeeds[0]

    for path in ["/api/pool/nope", "/api/pool/-1", "/api/pool/20"]:
      response = handleEditorRequest("GET", path, "")
      body = response.responseJson()
      check response.status == 200
      check not body["ok"].getBool()

  test "routing, body limits, and static paths fail clearly":
    var response = handleEditorRequest("GET", "/", "")
    check response.status == 200
    check response.contentType.startsWith("text/html")

    response = handleEditorRequest("GET", "/static/editor.css", "")
    check response.status == 200
    check response.contentType.startsWith("text/css")
    check response.body.len > 0

    response = handleEditorRequest("GET", "/static/does-not-exist.js", "")
    check response.status == 404

    response = handleEditorRequest("GET", "/static/../arena.nim", "")
    check response.status == 404
    check not response.responseJson()["ok"].getBool()

    response = handleEditorRequest("GET", "/api/map", "")
    check response.status == 405

    response = handleEditorRequest("GET", "/api/symmetry", "")
    check response.status == 405

    response = handleEditorRequest("GET", "/does-not-exist", "")
    check response.status == 404

    response = handleEditorRequest(
      "POST", "/api/map", repeat('x', MapEditorMaxBodyBytes + 1)
    )
    check response.status == 413
    check not response.responseJson()["ok"].getBool()
