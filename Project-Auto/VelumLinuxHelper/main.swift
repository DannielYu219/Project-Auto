//
//  main.swift
//  VelumLinuxHelper
//

import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperPeerValidation.accepts(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: LinuxHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
