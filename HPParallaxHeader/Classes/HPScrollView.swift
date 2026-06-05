//
//  HPScrollView.swift
//  HPParallaxHeader
//
//  Created by Hien Pham on 17/05/2021.
//

import UIKit

/**
 The delegate of a MXScrollView object may adopt the MXScrollViewDelegate protocol to control subview's scrolling effect.
 */
@objc public protocol HPScrollViewDelegate: UIScrollViewDelegate {
    /**
     Asks the page if the scrollview should scroll with the subview.
     
     @param scrollView The scrollview. This is the object sending the message.
     @param subView    An instance of a sub view.
     
     @return YES to allow scrollview and subview to scroll together. YES by default.
     */
    func scrollViewShouldScroll(_ scrollView: HPScrollView, with subView: UIScrollView) -> Bool
}

/**
 The MXScrollView is a UIScrollView subclass with the ability to hook the vertical scroll from its subviews.
 */
open class HPScrollView : UIScrollView {
    static var KVOContext = "kHPScrollViewKVOContext"

    /**
     Delegate instance that adopt the MXScrollViewDelegate.
     */
    var forwarder: HPScrollViewDelegateForwarder!
    
    /// - Warning: This value **must** be set as a `DMScrollViewDelegate`.
    override open var delegate: UIScrollViewDelegate? {
        get { return forwarder.delegate }
        set {
            forwarder.delegate = newValue as? HPScrollViewDelegate
            super.delegate = nil
            super.delegate = forwarder
        }
    }

    private var observedViews: [UIScrollView] = []
    private var isObserving: Bool = true
    private var lock: Bool = false
    private var isScrollingToTop: Bool = false
    // FIX: Guards against KVO re-entrancy in observeValue(...).
    // observeValue calls scrollView(_:setContentOffset:), which assigns
    // contentOffset and synchronously fires another contentOffset KVO,
    // re-entering observeValue. During that re-entrant call the
    // `change as? CGPoint` downcast can crash with EXC_BAD_ACCESS while the
    // Swift runtime resolves metadata. KVO is delivered synchronously on the
    // main thread, so a simple Bool is enough to detect the re-entry.
    private var isHandlingObservation: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        initialize()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize()
    }
    
    func initialize() {
        forwarder = HPScrollViewDelegateForwarder(scrollView: self)
        super.delegate = forwarder
        showsVerticalScrollIndicator = false
        isDirectionalLockEnabled = true
        bounces = true
        panGestureRecognizer.cancelsTouchesInView = false
        addObserver(self, forKeyPath: #keyPath(UIScrollView.contentOffset),
                    options:[.new, .old], context: &HPScrollView.KVOContext)
        isObserving = true
    }

    deinit {
        removeObserver(self, forKeyPath: #keyPath(contentOffset), context: &HPScrollView.KVOContext)
        removeObservedViews()
    }
}

extension HPScrollView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if (otherGestureRecognizer.view == self) {
            isScrollingToTop = false
            return false
        }
        
        // Ignore other gesture than pan
        if !(gestureRecognizer is UIPanGestureRecognizer) {
            return false
        }
        
        // Lock horizontal pan gesture.
        guard let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: self) else {
            return false
        }
        if (abs(velocity.x) > abs(velocity.y)) {
            return false
        }
        
        var otherView = otherGestureRecognizer.view
        // WKWebView on he MXScrollView
        if let wkContentClass = NSClassFromString("WKContentView"),
           let unwrapped = otherView, unwrapped.isKind(of: wkContentClass) {
            otherView = unwrapped.superview
        }
        
        // Consider scroll view pan only
        guard let scrollView = otherView as? UIScrollView else {
            return false
        }
        
        // Tricky case: UITableViewWrapperView
        if scrollView.superview is UITableView {
            return false
        }
        
        //tableview on the HPScrollView
        if let uiTableViewContentClass = NSClassFromString("UITableViewCellContentView"),
           (scrollView.superview?.isKind(of: uiTableViewContentClass) ?? false) {
            return false
        }
        
        let shouldScroll = forwarder.scrollViewShouldScroll(self, with: scrollView)
        
        if shouldScroll {
            addObservedView(scrollView)
        }
        
        return shouldScroll
    }
}

// MARK: - KVO
extension HPScrollView {
    /*
     *  MARK: - KVO
     */
    
    func addObserver(to scrollView: UIScrollView) {
        lock = (scrollView.contentOffset.y > -scrollView.contentInset.top)
        
        scrollView.addObserver(self,
                               forKeyPath: #keyPath(UIScrollView.contentOffset),
                               options: [.old, .new],
                               context: &HPScrollView.KVOContext)
    }
    
    func removeObserver(from scrollView: UIScrollView) {
        scrollView.removeObserver(self,
                                  forKeyPath: #keyPath(UIScrollView.contentOffset),
                                  context: &HPScrollView.KVOContext)
    }

    
    //This is where the magic happens...
    override open func observeValue(forKeyPath keyPath: String?,
                                    of object: Any?,
                                    change: [NSKeyValueChangeKey : Any]?,
                                    context: UnsafeMutableRawPointer?) {
        guard context == &HPScrollView.KVOContext && keyPath == #keyPath(UIScrollView.contentOffset) else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }

        // FIX: KVO re-entrancy guard.
        // The body below calls scrollView(_:setContentOffset:), which changes
        // contentOffset and re-enters this method synchronously via KVO. During
        // that re-entry the `change as? CGPoint` downcast can race with Swift
        // metadata resolution and crash with EXC_BAD_ACCESS, so bail out as soon
        // as a re-entry is detected.
        if isHandlingObservation { return }
        isHandlingObservation = true
        defer { isHandlingObservation = false }

        guard let scrollView = object as? UIScrollView,
            let new = change?[.newKey] as? CGPoint,
            let old = change?[.oldKey] as? CGPoint else { return }
        let diff = old.y - new.y
        if diff == 0.0 || !isObserving { return }

        if scrollView == self {
            
            //Adjust self scroll offset when scroll down
            if (diff > 0 && lock && isScrollingToTop == false) {
                self.scrollView(self, setContentOffset: old)
            } else if contentOffset.y < -contentInset.top && !bounces {
                self.scrollView(self, setContentOffset: CGPoint(x: contentOffset.x,
                                                                y: -contentInset.top))
            } else if contentOffset.y > -parallaxHeader.minimumHeight {
                self.scrollView(self, setContentOffset: CGPoint(x: contentOffset.x,
                                                                y: -parallaxHeader.minimumHeight))
            }
            
            // Check and update isScrollingToTop
            if contentOffset.y <= -parallaxHeader.height {
                isScrollingToTop = false
            }
        } else {
            //Adjust the observed scrollview's content offset
            lock = (scrollView.contentOffset.y > -scrollView.contentInset.top)
            
            //Manage scroll up
            if (contentOffset.y < -parallaxHeader.minimumHeight) && lock && (diff < 0) {
                self.scrollView(scrollView, setContentOffset: old)
            }
            
            //Disable bouncing when scroll down
            if !lock && ((contentOffset.y > -contentInset.top) || bounces) {
                self.scrollView(scrollView, setContentOffset: CGPoint(x: scrollView.contentOffset.x,
                                                                      y: -scrollView.contentInset.top))
            }
        }
    }
    
    /**
     Scroll to top manually which show parallax header totally
     */
    open func hpScrollsToTop(animated: Bool) {
        isScrollingToTop = true
        setContentOffset(CGPoint(x: 0, y: -parallaxHeader.height), animated: animated)
    }
}

// MARK: - Scrolling views handlers
extension HPScrollView {
    func addObservedView(_ scrollView: UIScrollView) {
        guard !observedViews.contains(scrollView) else { return }
        observedViews.append(scrollView)
        addObserver(to: scrollView)
    }
    
    func removeObservedViews() {
        observedViews.forEach { removeObserver(from: $0) }
        observedViews.removeAll()
    }

    func scrollView(_ scrollView: UIScrollView, setContentOffset offset: CGPoint) {
        // FIX(1): Skip the assignment when the target equals the current offset.
        // Assigning contentOffset fires a KVO notification even when the value
        // does not change, which can drive the re-entrant layout/allocation that
        // crashes. Sub-pixel differences are treated as equal.
        let current = scrollView.contentOffset
        if abs(current.x - offset.x) < 0.5, abs(current.y - offset.y) < 0.5 {
            return
        }

        // FIX(2): When called from inside observeValue (i.e. during a layout /
        // KVO re-entrancy), assigning contentOffset synchronously fires
        // _NSSetPointValueAndNotify in the middle of layoutBelowIfNeeded and can
        // mutate the CA::Layer hierarchy, crashing with EXC_BAD_ACCESS. Defer the
        // assignment to the next run loop so it runs after layout settles.
        if isHandlingObservation {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let now = scrollView.contentOffset
                if abs(now.x - offset.x) < 0.5, abs(now.y - offset.y) < 0.5 { return }
                self.isObserving = false
                scrollView.contentOffset = offset
                self.isObserving = true
            }
            return
        }

        isObserving = false
        scrollView.contentOffset = offset
        isObserving = true
    }
}

// MARK: - <UIScrollViewDelegate>
extension HPScrollView: UIScrollViewDelegate {
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        delegate?.scrollViewDidEndDecelerating?(scrollView)
    }
    
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
    }
}
