include "../players/baseline/baseline/taunts"

putEnv("COWORLD_LLM_ENDPOINT", paramStr(1))
putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
let pool = newCurlPool(1)
doAssert pool.invokeLlm("rules", "state", 16) == "NATIVE"
pool.close()
echo "Native taunt HTTP passed"
