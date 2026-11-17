import Foundation
import WindowfolkArtIO

// 只负责把 CommandRouter 返回的 ExitStatus 转成进程退出码（R9.7）。
let status = await CommandRouter.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: .live())
exit(status.rawValue)
