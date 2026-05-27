import Foundation

enum Config {
    static let viewerHost = "https://waza-proto.vercel.app"
    static let publisherHost = "https://waza-proto.vercel.app"

    static func viewerURL(invite: String) -> URL {
        URL(string: "\(viewerHost)/?invite=\(invite)")!
    }

    static func publisherTokenURL(auth: String) -> URL {
        URL(string: "\(publisherHost)/api/publisher-token?auth=\(auth)")!
    }
}
