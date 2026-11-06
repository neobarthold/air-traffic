import AirTrafficCore
import Foundation

// `airtraffic` (SPEC §24): dünne Hülle um `AgentCLI` und `MCPServer` aus dem Core.
// Liest/schreibt nur die Konfiguration (AIRTRAFFIC_CONFIG_PATH beachtet); kein Netzwerk,
// kein Schlüsselbund, öffnet nichts.

setvbuf(stdout, nil, _IOLBF, 0)

let version = ToolVersion.current
let api = AgentAPI(store: .makeDefault(), resolver: WorkspaceAppResolver())
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["mcp"] {
    let server = MCPServer(api: api, version: version)
    FileHandle.standardError.write(Data("airtraffic \(version): MCP-Server bereit (stdio), Konfiguration \(api.store.fileURL.path(percentEncoded: false))\n".utf8))
    while let line = readLine(strippingNewline: true) {
        if let response = server.handle(line: line) {
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }
    exit(0)
}

let io = AgentCLI.IO(
    readStdin: {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    },
    out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
    err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
)
exit(AgentCLI(api: api, version: version).run(arguments, io: io))
