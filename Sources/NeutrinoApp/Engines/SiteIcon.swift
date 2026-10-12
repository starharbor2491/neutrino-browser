// SPDX-License-Identifier: MPL-2.0
import Foundation
import ImageIO
import UniformTypeIdentifiers
import NeutrinoCore

/// Fetches only public site identity, with no profile cookies or stored credentials.
/// Raster decoding and the request are bounded; arbitrary SVG never enters the UI.
enum SiteIcon {
    static func load(for page: URL) async -> String? {
        guard AddressResolver.isWebURL(page), !ContentBlocking.blocks(page), var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: SiteIconRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= 131_072 else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 131_072 else { return nil }; data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:32, kCGImageSourceShouldCache:false] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination), output.length < 8192 else { return nil }
            return "data:image/png;base64," + (output as Data).base64EncodedString()
        } catch { return nil }
    }
}

// Public identity fetches never follow redirects into another origin or tracker.
private final class SiteIconRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
