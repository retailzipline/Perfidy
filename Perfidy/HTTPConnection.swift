import Foundation
import Gauntlet



private enum Const {
  static let timeout: CFTimeInterval = 10.0
}



internal class HTTPConnection : NSObject {
  internal struct HTTPConnectionCallbacks{
    var whenFinishesRequest: ((_ req:URLRequest)->Void)?
    var whenFinishesResponse: (()->Void)?
    var whenNeedsResponseForRoute: ((Route)->Response?)?
  }
  internal var callback = HTTPConnectionCallbacks()
  internal var defaultStatusCode = 200
  fileprivate let socket:GCDAsyncSocket
  fileprivate lazy var machine: StateMachine<State> = self.makeMachine()
  
  init(socket:GCDAsyncSocket){
    self.socket = socket
    super.init()
    self.socket.setDelegate(self, delegateQueue: DispatchQueue.main)
    machine.queue(.readingHead(HTTPMessage()))
  }
}



private extension HTTPConnection{
  func readHead(){
    socket.readData(to: GCDAsyncSocket.crlfData(), withTimeout: Const.timeout, tag:0)
  }
  
  
  func readBodyOfLength(_ length:UInt){
    //This is a no-op when «length» is 0.
    socket.readData(toLength: length, withTimeout: Const.timeout, tag:0)
  }
  
  
  func respondToMessage(_ message:HTTPMessage){
    let route = Route(method: message.method, path: message.url?.path)
    //Not only is the callback optional, but it can return a nil response.
    let response = callback.whenNeedsResponseForRoute?(route) ?? Response(status: defaultStatusCode, data: nil)
    machine.queue(.writingResponse(HTTPMessage(response: response)))
  }
  
  
  func writeResponse(_ message:HTTPMessage){
    guard let someData = message.data else {
      return
    }
    socket.write(someData, withTimeout: Const.timeout, tag:0)
  }
}



extension HTTPConnection: GCDAsyncSocketDelegate {
  func socket(_ socket:GCDAsyncSocket, didRead data:Data, withTag tag:Int){
    switch machine.state{
    case .readingHead(let message):
      message.append(data)
      if message.needsMoreHeader{
        machine.queue(.readingHead(message))
      } else{
        machine.queue(.readingBody(message))
      }
    case .readingBody(let message):
      message.append(data) //We're assuming this only gets called once because we give it the lenght of the buffer.
      machine.queue(.readComplete(message))
    default:
      assertionFailure("HTTPConnection has read data outside of a reading state")
    }
  }
  
  
  func socket(_ socket:GCDAsyncSocket, didWriteDataWithTag tag:Int){
    switch machine.state{
    case .writingResponse:
      machine.queue(.writeComplete)
    default:
      assertionFailure("HTTPConnection wrote data outside of a writing state")
    }
  }
}



private extension HTTPConnection {
  enum State: StateType {
    case ready
    case readingHead(HTTPMessage), readingBody(HTTPMessage), readComplete(HTTPMessage)
    case writingResponse(HTTPMessage), writeComplete

    static func shouldTransition(from: State, to: State) -> Bool {
      switch (from, to) {
      case (.ready, .readingHead),
      (.readingHead, .readingHead),
      (.readingHead, .readingBody),
      (.readingBody, .readComplete),
      (.readComplete, .writingResponse),
      (.writingResponse, .writeComplete):
        return true
      default:
        return false
      }
    }
  }
  
  
  func makeMachine() -> StateMachine<State> {
    let machine = StateMachine(initialState: State.ready)
    machine.transitionHandler = { [unowned self] _, to in
      switch to{
      case .readingHead:
        self.readHead()
      case .readingBody(let message):
        guard message.contentLength != 0 else {
          //We have to short-circuit here because reading 0 length from the socket is a no-op (and thus will never cause the async callback to be fired, thus never transition to SendingResponse).
          self.machine.queue(.readComplete(message))
          break
        }
        self.readBodyOfLength(UInt(message.contentLength))
      case .readComplete(let message):
        self.callback.whenFinishesRequest?(message.request)
        self.respondToMessage(message)
      case .writingResponse(let message):
        self.writeResponse(message)
      case .writeComplete:
        self.socket.disconnect()
        self.callback.whenFinishesResponse?()
      default:
        break
      }
    }
    return machine
  }
}
