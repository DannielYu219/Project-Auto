//
//  LinuxHelperProtocol.swift
//  VelumLinuxHelper
//
//  主 App 与 XPC helper 之间的协议。
//  命令用 start/poll 两段式：start 立即返回 token，App 轮询增量输出，
//  这样长命令不会阻塞 XPC 调用，也能实时看到进度。
//

import Foundation

@objc public protocol LinuxHelperProtocol {
    func startExec(command: String,
                   packPath: String,
                   workspacePath: String,
                   timeout: Double,
                   reply: @escaping (String) -> Void)

    func pollExec(token: String,
                  reply: @escaping (String, Bool, String, String, Int32, Bool) -> Void)

    func configureMounts(packPath: String, workspacePath: String, mounts: Data,
                         reply: @escaping (String?) -> Void)
    func splitEngineRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void)
    func localRuntimeRequest(requestJSON: String, reply: @escaping (String?, String?) -> Void)
    func stop(reply: @escaping () -> Void)
}
