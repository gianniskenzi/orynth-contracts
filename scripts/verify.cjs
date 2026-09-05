const fs = require("node:fs")
const path = require("node:path")

async function main() {
  const [address, flag] = process.argv.slice(2)
  if (!/^0x[0-9a-fA-F]{40}$/.test(address || "") || (flag && flag !== "--submit")) {
    throw new Error("Usage: node scripts/verify.cjs <address> [--submit]")
  }
  const root = path.resolve(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "deployments/robinhood-mainnet.json")))
  const record = manifest.contracts.find(item => item.address.toLowerCase() === address.toLowerCase())
  if (!record?.artifactMatch || !record.build) throw new Error("No matching artifact recorded for this address")
  const builds = JSON.parse(fs.readFileSync(path.join(root, "builds.json")))
  const build = builds.find(item => item.standardJsonInput === record.build)
  if (!build) throw new Error("Build metadata is missing")
  const inputPath = path.resolve(root, record.build)
  if (!inputPath.startsWith(root + path.sep)) throw new Error("Invalid build path")
  const input = fs.readFileSync(inputPath, "utf8")
  const digest = require("node:crypto").createHash("sha256").update(input).digest("hex")
  if (digest !== build.sha256) throw new Error("Compiler input checksum mismatch")
  const url = `${manifest.explorer}/api/v2/smart-contracts/${address}/verification/via/standard-input`
  console.log(JSON.stringify({chainId:manifest.chainId, address, contract:`${record.source}:${record.name}`,
    compiler:build.compilerVersion, input:record.build, destination:url, submit:flag==="--submit"},null,2))
  if (flag !== "--submit") return
  const body = new FormData()
  body.set("compiler_version", `v${build.compilerVersion}`)
  body.set("contract_name", record.name)
  body.set("autodetect_constructor_args", "true")
  body.set("license_type", "mit")
  body.set("files[0]",new Blob([input],{type:"application/json"}),path.basename(inputPath))
  const response = await fetch(url,{method:"POST",body,signal:AbortSignal.timeout(60000)})
  if (response.status===403) throw new Error("Blockscout denied API access. Use its browser verification form.")
  const text = await response.text()
  if (!response.ok) throw new Error(`Blockscout returned HTTP ${response.status}: ${text.slice(0,500)}`)
  console.log(text.slice(0,1000))
  console.log(`Submission accepted. Confirm the final verification result at ${manifest.explorer}/address/${address}?tab=contract`)
}
main().catch(error=>{console.error(error.message);process.exitCode=1})
