@preconcurrency import Network
import Foundation

public enum SpatialBridgeConnectionState: Equatable, Sendable {
    case stopped
    case searching
    case connecting
    case connected(peerCount: Int)
    case failed(String)
}

public final class LocalSpatialBridgeServer: @unchecked Sendable {
    public static let serviceType = "_spatialbridge._tcp"

    public var onEnvelope: (@Sendable (SpatialBridgeEnvelope) -> Void)?
    public var onStateChange: (@Sendable (SpatialBridgeConnectionState) -> Void)?

    private let queue = DispatchQueue(label: "SpatialBridge.server")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    public init() {}

    public func start(serviceName: String) throws {
        stop()
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(
                    self.connectionCount == 0 ? .searching : .connected(peerCount: self.connectionCount)
                )
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        onStateChange?(.searching)
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        activeConnections.forEach { $0.cancel() }
        onStateChange?(.stopped)
    }

    public func send(_ envelope: SpatialBridgeEnvelope) throws {
        let data = try SpatialBridgeFrameDecoder.encode(encoder.encode(envelope))
        lock.lock()
        let activeConnections = Array(connections.values)
        lock.unlock()
        for connection in activeConnections {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        connections[identifier] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.onStateChange?(.connected(peerCount: self.connectionCount))
                self.receive(on: connection, decoderState: SpatialBridgeFrameDecoder())
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, decoderState: SpatialBridgeFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var nextState = decoderState
            if let data, !data.isEmpty {
                do {
                    for frame in try nextState.append(data) {
                        let envelope = try self.decoder.decode(SpatialBridgeEnvelope.self, from: frame)
                        self.onEnvelope?(envelope)
                    }
                } catch {
                    connection.cancel()
                    self.remove(connection)
                    return
                }
            }
            if isComplete || error != nil {
                self.remove(connection)
            } else {
                self.receive(on: connection, decoderState: nextState)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        let count = connections.count
        lock.unlock()
        onStateChange?(count == 0 ? .searching : .connected(peerCount: count))
    }
}

public final class LocalSpatialBridgeClient: @unchecked Sendable {
    public var onEnvelope: (@Sendable (SpatialBridgeEnvelope) -> Void)?
    public var onStateChange: (@Sendable (SpatialBridgeConnectionState) -> Void)?

    private let queue = DispatchQueue(label: "SpatialBridge.client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var browser: NWBrowser?
    private var connection: NWConnection?

    public init() {}

    public func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjour(type: LocalSpatialBridgeServer.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.stopped)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let result = results.first else { return }
            self.connect(to: result.endpoint)
        }
        self.browser = browser
        onStateChange?(.searching)
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        onStateChange?(.stopped)
    }

    public func send(_ envelope: SpatialBridgeEnvelope) throws {
        guard let connection else { return }
        let data = try SpatialBridgeFrameDecoder.encode(encoder.encode(envelope))
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func connect(to endpoint: NWEndpoint) {
        browser?.cancel()
        browser = nil
        onStateChange?(.connecting)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.onStateChange?(.connected(peerCount: 1))
                self.receive(on: connection, decoderState: SpatialBridgeFrameDecoder())
            case .failed(let error):
                self.connection = nil
                self.onStateChange?(.failed(error.localizedDescription))
                self.start()
            case .cancelled:
                self.connection = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, decoderState: SpatialBridgeFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var nextState = decoderState
            if let data, !data.isEmpty {
                do {
                    for frame in try nextState.append(data) {
                        let envelope = try self.decoder.decode(SpatialBridgeEnvelope.self, from: frame)
                        self.onEnvelope?(envelope)
                    }
                } catch {
                    connection.cancel()
                    self.connection = nil
                    self.start()
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.connection = nil
                self.start()
            } else {
                self.receive(on: connection, decoderState: nextState)
            }
        }
    }
}
