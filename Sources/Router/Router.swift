import Foundation
import UIKit

public protocol Route: Hashable { }

public protocol RoutableViewController {
    static func create(_ parameters: Parameters?) -> UIViewController
    mutating func handleRouteParameters(_ parameters: Parameters?)
}

public protocol Parameters {
    
    static func fromURL(_ url: URL) -> Self
    init()
    
    var otherData: [String: String]? { get }
}

public typealias RouteProcessorBlock<R: Route, P: Parameters>
    = (P?) -> (@escaping (Result<(route: R, parameters: P?), Error>) -> Void) -> Void

public enum RouteType<R: Route, P: Parameters> {
    case storyboard(String, String)
    case viewController(RoutableViewController.Type)
    case viewControllerBuilder((P?) -> UIViewController)
    case redirect(R)
    case redirectBlock((P?) throws -> R)
    case processThenRedirect(RouteProcessorBlock<R, P>)
    case callBlock((P?) -> Void)
    case notification(Notification.Name, Any?, [AnyHashable: Any]?)
    
    var requiresMainThread: Bool {
        switch self {
        case .storyboard, .viewController, .viewControllerBuilder:
            return true
        default: return false
        }
    }
}

public enum RouterError: String, Error {
    case noRegistrationsForRoute
}

public struct RouterEventBlocks<R: Route, P: Parameters> {

    public var routerWillPrepareNavigation: (R, inout P?) -> Void
    public var handleRoutedViewController: (UIViewController) -> Void
    public var handleBackNavigation: () -> Void
    
    public init(
        routerWillPrepareNavigation: @escaping (R, inout P?) -> Void,
        handleRoutedViewController: @escaping (UIViewController) -> Void,
        handleBackNavigation: @escaping () -> Void
    ) {
        self.routerWillPrepareNavigation = routerWillPrepareNavigation
        self.handleRoutedViewController = handleRoutedViewController
        self.handleBackNavigation = handleBackNavigation
    }
}

public class Router<R: Route, P: Parameters> {
    
    public var routerEventBlocks: RouterEventBlocks<R, P>?
    
    private(set) var registry: [R: RouteType<R, P>] = [:]
    
    public init () {
        
    }
    
    public func register(route: R, withRouteType routeType: RouteType<R, P>) {
        registry[route] = routeType
    }
    
    public func navigate(to route: R) throws {
        try navigate(to: route, withParameters: nil)
    }
    
    public func navigate(to route: R, withParameters parameters: P?) throws {
        guard let routeType = registry[route] else {
            throw RouterError.noRegistrationsForRoute
        }
        
        var params = parameters
        routerEventBlocks?.routerWillPrepareNavigation(route, &params)
        
        if !routeType.requiresMainThread {
            try handleIndirectNavigation(to: routeType, withParameters: params)
            return
        }
        
        DispatchQueue.main.async {
            let vc: UIViewController
            switch routeType {
            case .storyboard(let sbName, let ctrlName):
                vc = UIStoryboard(name: sbName, bundle: nil).instantiateViewController(withIdentifier: ctrlName)
            case .viewController(let ctrlType):
                vc = ctrlType.create(params)
            case .viewControllerBuilder(let buildFunc):
                vc = buildFunc(params)
            default: return // all other types should have already been handled
            }
            if var routableVC = vc as? RoutableViewController {
                routableVC.handleRouteParameters(params)
            }
            self.routerEventBlocks?.handleRoutedViewController(vc)
        }
    }
    
    public func navigateBack() {
        DispatchQueue.main.async {
            self.routerEventBlocks?.handleBackNavigation()
        }
    }
    
    public func handleIndirectNavigation(to routeType: RouteType<R, P>, withParameters parameters: P?) throws {
        switch routeType {
        case .redirect(let newRoute):
            try self.navigate(to: newRoute, withParameters: parameters)
        case .redirectBlock(let routingBlock):
            try self.navigate(to: routingBlock(parameters), withParameters: parameters)
        case .callBlock(let block):
            block(parameters)
        case .notification(let name, let object, let userInfo):
            NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
        case .processThenRedirect(let processor):
            self.handleProcessing(processor, withParameters: parameters)
        case .storyboard, .viewController, .viewControllerBuilder:
            break
        }
    }
    
    public func handleProcessing(_ processorBlock: RouteProcessorBlock<R, P>, withParameters parameters: P?) {
        processorBlock(parameters)({ result in
            do {
                switch result {
                case .success(let value):
                    try self.navigate(to: value.route, withParameters: value.parameters)
                case .failure(let error):
                    throw error
                }
            } catch {
                print("Error, failed to navigate")
            }
        })
    }
    
    public func handle(userActivity: NSUserActivity) throws {
        
    }
    
}
