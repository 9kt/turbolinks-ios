import UIKit
import WebKit

public protocol SessionDelegate: class {
    func sessionDidInitializeWebView(session: Session)
    func session(session: Session, didProposeVisitToURL URL: NSURL, withAction action: Action)
    
    func sessionDidStartRequest(session: Session)
    func session(session: Session, didFailRequestForVisitable visitable: Visitable, withError error: NSError)
    func sessionDidFinishRequest(session: Session)
}

public class Session: NSObject, WebViewDelegate, VisitDelegate, VisitableDelegate {
    public weak var delegate: SessionDelegate?

    public var webView: WKWebView {
        return self._webView
    }

    var _webView: WebView
    var initialized: Bool = false
    var refreshing: Bool = false

    public init(webViewConfiguration: WKWebViewConfiguration) {
        self._webView = WebView(configuration: webViewConfiguration)
        super.init()
        _webView.delegate = self
    }

    // MARK: Visiting

    private var currentVisit: Visit?
    private var topmostVisit: Visit?

    public var topmostVisitable: Visitable? {
        return topmostVisit?.visitable
    }

    public func visit(visitable: Visitable) {
        visitVisitable(visitable, action: .Advance)
    }
    
    func visitVisitable(visitable: Visitable, action: Action) {
        if visitable.visitableURL != nil {
            let visit: Visit

            if initialized {
                visit = JavaScriptVisit(visitable: visitable, action: action, webView: _webView)
                visit.restorationIdentifier = restorationIdentifierForVisitable(visitable)
            } else {
                visit = ColdBootVisit(visitable: visitable, action: action, webView: _webView)
            }

            currentVisit?.cancel()
            currentVisit = visit

            visit.delegate = self
            visit.start()
        }
    }

    public func reload() {
        if let visitable = topmostVisitable {
            initialized = false
            visit(visitable)
            topmostVisit = currentVisit
        }
    }

    // MARK: Visitable activation

    private var activatedVisitable: Visitable?

    func activateVisitable(visitable: Visitable) {
        if visitable !== activatedVisitable {
            if let activatedVisitable = self.activatedVisitable {
                deactivateVisitable(activatedVisitable, showScreenshot: true)
            }

            visitable.activateVisitableWebView(webView)
            activatedVisitable = visitable
        }
    }

    func deactivateVisitable(visitable: Visitable, showScreenshot: Bool = false) {
        if visitable === activatedVisitable {
            if showScreenshot {
                visitable.updateVisitableScreenshot()
                visitable.showVisitableScreenshot()
            }

            visitable.deactivateVisitableWebView()
            activatedVisitable = nil
        }
    }

    // MARK: Visitable restoration identifiers

    private var visitableRestorationIdentifiers = NSMapTable(keyOptions: .WeakMemory, valueOptions: .StrongMemory)

    func restorationIdentifierForVisitable(visitable: Visitable) -> String? {
        return visitableRestorationIdentifiers.objectForKey(visitable) as? String
    }

    func storeRestorationIdentifier(restorationIdentifier: String, forVisitable visitable: Visitable) {
        visitableRestorationIdentifiers.setObject(restorationIdentifier, forKey: visitable)
    }

    // MARK: WebViewDelegate

    func webView(webView: WebView, didProposeVisitToLocation location: NSURL, withAction action: Action) {
        delegate?.session(self, didProposeVisitToURL: location, withAction: action)
    }

    func webViewDidInvalidatePage(webView: WebView) {
        if let visitable = topmostVisitable {
            visitable.updateVisitableScreenshot()
            visitable.showVisitableScreenshot()
            visitable.showVisitableActivityIndicator()
            reload()
        }
    }

    func webView(webView: WebView, didFailJavaScriptEvaluationWithError error: NSError) {
        if let currentVisit = self.currentVisit where initialized {
            self.initialized = false
            currentVisit.cancel()
            visit(currentVisit.visitable)
        }
    }

    // MARK: VisitDelegate

    func visitDidInitializeWebView(visit: Visit) {
        initialized = true
        delegate?.sessionDidInitializeWebView(self)
        visit.visitable.visitableDidRender?()
    }

    func visitWillStart(visit: Visit) {
        visit.visitable.showVisitableScreenshot()
        activateVisitable(visit.visitable)
    }
   
    func visitDidStart(visit: Visit) {
        if !visit.hasCachedSnapshot {
            visit.visitable.showVisitableActivityIndicator()
        }
    }

    func visitWillLoadResponse(visit: Visit) {
        visit.visitable.updateVisitableScreenshot()
        visit.visitable.showVisitableScreenshot()
    }

    func visitDidRender(visit: Visit) {
        visit.visitable.hideVisitableScreenshot()
        visit.visitable.hideVisitableActivityIndicator()
        visit.visitable.visitableDidRender?()
    }

    func visitDidComplete(visit: Visit) {
        if let restorationIdentifier = visit.restorationIdentifier {
            storeRestorationIdentifier(restorationIdentifier, forVisitable: visit.visitable)
        }

        if refreshing {
            refreshing = false
            visit.visitable.visitableDidRefresh()
        }
    }

    func visitDidFail(visit: Visit) {
        deactivateVisitable(visit.visitable)
    }

    // MARK: VisitDelegate networking

    func visitRequestDidStart(visit: Visit) {
        delegate?.sessionDidStartRequest(self)
    }

    func visitRequestDidFinish(visit: Visit) {
        delegate?.sessionDidFinishRequest(self)
    }

    func visit(visit: Visit, requestDidFailWithError error: NSError) {
        delegate?.session(self, didFailRequestForVisitable: visit.visitable, withError: error)
    }

    // MARK: VisitableDelegate

    public func visitableViewWillAppear(visitable: Visitable) {
        if let topmostVisit = self.topmostVisit, currentVisit = self.currentVisit {
            if visitable === topmostVisit.visitable && visitable.visitableViewController.isMovingToParentViewController() {
                // Back swipe gesture canceled
                if topmostVisit.state == .Completed {
                    currentVisit.cancel()
                } else {
                    visitVisitable(visitable, action: .Advance)
                }
            } else if visitable === currentVisit.visitable && currentVisit.state == .Started {
                // Navigating forward - complete navigation early
                completeNavigationForCurrentVisit()
            } else if visitable !== topmostVisit.visitable {
                // Navigating backward
                visitVisitable(visitable, action: .Restore)
            }
        }
    }
    
    public func visitableViewDidAppear(visitable: Visitable) {
        if visitable === currentVisit?.visitable {
            // Appearing after successful navigation
            completeNavigationForCurrentVisit()
            if currentVisit!.state != .Failed {
                activateVisitable(visitable)
            }
        } else if visitable === topmostVisit?.visitable && topmostVisit?.state == .Completed {
            // Reappearing after canceled navigation
            visitable.hideVisitableScreenshot()
            visitable.hideVisitableActivityIndicator()
            activateVisitable(visitable)
        }
    }

    public func visitableDidRequestRefresh(visitable: Visitable) {
        if visitable === topmostVisitable {
            refreshing = true
            visitable.visitableWillRefresh()
            reload()
        }
    }

    private func completeNavigationForCurrentVisit() {
        if let visit = currentVisit {
            topmostVisit = visit
            visit.completeNavigation()
        }
    }
}
