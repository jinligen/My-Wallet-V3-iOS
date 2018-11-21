//
//  NetworkRequest.swift
//  Blockchain
//
//  Created by Alex McGregor on 8/28/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import RxSwift

typealias HTTPHeaders = [String: String]

/// TICKET: IOS-1242 - Condense HttpHeaderField
/// and HttpHeaderValue into enums and inject in a token
struct NetworkRequest {
    
    enum NetworkError: Error {
        case generic
    }
    
    enum NetworkMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }
    
    let method: NetworkMethod
    let endpoint: URL
    let headers: HTTPHeaders?

    // TODO: modify this to be an Encodable type so that JSON serialization is done in this class
    // vs. having to serialize outside of this class
    let body: Data?

    // Deprecate this field in favor of headers (i.e. the token should be passed in as an
    // element in `headers`
    let token: String?

    private let session: URLSession? = {
        guard let session = NetworkManager.shared.session else { return nil }
        return session
    }()
    private var task: URLSessionDataTask?
    
    init(endpoint: URL, method: NetworkMethod, body: Data?, authToken: String? = nil, headers: HTTPHeaders? = nil) {
        self.endpoint = endpoint
        self.token = authToken
        self.method = method
        self.body = body
        self.headers = headers
    }
    
    func URLRequest() -> URLRequest? {
        let request: NSMutableURLRequest = NSMutableURLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30.0
        )
        
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = [HttpHeaderField.contentType: HttpHeaderValue.json,
                                       HttpHeaderField.accept: HttpHeaderValue.json]
        if let auth = token {
            request.addValue(
                auth,
                forHTTPHeaderField: HttpHeaderField.authorization
            )
        }

        if let headers = headers {
            headers.forEach {
                request.addValue($1, forHTTPHeaderField: $0)
            }
        }
        
        if let data = body {
            request.httpBody = data
        }
        
        return request.copy() as? URLRequest
    }

    // swiftlint:disable:next function_body_length
    fileprivate mutating func execute<T: Decodable>(expecting: T.Type, withCompletion: @escaping ((Result<T>, _ responseCode: Int) -> Void)) {
        let responseCode: Int = 0
        
        guard let urlRequest = URLRequest() else {
            withCompletion(.error(nil), responseCode)
            return
        }
        guard let session = session else {
            withCompletion(.error(nil), responseCode)
            return
        }

        // Debugging
        Logger.shared.debug("Sending \(urlRequest.httpMethod ?? "") request to '\(urlRequest.url?.absoluteString ?? "")'")
        if let body = urlRequest.httpBody,
            let bodyString = String(data: body, encoding: .utf8) {
            Logger.shared.debug("Body: \(bodyString)")
        }

        task = session.dataTask(with: urlRequest) { payload, response, error in

            if let error = error {
                withCompletion(.error(HTTPRequestClientError.failedRequest(description: error.localizedDescription)), responseCode)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                withCompletion(.error(HTTPRequestServerError.badResponse), responseCode)
                return
            }

            guard let responseData = payload else {
                withCompletion(.error(HTTPRequestPayloadError.emptyData), responseCode)
                return
            }

            // Debugging
            if let responseString = String(data: responseData, encoding: .utf8) {
                Logger.shared.debug("Response received: \(responseString)")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(NabuNetworkError.self, from: responseData)
                let errorStatusCode = HTTPRequestServerError.badStatusCode(code: httpResponse.statusCode, error: errorPayload)
                withCompletion(.error(errorStatusCode), httpResponse.statusCode)
                return
            }

            // No need to decode if desired type is Void
            guard T.self != EmptyNetworkResponse.self else {
                let emptyResponse: T = EmptyNetworkResponse() as! T
                withCompletion(.success(emptyResponse), httpResponse.statusCode)
                return
            }

            if let payload = payload, error == nil {
                do {
                    Logger.shared.debug("Received payload: \(String(data: payload, encoding: .utf8) ?? "")")
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    let final = try decoder.decode(T.self, from: payload)
                    withCompletion(.success(final), httpResponse.statusCode)
                } catch let decodingError {
                    Logger.shared.debug("Payload decoding error: \(decodingError)")
                    withCompletion(.error(HTTPRequestPayloadError.badData), httpResponse.statusCode)
                }
            }
        }
        
        task?.resume()
    }
    
    static func POST(url: URL, body: Data?) -> NetworkRequest {
        return self.init(endpoint: url, method: .post, body: body)
    }
    
    static func PUT(url: URL, body: Data?) -> NetworkRequest {
        return self.init(endpoint: url, method: .put, body: body)
    }
    
    static func DELETE(url: URL) -> NetworkRequest {
        return self.init(endpoint: url, method: .delete, body: nil)
    }
}

// MARK: - Rx

extension NetworkRequest {

    static func GET<ResponseType: Decodable>(
        url: URL,
        body: Data? = nil,
        token: String? = nil,
        type: ResponseType.Type
    ) -> Single<ResponseType> {
        var request = self.init(endpoint: url, method: .get, body: body, authToken: token)
        return Single.create(subscribe: { observer -> Disposable in
            request.execute(expecting: ResponseType.self, withCompletion: { result, _ in
                switch result {
                case .success(let value):
                    observer(.success(value))
                case .error(let error):
                    observer(.error(error ?? NetworkError.generic))
                }
            })
            return Disposables.create()
        })
    }

    static func POST(
        url: URL,
        body: Data?,
        headers: HTTPHeaders? = nil
    ) -> Completable {
        var request = self.init(endpoint: url, method: .post, body: body, headers: headers)
        return Completable.create(subscribe: { observer -> Disposable in
            request.execute(expecting: EmptyNetworkResponse.self, withCompletion: { result, _ in
                switch result {
                case .success(_):
                    observer(.completed)
                case .error(let error):
                    observer(.error(error ?? NetworkError.generic))
                }
            })
            return Disposables.create()
        })
    }

    static func POST<ResponseType: Decodable>(
        url: URL,
        body: Data?,
        token: String?,
        type: ResponseType.Type,
        headers: HTTPHeaders? = nil
    ) -> Single<ResponseType> {
        var request = self.init(endpoint: url, method: .post, body: body, authToken: token, headers: headers)
        return Single.create(subscribe: { observer -> Disposable in
            request.execute(expecting: ResponseType.self, withCompletion: { result, _ in
                switch result {
                case .success(let value):
                    observer(.success(value))
                case .error(let error):
                    observer(.error(error ?? NetworkError.generic))
                }
            })
            return Disposables.create()
        })
    }

    static func PUT<ResponseType: Decodable>(
        url: URL,
        body: Data?,
        token: String?,
        type: ResponseType.Type,
        headers: HTTPHeaders? = nil
    ) -> Single<ResponseType> {
        var request = self.init(endpoint: url, method: .put, body: body, authToken: token, headers: headers)
        return Single.create(subscribe: { observer -> Disposable in
            request.execute(expecting: ResponseType.self, withCompletion: { result, _ in
                switch result {
                case .success(let value):
                    observer(.success(value))
                case .error(let error):
                    observer(.error(error ?? NetworkError.generic))
                }
            })
            return Disposables.create()
        })
    }
}
