import Foundation

enum Config {
    static let viewerHost = "https://waza-proto.vercel.app"

    static func viewerURL(invite: String) -> URL {
        URL(string: "\(viewerHost)/?invite=\(invite)")!
    }
}
