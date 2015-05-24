import Foundation

public struct Endpoint{
  let method:Verb
  let path:String

  public init(method:Verb = .GET, path:String?){
    self.method = method
    self.path = path ?? "/"
  }
  
  public init(method:String?, path:String?){
    let verb = Verb(rawValue: method?.uppercaseString ?? "GET") ?? .GET
    self.init(method:verb, path:path)
  }
}

extension Endpoint : Hashable{
  public var hashValue:Int{
    return path.hashValue ^ method.hashValue
  }
}

public func ==(lhs: Endpoint, rhs: Endpoint) -> Bool {
  return lhs.method == rhs.method && lhs.path == rhs.path
}