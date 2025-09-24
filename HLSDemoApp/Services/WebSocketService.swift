//
//  WebSocketService.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/23.
//

import Foundation

extension URLSessionWebSocketTask.CloseCode {
    nonisolated
    var displayString: String {
        switch self {
            
        case .invalid:
            "invalid"
        case .normalClosure:
            "normalClosure"
        case .goingAway:
            "goingAway"
        case .protocolError:
            "protocolError"
        case .unsupportedData:
            "unsupportedData"
        case .noStatusReceived:
            "noStatusReceived"
        case .abnormalClosure:
            "abnormalClosure"
        case .invalidFramePayloadData:
            "invalidFramePayloadData"
        case .policyViolation:
            "policyViolation"
        case .messageTooBig:
            "messageTooBig"
        case .mandatoryExtensionMissing:
            "mandatoryExtensionMissing"
        case .internalServerError:
            "internalServerError"
        case .tlsHandshakeFailure:
            "tlsHandshakeFailure"
        @unknown default:
            "unknown close code"
        }
    }
}

extension Error {
    // error: Error Domain=NSPOSIXErrorDomain Code=57 "Socket is not connected" UserInfo={NSErrorFailingURLStringKey=ws://127.0.0.1:3000/web_socket, NSErrorFailingURLKey=ws://127.0.0.1:3000/web_socket}
    // in this case, we will receive the close code and reason within the delegate function, so we will ignore this error
    nonisolated
    var isSocketNotConnectedError: Bool {
        let error = self as NSError
        guard error.domain == NSPOSIXErrorDomain else {
            return false
        }
        // POSIXError.ENOTCONN: 57
        // https://developer.apple.com/documentation/foundation/posixerror/enotconn
        guard error.code == POSIXError.ENOTCONN.rawValue else {
            return false
        }
        return true
        
    }
}

nonisolated
extension WebSocketService {
    nonisolated
    enum WebSocketError: Error {
        case invalidURL
        case webSocketTaskUndefined
        case connectionClosed(URLSessionWebSocketTask.CloseCode, String)
    }
    
    nonisolated
    enum ConnectionState: Sendable {
        case notConnected
        case connecting
        case connected
    }
}



nonisolated
class WebSocketService: NSObject, @unchecked Sendable {
    var onError: ((Error) -> Void)?
    
    private(set) var connectionState: ConnectionState = .notConnected
    
    private var webSocketTask: URLSessionWebSocketTask?
        
    private let urlSession: URLSession = .shared

    
    deinit {
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.urlSession.finishTasksAndInvalidate()
    }
    
    
    // URL: has to be either `ws` or `wss` scheme
    func connect(to endpointURL: String, httpMethod: String = "GET") async throws {
        print(#function)
        guard let url = URL(string: endpointURL) else {
            throw WebSocketError.invalidURL
        }
        self.disconnect()
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = httpMethod
        
        self.webSocketTask = self.urlSession.webSocketTask(with: urlRequest)
        self.webSocketTask?.delegate = self
        self.webSocketTask?.resume()
        // we won't know whether if we are actually connected, ie: handshake completes,
        // until we receive the notifications through the session’s delegate
        self.connectionState = .connecting
        print("Connecting to \(endpointURL).")
        
        while self.connectionState == .connecting {
            try await Task.sleep(for: .milliseconds(50))
        }
        
        print("connected")
    }
    
    func disconnect() {
        print(#function)
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.connectionState = .notConnected
    }
    
    func send(_ string: String) async throws {
        print(#function)

        guard let webSocketTask = self.webSocketTask else {
            throw WebSocketError.webSocketTaskUndefined
        }
        try await webSocketTask.send(.string(string))
        print("Message Send with success")
    }

}


nonisolated
extension WebSocketService: URLSessionWebSocketDelegate {
    // Tells the delegate that the WebSocket task successfully negotiated the handshake with the endpoint, indicating the negotiated protocol.
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print(#function)
        if self.connectionState == .connecting, webSocketTask == self.webSocketTask {
            self.connectionState = .connected
        }
    }
    
    // Tells the delegate that the WebSocket task received a close frame from the server endpoint, optionally including a close code and reason from the server.
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print(#function)

        print("Close code: \(closeCode.displayString)")
        if let reason {
            print("Reason: \(String(describing: String(data: reason, encoding: .utf8)))")
        }
        // connection lost due to server close
        if self.connectionState == .connected, webSocketTask == self.webSocketTask {
            self.disconnect()
            let error = WebSocketError.connectionClosed(closeCode, String(data: reason ?? Data("".utf8), encoding: .utf8) ?? "unknown")
            self.onError?(error)
        }
    }
}

